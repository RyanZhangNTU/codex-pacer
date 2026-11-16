import XCTest
@testable import PacerCore

/// The bar on its side: the number on top at full size, what it counts under it.
final class CompactStripFigureTests: XCTestCase {
    private func assert(_ figure: CompactStripFigure, _ number: String, _ unit: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(figure.number, number, file: file, line: line)
        XCTAssertEqual(figure.unit, unit, file: file, line: line)
    }

    func testPercentagesKeepWholeNumbersOverTheirSign() {
        assert(.percent(58), "58", "%")
        assert(.percent(219.4), "219", "%")
        assert(.percent(nil), "—", "%")
    }

    func testCreditsShowOneDecimalUpToThreeDigitsAndMoveTheMagnitudeUnder() {
        assert(.amount(850), "850", nil)
        assert(.amount(5.5), "5.5", nil)
        assert(.amount(5), "5", nil)
        assert(.amount(1_234), "1.2", "k")
        assert(.amount(12_345), "12.3", "k")
        assert(.amount(123_456), "123", "k")
        assert(.amount(1_234_567), "1.2", "M")
        // The shown figure decides: 999.6 is 1k, 99.96 is 100, never 1000 or 100.0.
        assert(.amount(999.6), "1", "k")
        assert(.amount(99.96), "100", nil)
        assert(.amount(999_600), "1", "M")
        assert(.amount(nil), "—", nil)
    }

    func testMoneyRoundsDownAndCarriesItsSymbolAfterTheMagnitude() {
        assert(.amount(5.63, symbol: "¥", roundsDown: true), "5.6", "¥")
        assert(.amount(64.59, symbol: "¥", roundsDown: true), "64.5", "¥")
        assert(.amount(123.4, symbol: "¥", roundsDown: true), "123", "¥")
        assert(.amount(12_345, symbol: "¥", roundsDown: true), "12.3", "k¥")
        assert(.amount(999.99, symbol: "¥", roundsDown: true), "999", "¥")
        assert(.amount(86.96, symbol: "¥", roundsDown: true), "86.9", "¥")
        assert(.amount(12.5, symbol: "$"), "12.5", "$")
        assert(.amount(nil, symbol: "¥"), "—", "¥")
    }

    func testAMinusSignLeavesNoRoomForADecimal() {
        assert(.amount(-3.27, symbol: "¥", roundsDown: true), "−3", "¥")
        assert(.amount(-64.2, symbol: "¥", roundsDown: true), "−64", "¥")
        assert(.amount(-0.3, symbol: "¥", roundsDown: true), "0", "¥")
    }

    func testRatesPadThreeDigitsAndPutTheirMagnitudeBesideTheUnit() {
        assert(.rate(nil), "000", "t/s")
        assert(.rate(42), "042", "t/s")
        assert(.rate(104), "104", "t/s")
        assert(.rate(1_234), "1.2", "k t/s")
    }

    /// Every number fits three digits plus a point or a minus sign, the most
    /// the strip draws at full size.
    func testEveryNumberStaysWithinTheStripsWidth() {
        let values: [Double] = [0, 0.04, 0.5, 5, 9.96, 12.3, 99.4, 99.96, 123.4, 999.4, 999.6, 1_000, 9_999, 12_345,
                                99_949, 99_960, 123_456, 999_499, 999_600, 1_234_567, 99_999_999, 999_400_000]
        for value in values {
            for figure in [CompactStripFigure.amount(value), .amount(value, symbol: "¥", roundsDown: true),
                           .amount(-value, symbol: "¥", roundsDown: true), .rate(value)] {
                XCTAssertLessThanOrEqual(figure.number.filter(\.isNumber).count, 3, "\(value) → \(figure.number)")
                XCTAssertLessThanOrEqual(figure.number.count, 4, "\(value) → \(figure.number)")
            }
        }
    }
}
