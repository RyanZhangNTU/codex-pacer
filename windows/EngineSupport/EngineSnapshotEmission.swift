import Foundation

/// Compare the wire projection, retaining every business field. Envelope time
/// and the compact query's reference clock alone do not change a visible value:
/// quota time/pace, wallet clock, task durations and freshness are projected too.
/// Clock-derived numbers are compared at display precision (0.1 for percents
/// and degrees, 0.01 for amounts), so they publish when they move visibly
/// rather than on every source callback; the frame still carries exact values.
struct EngineSnapshotEmission {
    private var previous: Data?
    private static let tenths: Set<String> = ["remainingTimePercent", "pacePercent", "angle"]
    private static let hundredths: Set<String> = ["averageDaily"]

    mutating func accepts(_ bytes: Data, force: Bool = false) throws -> Bool {
        guard var content = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return true }
        content.removeValue(forKey: "sequence"); content.removeValue(forKey: "capturedAt")
        if var compact = content["compactContext"] as? [String: Any] {
            compact.removeValue(forKey: "now"); content["compactContext"] = compact
        }
        let notices = (content["notices"] as? [Any])?.isEmpty == false
        let key = try JSONSerialization.data(withJSONObject: Self.comparable(content), options: [.sortedKeys, .fragmentsAllowed])
        let changed = key != previous
        previous = key
        // A notification is an event, including an identical visible message.
        return force || changed || notices
    }

    private static func comparable(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            // A dashboard reading's reference time is the clock itself.
            if object["period"] != nil, object["availability"] != nil { object.removeValue(forKey: "date") }
            for (key, child) in object {
                if let number = child as? Double, !(child is Bool) {
                    if tenths.contains(key) { object[key] = (number * 10).rounded() / 10; continue }
                    if hundredths.contains(key) { object[key] = (number * 100).rounded() / 100; continue }
                }
                if child is [String: Any] || child is [Any] { object[key] = comparable(child) }
            }
            return object
        }
        if let array = value as? [Any] { return array.map(comparable) }
        return value
    }
}
