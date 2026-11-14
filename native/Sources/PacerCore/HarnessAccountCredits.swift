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

    /// Credits for the collapsed bar: 87, 1.2k, 12k, 3.4M.
    public static func compactAmount(_ value: Double) -> String {
        let value = max(0, value)
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let scaled = value / divisor
            return (scaled < 9.95 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)) + suffix
        }
        if value >= 999_500 { return scaled(1_000_000, "M") }
        if value >= 999.5 { return scaled(1000, "k") }
        return value < 9.95 && value.rounded() != value ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
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
        /// What is left of the plan cycle, or of all credits without one, in percent.
        public var percent: Double? {
            if let cycle, cycle.total > 0 { return min(100, max(0, cycle.remaining / cycle.total * 100)) }
            return fraction.map { $0 * 100 }
        }

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

/// Where a module's account credits come from. Hosts sign in on one of the
/// sites in their own web view, then run the summary script against the bill.
public struct HarnessAccountCreditsDefinition: Sendable {
    public struct Site: Equatable, Sendable {
        /// Stored in preferences: `automatic` picks by the app language.
        public let id: String
        public let url: URL
    }
    public let sites: [Site]
    /// The site `automatic` uses while the app is in Chinese.
    public let chineseSite: String
    /// The page that opens for sign-in, relative to the site.
    public let loginPath: String
    /// The bill request the summary script reads.
    public let billingPath: String
    private let scriptResource: String

    package init(sites: [Site], chineseSite: String, loginPath: String, billingPath: String, scriptResource: String) {
        self.sites = sites; self.chineseSite = chineseSite; self.loginPath = loginPath
        self.billingPath = billingPath; self.scriptResource = scriptResource
    }

    public func site(_ preference: String, chinese: Bool) -> Site {
        sites.first { $0.id == preference } ?? sites.first { $0.id == (chinese ? chineseSite : "") } ??
            sites.first { $0.id != chineseSite } ?? sites[0]
    }

    public var summaryScript: String {
        guard let url = Bundle.module.url(forResource: scriptResource, withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing account credits script " + scriptResource)
        }
        return script
    }
}

public enum WorkBuddyAccountWeb {
    private static var definition: HarnessAccountCreditsDefinition { WorkBuddyHarness.accountCredits }
    public static var china: URL { definition.site("china", chinese: true).url }
    public static var international: URL { definition.site("international", chinese: false).url }
    public static var billingPath: String { definition.billingPath }
    public static var loginPath: String { definition.loginPath }
    public static let summaryScript: String = WorkBuddyHarness.accountCredits.summaryScript
}
