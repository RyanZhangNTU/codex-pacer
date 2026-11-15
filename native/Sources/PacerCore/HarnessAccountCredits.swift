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
    /// The bill's packages by how they behave, as the service's own usage page groups them.
    public let groups: [Group]?

    public init(state: State, remaining: Double?, total: Double?, reserved: Double?, plan: String?,
                cycle: Cycle?, expiration: Expiration?, groups: [Group]? = nil) {
        self.state = state; self.remaining = remaining; self.total = total; self.reserved = reserved
        self.plan = plan; self.cycle = cycle; self.expiration = expiration; self.groups = groups
    }

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

    /// Plan credits refresh every plan cycle; rewards and top-ups never
    /// refresh and lapse at their own dates.
    public struct Group: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case planBase, planBonus, reward, topUp
            public var refreshes: Bool { self == .planBase || self == .planBonus }
        }
        public let kind: Kind
        public let remaining: Double
        /// Refreshing groups: what each cycle grants.
        public let total: Double?
        /// Refreshing groups: the next refresh, in seconds since 1970.
        public let refresh: Double?
        /// Non-refreshing groups: what is left of each batch and when it lapses.
        public let expiries: [Expiration]?

        public init(kind: Kind, remaining: Double, total: Double? = nil, refresh: Double? = nil, expiries: [Expiration]? = nil) {
            self.kind = kind; self.remaining = remaining; self.total = total; self.refresh = refresh; self.expiries = expiries
        }
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
        let readGroups = (groups ?? []).prefix(Group.Kind.allCases.count).compactMap { group -> Reading.GroupReading? in
            guard Self.isAmount(group.remaining), group.total.map(Self.isAmount) ?? true else { return nil }
            let batches = (group.expiries ?? []).prefix(48).compactMap { batch -> Reading.ExpiringCredits? in
                guard batch.credits > 0, Self.isAmount(batch.credits), let date = Self.futureDate(batch.at, at: now) else { return nil }
                return .init(credits: batch.credits, date: date)
            }.sorted { $0.date < $1.date }
            return .init(kind: group.kind, remaining: group.remaining, total: group.kind.refreshes ? group.total : nil,
                         refreshesAt: group.kind.refreshes ? group.refresh.flatMap { Self.futureDate($0, at: now) } : nil,
                         batches: group.kind.refreshes ? [] : batches)
        }
        return Reading(remaining: remaining, total: total, reserved: reserved,
                       plan: plan.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }, cycle: planCycle, expiring: expiring,
                       groups: Array(readGroups))
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
        public let groups: [GroupReading]

        public init(remaining: Double, total: Double, reserved: Double, plan: String?, cycle: PlanCycle?, expiring: ExpiringCredits?,
                    groups: [GroupReading] = []) {
            self.remaining = remaining; self.total = total; self.reserved = reserved; self.plan = plan
            self.cycle = cycle; self.expiring = expiring; self.groups = groups
        }

        public var fraction: Double? { total > 0 ? min(1, remaining / total) : nil }
        /// Everything that can be spent now.
        public var available: Double { remaining }

        /// The credits that refresh every plan cycle (plan base and bonus).
        public var monthly: Monthly? {
            let refreshing = groups.filter(\.kind.refreshes)
            if !refreshing.isEmpty {
                let total = refreshing.compactMap(\.total).reduce(0, +)
                return Monthly(remaining: min(refreshing.map(\.remaining).reduce(0, +), remaining),
                               total: total, refreshesAt: refreshing.compactMap(\.refreshesAt).min())
            }
            if groups.isEmpty, let cycle { return Monthly(remaining: cycle.remaining, total: cycle.total, refreshesAt: cycle.resetsAt) }
            return nil
        }
        /// Rewards and top-ups: they never refresh and lapse at their own dates.
        public var extra: Extra? {
            if !groups.isEmpty {
                let lapsing = groups.filter { !$0.kind.refreshes }
                let credits = lapsing.map(\.remaining).reduce(0, +)
                guard credits > 0.000001 else { return nil }
                return Extra(remaining: credits, batches: lapsing.flatMap(\.batches).sorted { $0.date < $1.date })
            }
            let credits = remaining - (cycle?.remaining ?? remaining)
            guard credits > 0.000001 else { return nil }
            return Extra(remaining: credits, batches: expiring.map { [$0] } ?? [])
        }
        /// What is left of the month's credits, or of all credits without a plan, in percent.
        public var percent: Double? {
            if let monthly, monthly.total > 0 { return min(100, max(0, monthly.remaining / monthly.total * 100)) }
            return fraction.map { $0 * 100 }
        }
        /// How full the dial is: the month's credits, which refresh, so a fraction means something.
        public var monthlyFraction: Double? { percent.map { $0 / 100 } }

        /// The first extra credits to lapse within the window: those lapsing on
        /// the earliest day, so "300 expire tomorrow" doesn't add a batch that
        /// lapses later in the window (it read "1,000 expire tomorrow").
        public func expiringSoon(within days: Int, at now: Date, calendar: Calendar = .current) -> ExpiringCredits? {
            guard days > 0, let extra else { return nil }
            let limit = now.addingTimeInterval(TimeInterval(days) * 86_400)
            let soon = extra.batches.filter { $0.date > now && $0.date <= limit }
            guard let first = soon.min(by: { $0.date < $1.date }) else { return nil }
            let day = soon.filter { calendar.isDate($0.date, inSameDayAs: first.date) }
            return .init(credits: day.map(\.credits).reduce(0, +), date: first.date)
        }
        /// The credits that count as low: the user's line, or a tenth of the month's credits.
        public func lowLine(_ settings: HarnessCreditsSettings) -> Double {
            if let line = settings.lowCredits { return line }
            if let monthly, monthly.total > 0 { return monthly.total * 0.1 }
            return total * 0.1
        }
        /// A figure as the collapsed bar writes it: 4.6k, 3.3k or 83%.
        public func compactFigure(_ figure: HarnessCreditsFigure) -> String {
            switch figure {
            case .available: return HarnessAccountCredits.compactAmount(available)
            case .monthlyRemaining: return HarnessAccountCredits.compactAmount(monthly?.remaining ?? available)
            case .monthlyPercent: return percent.map { "\(Int($0.rounded()))%" } ?? HarnessAccountCredits.compactAmount(available)
            }
        }

        public struct PlanCycle: Equatable, Sendable {
            public let total: Double
            public let remaining: Double
            public let used: Double?
            public let resetsAt: Date?
            public init(total: Double, remaining: Double, used: Double?, resetsAt: Date?) {
                self.total = total; self.remaining = remaining; self.used = used; self.resetsAt = resetsAt
            }
        }

        public struct ExpiringCredits: Equatable, Sendable {
            public let credits: Double
            public let date: Date
            public init(credits: Double, date: Date) { self.credits = credits; self.date = date }
        }

        public struct GroupReading: Equatable, Sendable {
            public let kind: Group.Kind
            public let remaining: Double
            public let total: Double?
            public let refreshesAt: Date?
            public let batches: [ExpiringCredits]
            /// The earliest lapse among a non-refreshing group's batches.
            public var expiresAt: Date? { batches.first?.date }
        }

        public struct Monthly: Equatable, Sendable {
            public let remaining: Double
            public let total: Double
            public let refreshesAt: Date?
        }

        public struct Extra: Equatable, Sendable {
            public let remaining: Double
            /// Sorted by date; empty when the bill gave no dates.
            public let batches: [ExpiringCredits]
        }
    }
}

