import XCTest
import PacerCore
import CodexPacerPortablePackageDiscoveredTests

// All portable suites use XCTest. Keep SwiftPM discovery, without importing
// the optional Swift Testing overlays into the Windows test runner.
@main
@available(*, deprecated, message: "SwiftPM discovery permits deprecated test cases through this compatibility entry point.")
struct WindowsTestRunner {
    static func main() {
        WindowsResources.configure()
        XCTMain(__allDiscoveredTests())
    }
}
