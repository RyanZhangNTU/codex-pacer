import Foundation

/// Account credits are independent of local turn costs and rate-limit windows.
public struct HarnessAccountCredits: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ready, signIn, unavailable }
    public let state: State
    public let remaining: Double?
    public let total: Double?
    public let reserved: Double?
    public let plan: String?
    public let cycle: Cycle?
    public let expiration: Expiration?

    public struct Cycle: Codable, Equatable, Sendable {
        public let total: Double
        public let remaining: Double
        public let used: Double?
        public let reset: Double?
    }

    public struct Expiration: Codable, Equatable, Sendable {
        public let credits: Double
        public let at: Double
    }

    public func reading(at now: Date = Date()) -> Reading? {
        guard state == .ready, let remaining, let total, let reserved,
              [remaining, total, reserved].allSatisfy(Self.isAmount) else { return nil }
        let planCycle = cycle.flatMap { value -> Reading.PlanCycle? in
            guard Self.isAmount(value.total), Self.isAmount(value.remaining) else { return nil }
            return .init(total: value.total, remaining: value.remaining, used: value.used.flatMap { Self.isAmount($0) ? $0 : nil },
                resetsAt: value.reset.flatMap { Self.futureDate($0, at: now) })
        }
        let expiring = expiration.flatMap { value -> Reading.ExpiringCredits? in
            guard value.credits > 0, value.credits <= remaining + 0.000001,
                  let date = Self.futureDate(value.at, at: now) else { return nil }
            return .init(credits: value.credits, date: date)
        }
        return Reading(remaining: remaining, total: total, reserved: reserved,
                       plan: plan.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }, cycle: planCycle, expiring: expiring)
    }

    private static func isAmount(_ value: Double) -> Bool { (0...128e12).contains(value) }
    private static func futureDate(_ value: Double, at now: Date) -> Date? {
        (0..<4_102_444_800).contains(value) && value > now.timeIntervalSince1970 ? Date(timeIntervalSince1970: value) : nil
    }

    public struct Reading: Equatable, Sendable {
        public let remaining: Double
        public let total: Double
        public let reserved: Double
        public let plan: String?
        public let cycle: PlanCycle?
        public let expiring: ExpiringCredits?
        public var fraction: Double? { total > 0 ? min(1, remaining / total) : nil }

        public struct PlanCycle: Equatable, Sendable {
            public let total: Double
            public let remaining: Double
            public let used: Double?
            public let resetsAt: Date?
        }

        public struct ExpiringCredits: Equatable, Sendable {
            public let credits: Double
            public let date: Date
        }
    }
}

public enum WorkBuddyAccountWeb {
    public static let china = URL(string: "https://www.workbuddy.cn/")!
    public static let international = URL(string: "https://www.workbuddy.ai/")!
    public static let billingPath = "/billing/meter/get-user-resource-summary"
    public static let loginPath = "profile/plans-usage"
    public static let summaryScript: String = {
        guard let url = Bundle.module.url(forResource: "workbuddy-account-credits", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing WorkBuddy account credits script")
        }
        return script
    }()
}
