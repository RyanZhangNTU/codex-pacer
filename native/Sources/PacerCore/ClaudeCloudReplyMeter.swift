import Foundation

/// What Claude's message streams say about a run, as numbers. A partial reply
/// repeats everything written so far, and its text never leaves the parser.
enum ClaudeCloudStreamEvent: Equatable, Sendable {
    /// `session` is set when the event names the thread's own session.
    case threadStarting(thread: String, session: String?)
    case partialReply(thread: String, block: String, tokens: Double, sentAt: Date?)
}

/// Reads server-sent events line by line. Only the events below are decoded, so
/// the message bodies in the rest of a stream are skipped unread.
struct ClaudeCloudStreamParser: Sendable {
    /// The thread a thread-scoped stream belongs to.
    let thread: String?
    private var event = ""

    init(thread: String? = nil) { self.thread = thread }

    mutating func consume(_ line: Data) -> ClaudeCloudStreamEvent? {
        if line.starts(with: Self.eventPrefix) {
            event = String(decoding: line.dropFirst(Self.eventPrefix.count), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.starts(with: Self.dataPrefix), Self.decoded.contains(event),
              let row = (try? JSONSerialization.jsonObject(with: line.dropFirst(Self.dataPrefix.count))) as? [String: Any] else { return nil }
        // A coordinator's own events have no thread, and a project's stream carries them.
        guard let id = ClaudeCloudDecoder.threadID(row["thread_root_id"]) ?? thread else { return nil }
        switch event {
        case "thread_starting":
            return .threadStarting(thread: id, session: nil)
        case "session_activity":
            guard row["working"] as? Bool == true else { return nil }
            return .threadStarting(thread: id, session: ClaudeCloudDecoder.sessionID(row["session_id"]))
        default:
            guard let text = row["text"] as? String, let block = row["tool_use_id"] as? String, !block.isEmpty, block.utf8.count <= 128 else { return nil }
            return .partialReply(thread: id, block: block, tokens: ClaudeCloudReplyMeter.tokens(in: text),
                sentAt: (row["at"] as? String).flatMap(SessionActivity.parseDate))
        }
    }
    private static let eventPrefix = Array("event:".utf8), dataPrefix = Array("data:".utf8)
    private static let decoded: Set<String> = ["thread_starting", "session_activity", "session_partial_reply"]
}

/// Splits a byte stream into non-empty lines, without letting one grow without bound.
struct ClaudeCloudLineBuffer: Sendable {
    /// A partial reply repeats the whole reply, so this allows a very long one.
    static let maximumLine = 4 * 1024 * 1024
    private var line: [UInt8] = []

    mutating func append(_ byte: UInt8) throws -> Data? {
        guard byte == 10 else {
            guard line.count < Self.maximumLine else { throw ClaudeCloudFailure.invalidReply }
            line.append(byte)
            return nil
        }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        return line.isEmpty ? nil : Data(line)
    }
}

/// Estimates how fast a thread is writing. Claude publishes no token count during
/// a run, so this converts the growth of the reply's text, and it knows nothing
/// during thinking or other tool calls, which never appear in a partial reply.
struct ClaudeCloudReplyMeter: Equatable, Sendable {
    private struct Block: Equatable, Sendable { var tokens: Double; var at: Date }
    private struct Sample: Equatable, Sendable { let end: Date; let tokens: Double; let seconds: TimeInterval }
    /// Measured against turn results: replies of about 10,000 characters in each language.
    private static let tokensPerWideCharacter = 1.09, tokensPerCharacter = 0.3
    /// Updates come about every 0.44 s, so a longer pause is not writing.
    private static let longestPause: TimeInterval = 3
    private static let window: TimeInterval = 10
    private static let shortestMeasurement: TimeInterval = 2
    private static let maximumBlocks = 8
    private var blocks: [String: Block] = [:]
    private var samples: [Sample] = []

    static func tokens(in text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? tokensPerWideCharacter : tokensPerCharacter) }
    }
    /// CJK text takes about three times the tokens per character of Latin text.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF: return true
        default: return false
        }
    }

    mutating func observe(block id: String, tokens: Double, at date: Date) {
        guard let previous = blocks[id] else {
            blocks[id] = Block(tokens: tokens, at: date)
            if blocks.count > Self.maximumBlocks, let oldest = blocks.min(by: { $0.value.at < $1.value.at })?.key { blocks[oldest] = nil }
            return
        }
        let seconds = date.timeIntervalSince(previous.at)
        guard seconds > 0 else { return }
        blocks[id] = Block(tokens: tokens, at: date)
        guard seconds <= Self.longestPause, tokens >= previous.tokens else { return }
        samples.append(Sample(end: date, tokens: tokens - previous.tokens, seconds: seconds))
        samples.removeAll { date.timeIntervalSince($0.end) > Self.window }
    }

    var tokensPerSecond: Double? {
        let seconds = samples.reduce(0) { $0 + $1.seconds }
        guard seconds >= Self.shortestMeasurement else { return nil }
        let rate = samples.reduce(0) { $0 + $1.tokens } / seconds
        return rate > 0 && rate <= ClaudeCloudDecoder.maximumRate ? rate : nil
    }
}
