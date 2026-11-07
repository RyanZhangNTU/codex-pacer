// The Mac builds the shared PacerTestSupport helper. The Windows engine build
// compiles this directory without it, so it gets the same two functions here.
#if canImport(PacerTestSupport)
@_exported import PacerTestSupport
#else
import Foundation

func testDefaultsName(_ label: String) -> String {
    "com.codexpacer." + label + "." + UUID().uuidString
}

func removeTestDefaults(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
}
#endif
