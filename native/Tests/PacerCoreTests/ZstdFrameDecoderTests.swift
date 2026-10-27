import XCTest
@testable import PacerCore

final class ZstdFrameDecoderTests: XCTestCase {
    /// Two checksummed frames, as DeepSeek Harness appends them.
    private let first = Data(base64Encoded: "KLUv/SQ+vQEAtAJ7InR5cGUiOiJzZXNzaW9uIiwidmVyOjR9CnR1cm4vc3RhcnQiLCI6MX0KAwAwRRKqiF6lCXfDLmE=")!
    private let second = Data(base64Encoded: "KLUv/SQd6QAAeyJ0eXBlIjoidHVybi9lbmQiLCJ0dXJuIjoxfQpx14wB")!
    private func text(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    func testConcatenatedFramesDecodeToLinesAndConsumeEveryByte() throws {
        let output = try ZstdFrameDecoder.decode(first + second)
        XCTAssertEqual(text(output.lines), [#"{"type":"session","version":4}"#, #"{"type":"turn/start","turn":1}"#, #"{"type":"turn/end","turn":1}"#])
        XCTAssertEqual(output.consumed, first.count + second.count)
        XCTAssertEqual(output.frames, 2)
        XCTAssertFalse(output.more)
    }

    func testTornTailWaitsAtTheLastFrameBoundary() throws {
        let output = try ZstdFrameDecoder.decode(first + second.prefix(20))
        XCTAssertEqual(output.lines.count, 2)
        XCTAssertEqual(output.consumed, first.count)
        XCTAssertEqual(try ZstdFrameDecoder.decode(second.prefix(3)).consumed, 0)
    }

    func testDamagedFrameIsSkippedWholeAndGarbageFails() throws {
        var damaged = second
        damaged[damaged.count - 1] ^= 0xFF
        let output = try ZstdFrameDecoder.decode(damaged + first)
        XCTAssertEqual(output.skippedFrames, 1)
        XCTAssertEqual(text(output.lines), [#"{"type":"session","version":4}"#, #"{"type":"turn/start","turn":1}"#])
        XCTAssertEqual(output.consumed, damaged.count + first.count)
        XCTAssertThrowsError(try ZstdFrameDecoder.decode(Data("not zstd at all".utf8))) { XCTAssertEqual($0 as? ZstdFrameDecoder.Failure, .corrupt) }
    }

    func testBudgetsKeepLinePrefixesAndResumeAtFrameBoundaries() throws {
        let clipped = try ZstdFrameDecoder.decode(first + second, maxLineBytes: 10)
        XCTAssertEqual(text(clipped.lines), [#"{"type":"s"#, #"{"type":"t"#, #"{"type":"t"#])
        XCTAssertEqual(clipped.truncatedLines, 3)
        let limited = try ZstdFrameDecoder.decode(first + second, maxFrames: 1)
        XCTAssertEqual(limited.frames, 1)
        XCTAssertEqual(limited.consumed, first.count)
        XCTAssertTrue(limited.more)
        let rest = try ZstdFrameDecoder.decode((first + second).dropFirst(limited.consumed))
        XCTAssertEqual(text(rest.lines), [#"{"type":"turn/end","turn":1}"#])
    }

    func testDecodedByteBudgetDefersWholeFramesAndAcceptsItsExactBoundary() throws {
        let size = try ZstdFrameDecoder.decode(first).lines.reduce(0) { $0 + $1.count + 1 }
        let exact = try ZstdFrameDecoder.decode(first, maxDecodedBytes: size)
        XCTAssertEqual(exact.consumed, first.count)
        XCTAssertEqual(exact.skippedFrames, 0)
        let limited = try ZstdFrameDecoder.decode(first + second, maxDecodedBytes: size + 1)
        XCTAssertEqual(limited.consumed, first.count)
        XCTAssertEqual(limited.lines, exact.lines)
        XCTAssertTrue(limited.more)
        let rest = try ZstdFrameDecoder.decode(second, maxDecodedBytes: size + 1)
        XCTAssertEqual(rest.consumed, second.count)
        XCTAssertEqual(text(rest.lines), [#"{"type":"turn/end","turn":1}"#])
    }

    func testOversizedSingleFramesAreBoundedSkippedAndDoNotHideFollowingFrames() throws {
        // The same 1 MiB payload, with and without a declared frame content size.
        let frames = [
            "KLUv/aAAwBAATAEA6HsidHlwZSI6Imlnbm9yZWQiLCJwYWQiOiJBIn0KAgDx/g8rH7IpMAZMAAAIYQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJNAAAIQQEA/D8dCAE=",
            "KLUv/QBYTAEA6HsidHlwZSI6Imlnbm9yZWQiLCJwYWQiOiJBIn0KAgDx/g8rH7IpMAZMAAAIYQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJMAAAIQQEA/P85EAJNAAAIQQEA/D8dCAE="
        ].map { Data(base64Encoded: $0)! }
        for oversized in frames {
            var remaining = first + oversized + second, lines: [Data] = [], skipped = 0
            for _ in 0..<5 where !remaining.isEmpty {
                let next = try ZstdFrameDecoder.decode(remaining, maxDecodedBytes: 128, maxLineBytes: 128)
                XCTAssertLessThanOrEqual(next.lines.reduce(0) { $0 + $1.count }, 128)
                XCTAssertGreaterThan(next.consumed, 0, "An oversized frame must not be retried forever")
                guard next.consumed > 0 else { break }
                lines += next.lines; skipped += next.skippedFrames
                remaining = remaining.dropFirst(next.consumed)
            }
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertEqual(skipped, 1)
            let expected = try ZstdFrameDecoder.decode(first + second).lines
            XCTAssertEqual(lines.count, expected.count)
            XCTAssertTrue(lines == expected, "Valid frames before and after the oversized frame must survive")
        }
    }
}