/// What a credits module's dial shows in its center, or the collapsed bar shows as its value.
public enum HarnessCreditsFigure: String, Codable, CaseIterable, Sendable {
    /// What is left of the month's credits, in percent.
    case monthlyPercent
    /// The month's credits that are left.
    case monthlyRemaining
    /// Everything that can be spent now, extra credits included.
    case available
}

/// One credits module's display and reminder choices.
public struct HarnessCreditsSettings: Codable, Equatable, Sendable {
    public static let expiryDayRange = 1...30
    public static let lowCreditsLimit = 1e9
    public var center: HarnessCreditsFigure
    public var bar: HarnessCreditsFigure
    /// The credits that count as low; nil follows a tenth of the month's credits.
    public var lowCredits: Double?
    /// Remind before extra credits lapse.
    public var expiryReminder: Bool
    /// How many days ahead count as soon, for the reminder and the dial.
    public var expiryDays: Int

    public init(center: HarnessCreditsFigure = .monthlyPercent, bar: HarnessCreditsFigure = .available, lowCredits: Double? = nil,
                expiryReminder: Bool = true, expiryDays: Int = 3) {
        self.center = center; self.bar = bar
        self.lowCredits = lowCredits.flatMap { (0...Self.lowCreditsLimit).contains($0) ? $0 : nil }
        self.expiryReminder = expiryReminder
        self.expiryDays = min(Self.expiryDayRange.upperBound, max(Self.expiryDayRange.lowerBound, expiryDays))
    }

    public static let `default` = Self()

    private enum CodingKeys: String, CodingKey { case center, bar, lowCredits, expiryReminder, expiryDays }
    /// Missing or unknown choices fall back one by one, so a newer or older host keeps the rest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func figure(_ key: CodingKeys, _ fallback: HarnessCreditsFigure) -> HarnessCreditsFigure {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap(HarnessCreditsFigure.init(rawValue:)) ?? fallback
        }
        self.init(center: figure(.center, .monthlyPercent), bar: figure(.bar, .available),
                  lowCredits: (try? container.decodeIfPresent(Double.self, forKey: .lowCredits)) ?? nil,
                  expiryReminder: ((try? container.decodeIfPresent(Bool.self, forKey: .expiryReminder)) ?? nil) ?? true,
                  expiryDays: ((try? container.decodeIfPresent(Int.self, forKey: .expiryDays)) ?? nil) ?? 3)
    }
}

/// Where a module's account credits come from. Hosts sign in on the site in
/// their own web view, then run the summary script against the bill.
public struct HarnessAccountCreditsDefinition: Sendable {
    public struct Site: Equatable, Sendable {
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
