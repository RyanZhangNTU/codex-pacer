#if canImport(PacerMacSupport)
import PacerMacSupport
#else
@testable import PacerEngineSupport
#endif
import XCTest
@testable import PacerCore

final class ClaudeSSHRouteProjectionTests: XCTestCase {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func testOnlyValidatedCanonicalRoutingFieldsSurviveConfigurationProjection() {
        let route = ClaudeSSHRouteResolver.parse(data("hostname GPU.Example.\nuser fixture_user\nport 2200\nidentityfile PRIVATE\nproxycommand PRIVATE\n"))
        XCTAssertEqual(route, ClaudeSSHRoute(hostname: "gpu.example", user: "fixture_user", port: 2200))
        XCTAssertFalse(String(describing: route).contains("PRIVATE"))
        XCTAssertNotNil(ClaudeSSHRouteResolver.parse(data("hostname ::1\nuser fixture\nport 22\n")))
        XCTAssertEqual(ClaudeSSHRouteResolver.parse(data("hostname 0:0:0:0:0:0:0:1\nuser fixture\nport 22\n"))?.hostname, "::1")
        for invalid in ["hostname host\nuser fixture\n", "hostname host\nuser fixture\nport 0\n",
                        "hostname host\nuser fixture\nport 65536\n", "hostname host\nuser fixture\nport +22\n",
                        "hostname -option\nuser fixture\nport 22\n", "hostname host;command\nuser fixture\nport 22\n",
                        "hostname host\nuser user@host\nport 22\n", "hostname a\nhostname b\nuser fixture\nport 22\n"] {
            XCTAssertNil(ClaudeSSHRouteResolver.parse(data(invalid)))
        }
        XCTAssertNil(ClaudeSSHRouteResolver.parse(Data([255])))
        XCTAssertNil(ClaudeSSHRouteResolver.parse(Data(repeating: 120, count: 65537)))
    }
}
