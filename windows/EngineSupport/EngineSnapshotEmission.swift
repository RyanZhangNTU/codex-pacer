import Foundation

/// Compare the wire projection, retaining every business field. Envelope time
/// and the compact query's reference clock alone do not change a visible value:
/// quota time/pace, wallet clock, task durations and freshness are projected too.
/// Clock-derived numbers are compared at display precision (0.1 for percents
/// and degrees, 0.01 for amounts), so they publish when they move visibly
/// rather than on every source callback; the frame still carries exact values.
struct EngineSnapshotEmission {
    private var previous: Data?

    mutating func accepts(_ bytes: Data, force: Bool = false) throws -> Bool {
        guard let content = try Self.comparable(bytes) else { return true }
        let notices = (content["notices"] as? [Any])?.isEmpty == false
        // A notification is an event, including an identical visible message.
        if !force, !notices, let previous, let old = try Self.comparable(previous), Self.equal(old, content) {
            return false
        }
        previous = bytes
        return true
    }

    private static func comparable(_ bytes: Data) throws -> [String: Any]? {
        guard var content = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        content.removeValue(forKey: "sequence"); content.removeValue(forKey: "capturedAt")
        if var compact = content["compactContext"] as? [String: Any] {
            compact.removeValue(forKey: "now"); content["compactContext"] = compact
        }
        return content
    }

    // Compare the parsed values without sorting keys or encoding a second
    // snapshot. The caller still sends the original, full precision frame.
    private static func equal(_ lhs: Any, _ rhs: Any, key: String? = nil) -> Bool {
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            // Foundation boxes JSON booleans separately from integer 0 and 1.
            let aBool = isBoolean(a), bBool = isBoolean(b)
            guard aBool == bBool else { return false }
            if a == b { return true }
            guard !aBool else { return false }
            switch key {
            case "remainingTimePercent", "pacePercent", "angle":
                return (a.doubleValue * 10).rounded() == (b.doubleValue * 10).rounded()
            case "averageDaily": return (a.doubleValue * 100).rounded() == (b.doubleValue * 100).rounded()
            default: return false
            }
        }
        if let a = lhs as? String, let b = rhs as? String { return a.utf8.elementsEqual(b.utf8) }
        if let a = lhs as? [Any], let b = rhs as? [Any] {
            return a.count == b.count && zip(a, b).allSatisfy { equal($0.0, $0.1) }
        }
        if let a = lhs as? [String: Any], let b = rhs as? [String: Any] {
            // A dashboard reading's reference time is the clock itself.
            let aDate = a["period"] != nil && a["availability"] != nil && a["date"] != nil
            let bDate = b["period"] != nil && b["availability"] != nil && b["date"] != nil
            guard a.count - (aDate ? 1 : 0) == b.count - (bDate ? 1 : 0) else { return false }
            for (key, value) in a where !(key == "date" && aDate) {
                guard !(key == "date" && bDate), let other = b[key], equal(value, other, key: key) else { return false }
            }
            return true
        }
        return lhs is NSNull && rhs is NSNull
    }

    private static let trueNumber = NSNumber(value: true)
    private static let falseNumber = NSNumber(value: false)
    private static func isBoolean(_ value: NSNumber) -> Bool { value === trueNumber || value === falseNumber }
}
