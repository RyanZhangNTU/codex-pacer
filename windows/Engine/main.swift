import Foundation
import PacerEngineSupport
import PacerCore

if WindowsPlatformCompatibility.supports(ProcessInfo.processInfo.operatingSystemVersion) {
    await PacerEngine.run()
} else {
    try? FileHandle.standardError.write(contentsOf: Data("Codex Pacer requires Windows 10 build 19041 or later.\n".utf8))
    exit(1)
}
