import XCTest
@testable import PacerCore
@testable import PacerMacSupport

final class MacDurableCatalogTests: XCTestCase {
    func testRetriesKeepTheSameBoundaryUntilTheAccountOrCatalogChanges() {
        var account = MacDurableCatalog.AccountPublication()
        XCTAssertEqual(account.verify("first"), .accountVerified("first"))
        XCTAssertNil(account.suspend(), "A verified account without a catalog is already suspended")
        XCTAssertNil(account.verify("first"), "A socket retry with the same account adds no boundary")

        account.catalogAvailable()
        XCTAssertEqual(account.suspend(), .suspended)
        XCTAssertNil(account.suspend())
        XCTAssertNil(account.verify("first"))
        XCTAssertEqual(account.scope, "first")
        XCTAssertEqual(account.verify("other"), .accountVerified("other"))
        XCTAssertNil(account.suspend())

        XCTAssertEqual(account.revoke(), .revoked)
        XCTAssertNil(account.scope)
        XCTAssertNil(account.revoke())
        XCTAssertNil(account.suspend())
        XCTAssertEqual(account.verify("other"), .accountVerified("other"))
    }
}
