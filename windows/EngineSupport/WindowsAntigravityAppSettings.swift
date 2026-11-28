import Foundation
import PacerCore

/// Antigravity's own settings file, in the Electron user data folder
/// `%APPDATA%\Antigravity`. On Windows "Keep in menu bar" starts off, so
/// closing the last window quits Antigravity and stops its quota.
enum WindowsAntigravityAppSettings {
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let roaming = WindowsEnvironment.value("APPDATA", in: environment), WindowsURLHandler.localDrivePath(roaming) else { return nil }
        return URL(fileURLWithPath: roaming, isDirectory: true).appendingPathComponent("Antigravity", isDirectory: true)
            .appendingPathComponent(AntigravityAppSettings.filename, isDirectory: false)
    }

    /// Whether Antigravity keeps running after its last window closes, or `nil`
    /// while the file can't be read, such as during Antigravity's own write.
    static func keepsRunning(at url: URL, files: WindowsFileSystem = WindowsFileSystem()) -> Bool? {
        guard let info = files.metadata(url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : AntigravityAppSettings.keepsRunning(nil, platformDefault: false)
        }
        guard info.isRegularFile, info.size <= UInt64(AntigravityAppSettings.maximumBytes),
              let data = try? files.read(url, offset: 0, maximumBytes: AntigravityAppSettings.maximumBytes + 1),
              data.count == Int(info.size) else { return nil }
        return AntigravityAppSettings.keepsRunning(data, platformDefault: false)
    }
}
