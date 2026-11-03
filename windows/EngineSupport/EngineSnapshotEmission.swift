import Foundation

/// Compare the wire projection, retaining every business field. Envelope time
/// and the compact query's reference clock alone do not change a visible value:
/// quota time/pace, wallet clock, task durations and freshness are projected too.
struct EngineSnapshotEmission {
    private var previous: Data?
    mutating func accepts(_ bytes: Data, force: Bool = false) throws -> Bool {
        guard var content = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return true }
        content.removeValue(forKey: "sequence"); content.removeValue(forKey: "capturedAt")
        if var compact = content["compactContext"] as? [String: Any] {
            compact.removeValue(forKey: "now"); content["compactContext"] = compact
        }
        let key = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys, .fragmentsAllowed])
        let changed = key != previous
        previous = key
        // A notification is an event, including an identical visible message.
        return force || changed || (content["notices"] as? [Any])?.isEmpty == false
    }
}
