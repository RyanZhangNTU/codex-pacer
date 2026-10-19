import Foundation
import CryptoKit

/// Fallback for Desktop async questions when its IPC owner supplies no stream.
/// Keeps only hashed call IDs, acceptance and timestamps, never question text.
struct CodexLogAttention: Sendable {
    private struct Call: Sendable {
        let at: Date
        var accepted = false
    }
    private var turn: String?
    private var calls: [String: Call] = [:]

    mutating func reset() { turn = nil; calls.removeAll() }

    mutating func consume(_ value: [String: Any], activity: SessionActivity, now: Date) {
        guard activity.acceptsLogAttention, let current = activity.turnID,
              [.running, .waitingForInput].contains(activity.phase) else { reset(); return }
        if turn != current { calls.removeAll(); turn = current }
        guard value["type"] as? String == "response_item", let payload = value["payload"] as? [String: Any],
              let stamp = value["timestamp"] as? String, let at = SessionActivity.parseDate(stamp),
              at <= now.addingTimeInterval(300), activity.turnStartedAt.map({ at >= $0 }) == true else { return }
        if payload["type"] as? String == "message", payload["role"] as? String == "user" {
            calls = calls.filter { $0.value.at > at }
            return
        }
        guard let id = payload["call_id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil else { return }
        let key = SHA256.hash(data: Data(((activity.threadID ?? activity.id) + "\0" + current + "\0" + id).utf8)).map { String(format: "%02x", $0) }.joined()
        if payload["type"] as? String == "function_call",
           ["request_user_input_async", "functions.request_user_input_async"].contains(payload["name"] as? String ?? ""),
           let arguments = payload["arguments"] as? String,
           let document = try? JSONFieldView.document(Data(arguments.utf8), maximumBytes: 64 * 1024),
           let questions = try? document.fields(["questions"])["questions"],
           let count = try? questions.countElements(maximumCount: 64), count > 0 {
            if calls[key] == nil {
                if calls.count >= 64, let oldest = calls.min(by: { $0.value.at < $1.value.at })?.key { calls.removeValue(forKey: oldest) }
                calls[key] = Call(at: at)
            }
        } else if payload["type"] as? String == "function_call_output", let call = calls[key], at >= call.at {
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
            PendingAttentionRequest(id: "codex-log-question:" + key, threadID: thread, sourceHostID: nil,
                sourceName: nil, kind: .input, detectedAt: call.at)
        }.sorted { $0.id < $1.id }
    }
}
