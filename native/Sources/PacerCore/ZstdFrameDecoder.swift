import CZstd
import Foundation

/// Decodes the complete Zstandard frames of an append-only log. Each append is
/// one checksummed frame, so a read always resumes at a frame boundary. A torn
/// final frame waits for its writer; a complete frame that fails its checksum
/// is skipped whole; bytes that are not a frame at all are an error.
struct ZstdFrameDecoder {
    enum Failure: Error, Equatable { case corrupt }
    struct Output: Equatable {
        /// Complete lines; each keeps at most `maxLineBytes` of its prefix.
        var lines: [Data] = []
        var truncatedLines = 0
        var skippedFrames = 0
        /// Compressed bytes consumed through the last complete frame.
        var consumed = 0
        var frames = 0
        /// Complete frames remain beyond this read's budget.
        var more = false
    }

    static func decode(_ data: Data, maxFrames: Int = 4096, maxDecodedBytes: Int = 64 << 20,
                       maxLineBytes: Int = 1 << 20) throws -> Output {
        var output = Output()
        guard !data.isEmpty, let context = ZSTD_createDCtx() else { return output }
        defer { ZSTD_freeDCtx(context) }
        var decoded = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while output.consumed < raw.count {
                let start = base.advanced(by: output.consumed), remaining = raw.count - output.consumed
                let size = ZSTD_findFrameCompressedSize(start, remaining)
                if ZSTD_isError(size) != 0 {
                    // A writer appends whole frames; a short tail is still being written.
                    if ZSTD_getErrorCode(size) == ZSTD_error_srcSize_wrong { return }
                    throw Failure.corrupt
                }
                guard output.frames < maxFrames, decoded < maxDecodedBytes else { output.more = true; return }
                ZSTD_DCtx_reset(context, ZSTD_reset_session_only)
                var input = ZSTD_inBuffer(src: start, size: size, pos: 0)
                var line = Data(), lineBytes = 0, frameLines: [Data] = [], frameTruncated = 0, frameDecoded = 0
                var finished = false, failed = false
                while !finished, !failed {
                    let produced: Int = chunk.withUnsafeMutableBytes { buffer in
                        var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                        let result = ZSTD_decompressStream(context, &out, &input)
                        if ZSTD_isError(result) != 0 { failed = true; return 0 }
                        finished = result == 0
                        return out.pos
                    }
                    if !finished, produced == 0, input.pos >= input.size { failed = true }
                    frameDecoded += produced
                    var index = 0
                    while index < produced {
                        if let newline = chunk[index..<produced].firstIndex(of: 10) {
                            let take = min(newline - index, max(0, maxLineBytes - lineBytes))
                            if take > 0 { line.append(contentsOf: chunk[index..<(index + take)]) }
                            if lineBytes + (newline - index) > maxLineBytes { frameTruncated += 1 }
                            if !line.isEmpty { frameLines.append(line) }
                            line = Data(); lineBytes = 0; index = newline + 1
                        } else {
                            let take = min(produced - index, max(0, maxLineBytes - lineBytes))
                            if take > 0 { line.append(contentsOf: chunk[index..<(index + take)]) }
                            lineBytes += produced - index; index = produced
                        }
                    }
                }
                guard !failed, input.pos == size else {
                    output.skippedFrames += 1; output.consumed += size; output.frames += 1; continue
                }
                if !line.isEmpty { frameLines.append(line); if lineBytes > maxLineBytes { frameTruncated += 1 } }
                output.lines += frameLines; output.truncatedLines += frameTruncated
                output.consumed += size; output.frames += 1; decoded += frameDecoded
            }
        }
        return output
    }
}
