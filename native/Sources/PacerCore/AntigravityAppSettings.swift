import Foundation

/// Antigravity's own app settings, `app_storage.json` in its Electron user
/// data folder. Pacer reads one of them: "Keep in menu bar" (Settings,
/// Application), stored as `runInBackground`. Without it, closing the last
/// window quits Antigravity and its language server, so its quota can no
/// longer be read until Antigravity opens again.
package enum AntigravityAppSettings {
    package static let filename = "app_storage.json"
    package static let runInBackgroundKey = "runInBackground"
    package static let maximumBytes = 4 * 1024 * 1024

    /// Whether closing every window leaves Antigravity running, read as
    /// Antigravity reads it: only the string "true" turns it on. A missing
    /// file, value or damaged file means Antigravity's platform default, which
    /// is on for macOS only. `nil` when the file is too large to read.
    /// - Parameter data: the file's bytes, or `nil` when there is no file.
    package static func keepsRunning(_ data: Data?, platformDefault: Bool) -> Bool? {
        guard let data else { return platformDefault }
        guard data.count <= maximumBytes else { return nil }
        guard let document = try? JSONFieldView.document(data, maximumBytes: maximumBytes), document.isObject,
              let value = try? document.fields([runInBackgroundKey])[runInBackgroundKey], !value.isNull else { return platformDefault }
        return value.string(limit: 8) == "true"
    }
}
