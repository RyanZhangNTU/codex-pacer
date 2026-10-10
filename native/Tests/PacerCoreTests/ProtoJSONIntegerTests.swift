import XCTest
@testable import PacerCore

final class ProtoJSONIntegerTests: XCTestCase {
    private func view(_ literal: String) throws -> JSONFieldView {
        try JSONFieldView.document(Data(literal.utf8))
    }

    func testQuotedAndNumericExponentIntegersPreserveExact64BitBoundaries() throws {
        for literal in ["100", "1e2", "1.5e2", #""1e2""#, #""1.5e2""#, #""000100.0""#] {
            let value = try view(literal)
            XCTAssertEqual(value.unsignedInteger(), literal.contains("1.5") ? 150 : 100)
            XCTAssertEqual(value.signedInteger(), literal.contains("1.5") ? 150 : 100)
        }
        for literal in ["18446744073709551615", #""18446744073709551615""#, #""1.8446744073709551615e19""#] {
            XCTAssertEqual(try view(literal).unsignedInteger(), UInt64.max)
            XCTAssertNil(try view(literal).signedInteger())
        }
        XCTAssertEqual(try view(#""-9.223372036854775808e18""#).signedInteger(), Int64.min)
        XCTAssertEqual(try view("9223372036854775807").signedInteger(), Int64.max)
        XCTAssertNil(try view("-1").unsignedInteger())
        // Existing Codex scalar extraction still follows its original contract.
        XCTAssertNil(try view("1e2").integer())
        XCTAssertNil(try view(#""100""#).integer())
        XCTAssertEqual(try view("100").integer(), 100)
    }

    func testFractionBooleanOverflowAndOversizeCannotRoundOrTruncateIntoIntegers() throws {
        let invalid = ["true", "false", "null", "1.5", #""1.5""#, #""1.0000000000000000001""#,
                       "1e-2", #""1e-2""#, #""NaN""#, #""Infinity""#, #"" 100 ""#,
                       #""1e999999999999999999999999999999""#,
                       "18446744073709551616", #""18446744073709551616""#]
        for literal in invalid {
            XCTAssertNil(try view(literal).unsignedInteger(), literal)
            XCTAssertNil(try view(literal).signedInteger(), literal)
        }
        let oversized = try JSONEncoder().encode(String(repeating: "0", count: 128) + "1")
        let value = try JSONFieldView.document(oversized)
        XCTAssertNil(value.unsignedInteger())
        XCTAssertNil(value.signedInteger())
        let boundedZero = try JSONEncoder().encode(String(repeating: "0", count: 128))
        XCTAssertEqual(try JSONFieldView.document(boundedZero).unsignedInteger(), 0)
    }
}
