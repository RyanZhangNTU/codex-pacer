import Foundation

private let testDefaultsFolderPrefix = "codex-pacer-test-defaults."

/// A unique `UserDefaults` suite name for a test.
///
/// A suite named by an absolute path keeps its plist at that path instead of
/// `~/Library/Preferences`. A reverse-DNS test suite leaves an empty plist there
/// after `removePersistentDomain(forName:)`, because cfprefsd writes it later.
/// Windows builds `PacerCoreTests` without this target; see `TestDefaults.swift` there.
public func testDefaultsName(_ label: String) -> String {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(testDefaultsFolderPrefix + label + "." + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("defaults").path
}

/// Clears a suite made by `testDefaultsName(_:)` and deletes its folder.
public func removeTestDefaults(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    UserDefaults(suiteName: name)?.synchronize()
    let folder = URL(fileURLWithPath: name).deletingLastPathComponent()
    guard folder.lastPathComponent.hasPrefix(testDefaultsFolderPrefix) else { return }
    try? FileManager.default.removeItem(at: folder)
}
