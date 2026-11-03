import Foundation
import XCTest
@testable import PacerCore

enum PresentationScenarioFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }
    static func table<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PresentationTables/" + name + ".json")
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    struct Window: Decodable {
        let id: String
        let used: Double?
        let minutes: Int?
        let reset: Double?
        var value: QuotaWindow {
            .init(id: id, usedPercent: used, durationMinutes: minutes,
                resetsAt: reset.map { PresentationScenarioFixtures.now.addingTimeInterval($0) })
        }
    }
    static func snapshot(_ provider: AgentProvider, windows: [QuotaWindow], age: Double = 0,
                         bucket: String? = nil, emptyBucket: Bool = false) -> QuotaSnapshot {
        var buckets = [QuotaBucket(id: bucket ?? provider.rawValue, name: bucket, plan: nil, windows: windows, credits: nil)]
        if emptyBucket { buckets.append(.init(id: "empty", name: "Unreported", plan: nil, windows: [], credits: nil)) }
        return .init(buckets: buckets, capturedAt: now.addingTimeInterval(-age), accountScope: "synthetic-only", resetCredits: nil)
    }
    // Absolute UTC dates freeze the original compatibility fixture's demo inputs.
    static func demoQuota(_ provider: AgentProvider, weeklyRemaining: Double? = nil, capturedAt: Date? = nil) throws -> QuotaSnapshot {
        var limits: [String: Any] = ["limitId": provider.rawValue,
            "planType": provider == .codex ? "pro" : "max",
            "secondary": ["usedPercent": 100 - (weeklyRemaining ?? (provider == .codex ? 43 : 64)), "windowDurationMins": 10080,
                "resetsAt": now.addingTimeInterval(187200).timeIntervalSince1970]]
        if provider == .claude {
            limits["primary"] = ["usedPercent": 19, "windowDurationMins": 300,
                "resetsAt": now.addingTimeInterval(9600).timeIntervalSince1970]
        }
        var wire: [String: Any] = [:]
        if provider == .codex {
            limits["credits"] = ["hasCredits": true, "unlimited": false, "balance": "12500"]
            wire["rateLimitResetCredits"] = ["availableCount": 2, "credits": [
                ["id": "demo-reset-1", "status": "available", "grantedAt": now.addingTimeInterval(-86400).timeIntervalSince1970,
                    "expiresAt": now.addingTimeInterval(43200).timeIntervalSince1970],
                ["id": "demo-reset-2", "status": "available", "grantedAt": now.addingTimeInterval(-43200).timeIntervalSince1970,
                    "expiresAt": now.addingTimeInterval(129600).timeIntervalSince1970]]]
        }
        wire["rateLimits"] = limits
        var value = try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: wire), capturedAt: capturedAt ?? now)
        value.accountScope = "demo"
        return value
    }
    static func demoWallet(budget: Bool, total: Double = 86.4, age: Double = 0) -> DeepSeekWallet {
        let usage = DemoScenario.deepseekUsage(at: now, calendar: calendar)
        let start = calendar.startOfDay(for: now).addingTimeInterval(60)
        let local = usage.ledger.total(in: DateInterval(start: start, end: now)).total
        var history = DeepSeekBalanceHistory()
        history.record(total: 86.4 + local + 2.1, at: start, source: "web", calendar: calendar)
        history.record(total: 86.4, at: now, source: "web", calendar: calendar)
        return .init(balance: .init(total: total, capturedAt: now.addingTimeInterval(-age), source: .web), connected: true,
            ledger: usage.ledger, now: now, history: history, budgets: budget ? .init(daily: 20, weekly: 100) : .init(), calendar: calendar)
    }
    static func equal(_ actual: Double?, _ expected: Double?, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        if let expected {
            guard let actual else { XCTFail("Missing value: " + message, file: file, line: line); return }
            XCTAssertEqual(actual, expected, accuracy: 0.000_001, message, file: file, line: line)
        } else { XCTAssertNil(actual, message, file: file, line: line) }
    }
    struct Text: Decodable {
        var literal: String?
        var key: String?
        var numbers: [Int]?
        var strings: [String]?
        func render(substitutions: [String: String] = [:]) -> String {
            if let literal { return substitutions[literal] ?? literal }
            guard let key else { return "" }
            if let n = numbers, n.count == 2 { return L10n.text(key, n[0], n[1]) }
            if let n = numbers, n.count == 1 { return L10n.text(key, n[0]) }
            let s = strings?.map { substitutions[$0] ?? $0 }
            if let s, s.count == 2 { return L10n.text(key, s[0], s[1]) }
            if let s, s.count == 1 { return L10n.text(key, s[0]) }
            return L10n.text(key)
        }
    }
}
