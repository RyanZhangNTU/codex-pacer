import Foundation

/// Choices that change how one collapsed-bar component draws. Each field
/// decodes on its own: a missing or unknown value falls back to its default,
/// so a damaged or newer preference never resets the other choices. Every
/// choice is edited in the Collapsed Bar page's selected-component card.
public struct CompactComponentOptions: Codable, Equatable, Sendable {
    /// What the activity badge's ring shows while several tasks run.
    public enum MultiRing: String, Codable, CaseIterable, Sendable { case service, average, segments }
    /// What the badge's core shows while several tasks run with an average ring.
    public enum MultiCore: String, Codable, CaseIterable, Sendable { case count, percent }
    public enum StatusShow: String, Codable, CaseIterable, Sendable { case urgent, stage, count }
    public enum StatusWidth: String, Codable, CaseIterable, Sendable {
        case short, medium, long
        /// The widest the status text may draw before its end fades out.
        public var points: Double {
            switch self {
            case .short: 72
            case .medium: 108
            case .long: 160
            }
        }
    }
    public enum RateMeasure: String, Codable, CaseIterable, Sendable { case total, average }
    public enum FirstOutputValue: String, Codable, CaseIterable, Sendable { case latest, median }
    public enum QuotaMultiple: String, Codable, CaseIterable, Sendable { case alternate, pair, lowest }
    public enum RingLayout: String, Codable, CaseIterable, Sendable { case concentric, sideBySide, split }
    public enum TimeStyle: String, Codable, CaseIterable, Sendable { case percent, countdown }
    public enum ClockShow: String, Codable, CaseIterable, Sendable { case always, peak }
    public enum WarningStyle: String, Codable, CaseIterable, Sendable { case capsule, dot }

    public static let defaultsKey = "compactComponentOptions"
    public static let version = 1
    /// Larger saved or requested text is damaged.
    public static let byteLimit = 4096
    /// Warnings shown before the rest fold into one "+N" mark; zero shows all.
    public static let warningLimits: ClosedRange<Int> = 0...6

    public var multiRing: MultiRing = .service
    public var multiCore: MultiCore = .count
    /// The small mark that keeps an unread ending visible beside running work.
    public var endMark = true
    public var statusShow: StatusShow = .urgent
    public var statusWidth: StatusWidth = .medium
    public var rateMeasure: RateMeasure = .total
    public var firstOutput: FirstOutputValue = .latest
    public var quotaMultiple: QuotaMultiple = .alternate
    public var ringLayout: RingLayout = .concentric
    /// The white tick that marks how much of each window's time remains.
    public var paceTick = true
    /// Quota at or below 15% turns amber, as in the expanded panel.
    public var lowColor = true
    /// While the quota value alternates beside two rings, the ring it is not
    /// naming dims; off keeps both rings at full strength.
    public var ringDim = true
    public var timeStyle: TimeStyle = .percent
    public var clockShow: ClockShow = .always
    public var warningStyle: WarningStyle = .capsule
    public var warningLimit = 2

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, multiRing, multiCore, endMark, statusShow, statusWidth, rateMeasure, firstOutput,
             quotaMultiple, ringLayout, paceTick, lowColor, ringDim, timeStyle, clockShow, warningStyle, warningLimit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = Self()
        multiRing = field(.multiRing, defaults.multiRing)
        multiCore = field(.multiCore, defaults.multiCore)
        endMark = field(.endMark, defaults.endMark)
        statusShow = field(.statusShow, defaults.statusShow)
        statusWidth = field(.statusWidth, defaults.statusWidth)
        rateMeasure = field(.rateMeasure, defaults.rateMeasure)
        firstOutput = field(.firstOutput, defaults.firstOutput)
        quotaMultiple = field(.quotaMultiple, defaults.quotaMultiple)
        ringLayout = field(.ringLayout, defaults.ringLayout)
        paceTick = field(.paceTick, defaults.paceTick)
        lowColor = field(.lowColor, defaults.lowColor)
        ringDim = field(.ringDim, defaults.ringDim)
        timeStyle = field(.timeStyle, defaults.timeStyle)
        clockShow = field(.clockShow, defaults.clockShow)
        warningStyle = field(.warningStyle, defaults.warningStyle)
        let limit = field(.warningLimit, defaults.warningLimit)
        warningLimit = Self.warningLimits.contains(limit) ? limit : defaults.warningLimit
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.version, forKey: .version)
        try values.encode(multiRing, forKey: .multiRing)
        try values.encode(multiCore, forKey: .multiCore)
        try values.encode(endMark, forKey: .endMark)
        try values.encode(statusShow, forKey: .statusShow)
        try values.encode(statusWidth, forKey: .statusWidth)
        try values.encode(rateMeasure, forKey: .rateMeasure)
        try values.encode(firstOutput, forKey: .firstOutput)
        try values.encode(quotaMultiple, forKey: .quotaMultiple)
        try values.encode(ringLayout, forKey: .ringLayout)
        try values.encode(paceTick, forKey: .paceTick)
        try values.encode(lowColor, forKey: .lowColor)
        try values.encode(ringDim, forKey: .ringDim)
        try values.encode(timeStyle, forKey: .timeStyle)
        try values.encode(clockShow, forKey: .clockShow)
        try values.encode(warningStyle, forKey: .warningStyle)
        try values.encode(warningLimit, forKey: .warningLimit)
    }

    /// Text that is missing, damaged or oversized reads as the defaults.
    public static func decode(_ json: String?) -> Self {
        guard let json, json.utf8.count <= byteLimit, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    /// The saved choices as sorted JSON, the form both hosts store and send.
    public var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Damaged or oversized data reads as the defaults, and nothing is written.
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= byteLimit,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(Data(json.utf8), forKey: Self.defaultsKey)
    }
}

