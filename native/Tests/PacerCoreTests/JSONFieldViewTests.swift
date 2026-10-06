import XCTest
@testable import PacerCore

final class JSONFieldViewTests: XCTestCase {
    func testViewsSkipLargeUnusedBodiesAndRetainOnlySelectedFields() throws {
        let text = String(repeating: "PRIVATE", count: 200_000)
        let bytes = try JSONSerialization.data(withJSONObject: ["body": text, "nested": ["token": 12], "name": "名称😀"])
        let view = try JSONFieldView.document(bytes)
        let fields = try view.fields(["nested", "name"])
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields["name"]?.string(), "名称😀")
        XCTAssertEqual(try fields["nested"]?.fields(["token"])["token"]?.integer(), 12)
        XCTAssertNil(fields["body"])
    }
    func testMalformedSkippedDataCannotManufactureAValidFrame() {
        for body in [#"{"known":1,"ignored":[1,]}"#, #"{"known":1,"ignored":"\uD800"}"#,
                     #"{"known":1,"ignored":01}"#, #"{"known":1} false"#,
                     #"{"ignored": [truex]}"#, #"{"ignored":"\x00"}"#] {
            XCTAssertThrowsError(try JSONFieldView.document(Data(body.utf8)))
        }
        XCTAssertThrowsError(try JSONFieldView.document(Data([34, 0xC0, 0x80, 34])))
    }
    func testEscapesDuplicateKeysNumbersAndContainerBounds() throws {
        let value = try JSONFieldView.document(Data(#"{"a":1,"a":2,"unicode":"\uD83D\uDE00","float":-1.5e2,"items":[null,true,{"id":"x"}]}"#.utf8))
        let fields = try value.fields()
        XCTAssertEqual(fields["a"]?.integer(), 2)
        XCTAssertEqual(fields["unicode"]?.string(), "😀")
        XCTAssertEqual(fields["float"]?.number(), -150)
        XCTAssertNil(fields["float"]?.integer())
        XCTAssertEqual(try fields["items"]?.countElements(), 3)
        XCTAssertThrowsError(try fields["items"]?.elements(maximumCount: 2))
    }
}
