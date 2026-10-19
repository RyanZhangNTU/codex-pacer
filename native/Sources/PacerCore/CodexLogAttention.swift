import Foundation
import CryptoKit

/// Fallback for Desktop async questions when its IPC owner supplies no stream.
/// Keeps only hashed call IDs, acceptance and timestamps, never question text.
struct CodexLogAttention: Sendable {
    /// Marks requests from this fallback, so a question moving between it and
    /// Desktop's stream keeps one reminder.
    static let requestPrefix = "codex-log-question:"
    private static let questionTools: Set<String> = ["request_user_input_async", "functions.request_user_input_async"]
    private static let hexDigits = Array("0123456789abcdef".utf8)
    private struct Call: Sendable {
        let at: Date
        var accepted = false
    }
    private var turn: String?
    private var calls: [String: Call] = [:]
    private(set) var keyedRecords = 0

    mutating func reset() { turn = nil; calls.removeAll() }

    mutating func consume(_ value: [String: Any], activity: SessionActivity, now: Date) {
        guard activity.acceptsLogAttention, let current = activity.turnID,
              [.running, .waitingForInput].contains(activity.phase) else { reset(); return }
        if turn != current { calls.removeAll(); turn = current }
        guard value["type"] as? String == "response_item", let payload = value["payload"] as? [String: Any] else { return }
        // Most records are other tool traffic. Skip them before parsing a
        // timestamp or hashing a call ID; replies and outputs matter only
        // while a question is tracked.
        let type = payload["type"] as? String
        let question = type == "function_call" && Self.questionTools.contains(payload["name"] as? String ?? "")
        let reply = type == "message" && payload["role"] as? String == "user"
        guard question || (!calls.isEmpty && (reply || type == "function_call_output")) else { return }
        guard let stamp = value["timestamp"] as? String, let at = SessionActivity.parseDate(stamp),
              at <= now.addingTimeInterval(300), activity.turnStartedAt.map({ at >= $0 }) == true else { return }
        if reply {
            calls = calls.filter { $0.value.at > at }
            return
        }
        keyedRecords += 1
        guard let id = payload["call_id"] as? String,
              let key = Self.key(thread: activity.threadID ?? activity.id, turn: current, call: id) else { return }
        if question {
            guard let arguments = payload["arguments"] as? String,
                  let document = try? JSONFieldView.document(Data(arguments.utf8), maximumBytes: 64 * 1024),
                  let questions = try? document.fields(["questions"])["questions"],
                  let count = try? questions.countElements(maximumCount: 64), count > 0, calls[key] == nil else { return }
            if calls.count >= 64, let oldest = calls.min(by: { $0.value.at < $1.value.at })?.key { calls.removeValue(forKey: oldest) }
            calls[key] = Call(at: at)
        } else if let call = calls[key], at >= call.at {
            guard let output = payload["output"] as? String,
                  let document = try? JSONFieldView.document(Data(output.utf8), maximumBytes: 16 * 1024),
                  (try? document.fields(["accepted"])["accepted"]?.boolean()) == true else {
                calls.removeValue(forKey: key); return
            }
            calls[key]?.accepted = true
        }
    }

    func requests(for activity: SessionActivity) -> [PendingAttentionRequest] {
        guard activity.acceptsLogAttention, activity.turnID == turn,
              [.running, .waitingForInput].contains(activity.phase), let thread = activity.threadID else { return [] }
        return calls.filter { $0.value.accepted }.map { key, call in
            PendingAttentionRequest(id: Self.requestPrefix + key, threadID: thread, sourceHostID: nil,
                sourceName: nil, kind: .input, detectedAt: call.at)
        }.sorted { $0.id < $1.id }
    }

    /// Thread, turn and call in one opaque key; the call ID itself is not kept.
    private static func key(thread: String, turn: String, call: String) -> String? {
        guard !call.isEmpty, call.utf8.count <= 256,
              call.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil else { return nil }
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data((thread + "\0" + turn + "\0" + call).utf8)) {
            hex.append(hexDigits[Int(byte >> 4)]); hex.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