/// The collapsed bar's size. Every metric scales from the standard bar, so the
/// four steps keep the same proportions. A Mac notch fixes the height of a bar
/// attached to it, so the size cannot change there.
public enum CompactBarSize: String, Codable, CaseIterable, Sendable {
    case small, standard, large, extraLarge

    public static let defaultsKey = "compactBarSize"

    public var scale: Double {
        switch self {
        case .small: 32.0 / 36
        case .standard: 1
        case .large: 42.0 / 36
        case .extraLarge: 48.0 / 36
        }
    }

    public var label: String { L10n.text("appearance.bar_size." + rawValue) }
    public var metrics: CompactBarMetrics { CompactBarMetrics(scale: scale) }

    /// Only a bar attached to a real camera housing keeps the hardware height.
    public static func isAdjustable(attached: Bool, hardwareNotch: Bool) -> Bool { !(attached && hardwareNotch) }

    /// The size the bar draws at: the saved one, or standard where it cannot change.
    public func effective(attached: Bool, hardwareNotch: Bool) -> Self {
        Self.isAdjustable(attached: attached, hardwareNotch: hardwareNotch) ? self : .standard
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .standard
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Points for one size of the collapsed bar. Structural lengths round to whole
/// points so edges stay crisp; type sizes round to half points.
public struct CompactBarMetrics: Codable, Equatable, Sendable {
    /// The size's factor over the standard bar.
    public let scale: Double
    /// Height of a bar that is not attached to a hardware notch.
    public let height: Double
    /// Width of the bar turned on its side at a docked edge.
    public let stripWidth: Double
    /// Space between the bar's ends and its first and last components.
    public let inset: Double
    /// Space between components in one lane.
    public let gap: Double
    /// Space between the two lanes; a hairline of `divider` points sits in it.
    public let laneGap: Double
    public let divider: Double
    public let value: Double
    public let unit: Double
    public let status: Double
    public let badge: Double
    public let gauge: Double
    /// Height of a warning capsule.
    public let warning: Double
    public let stripValue: Double
    public let stripUnit: Double
    public let stripInset: Double
    public let stripGap: Double
    /// Radius of the concave fillet where an attached bar meets the screen edge.
    public let shoulder: Double
    /// Radius of an attached bar's free corners.
    public let radius: Double

    public static let standard = CompactBarMetrics(scale: 1)

    public init(scale: Double) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        self.scale = scale
        func whole(_ value: Double) -> Double { (value * scale).rounded() }
        func half(_ value: Double) -> Double { (value * scale * 2).rounded() / 2 }
        height = whole(36); stripWidth = whole(32); inset = whole(13); gap = whole(8)
        laneGap = whole(16); divider = whole(14)
        value = half(13); unit = half(10); status = half(12.5)
        badge = whole(22); gauge = whole(20); warning = whole(15)
        stripValue = half(11.5); stripUnit = half(9); stripInset = whole(10); stripGap = whole(8)
        shoulder = whole(8); radius = whole(19)
    }
}
