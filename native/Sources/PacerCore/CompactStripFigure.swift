import Foundation

/// A value in the collapsed bar turned on its side at a docked edge: the
/// number on top, and under it what the number counts, a symbol, a magnitude
/// or both, so the number keeps the strip's full size.
///
/// The number shows at most one decimal, and none once it would have more than
/// three digits or carry a minus sign. Thousands and millions move to the unit
/// as `k` and `M`, before any currency: `1.2` over `k¥`.
public struct CompactStripFigure: Codable, Equatable, Sendable {
    public let number: String
    public let unit: String?

    public init(number: String, unit: String?) {
        self.number = number; self.unit = unit?.isEmpty == true ? nil : unit
    }

    /// An amount such as credits or a balance, with its currency symbol, if
    /// any. Money rounds down, as the bar's balance does, so it never shows
    /// more than there is.
    public static func amount(_ value: Double?, symbol: String? = nil, roundsDown: Bool = false) -> Self {
        guard let value, value.isFinite else { return .init(number: "—", unit: symbol) }
        let negative = value < 0
        var scaled = abs(value), magnitude = ""
        func whole(_ value: Double) -> Double { roundsDown ? value.rounded(.down) : value.rounded() }
        // The magnitude follows the shown figure, so 999.6 credits read 1k, not 1000.
        if whole(scaled) >= 1000 { scaled /= 1000; magnitude = "k" }
        if whole(scaled) >= 1000 { scaled /= 1000; magnitude = "M" }
        return .init(number: digits(scaled, negative: negative, roundsDown: roundsDown), unit: magnitude + (symbol ?? ""))
    }

    /// A whole percentage over `%`.
    public static func percent(_ value: Double?) -> Self {
        .init(number: value.map { String(Int($0.rounded())) } ?? "—", unit: "%")
    }

    /// Tokens per second: three padded digits, or the amount's short form with
    /// its magnitude beside the unit.
    public static func rate(_ value: Double?) -> Self {
        guard let value, value.isFinite else { return .init(number: "000", unit: "t/s") }
        guard value.rounded() >= 1000 else { return .init(number: String(format: "%03.0f", max(0, value)), unit: "t/s") }
        let figure = amount(value)
        return .init(number: figure.number, unit: (figure.unit.map { $0 + " " } ?? "") + "t/s")
    }

    private static func digits(_ value: Double, negative: Bool, roundsDown: Bool) -> String {
        let decimal = String(format: "%.1f", roundsDown ? (value * 10).rounded(.down) / 10 : value)
        if !negative, !decimal.hasSuffix(".0"), decimal.filter(\.isNumber).count <= 3 { return decimal }
        let whole = Int(roundsDown ? value.rounded(.down) : value.rounded())
        return negative && whole > 0 ? "−" + String(whole) : String(whole)
    }
}
