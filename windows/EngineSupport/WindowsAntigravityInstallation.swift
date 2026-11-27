import CWindowsSupport
import Foundation
import PacerCore
import WinSDK

final class WindowsAntigravityInstallation: @unchecked Sendable {
    static let shared = WindowsAntigravityInstallation()
    static let filename = "Antigravity.exe"
    static let serverPath = "resources/bin/language_server.exe"

    private let lock = NSLock()
    private let matchesVersion: (URL) -> Bool
    private var cached: (app: URL, stamp: [PlatformFileMetadata])?

    init(matchesVersion: @escaping (URL) -> Bool = {
        pacer_antigravity_product_matches(WindowsFiles.wide($0)) != 0
    }) {
        self.matchesVersion = matchesVersion
    }

    static func candidates(environment: [String: String]) -> [URL] {
        var result: [URL] = []
        func candidate(_ field: String, uninstall: Bool) {
            let text = field.trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: #"^(?:"[^"]+\.exe"|.+?\.exe(?=$|,|\s))"#,
                                         options: [.regularExpression, .caseInsensitive]) else { return }
            let value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard WindowsURLHandler.localDrivePath(value) else { return }
            let url = URL(fileURLWithPath: value)
            result.append(uninstall ? url.deletingLastPathComponent().appendingPathComponent(filename) : url)
        }
        var index: UInt32 = 0
        var icon = [UInt16](repeating: 0, count: 32768), uninstall = icon
        while pacer_antigravity_uninstall_entry(&index, &icon, &uninstall, 32768) != 0 {
            candidate(String(decoding: icon.prefix { $0 != 0 }, as: UTF16.self), uninstall: false)
            candidate(String(decoding: uninstall.prefix { $0 != 0 }, as: UTF16.self), uninstall: true)
        }
        var handler = [UInt16](repeating: 0, count: 32768)
        if pacer_url_handler_path(Array("antigravity".utf16) + [0], 0, &handler, handler.count) != 0 {
            let value = String(decoding: handler.prefix { $0 != 0 }, as: UTF16.self)
            if WindowsURLHandler.localDrivePath(value) { result.append(URL(fileURLWithPath: value)) }
        }
        if let local = WindowsEnvironment.value("LOCALAPPDATA", in: environment), WindowsURLHandler.localDrivePath(local) {
            result.append(URL(fileURLWithPath: local).appendingPathComponent("Programs/antigravity/" + filename))
        }
        return result
    }

    private func stamp(_ app: URL) -> [PlatformFileMetadata]? {
        let path = WindowsCodexExecutableDiscovery.path(app)
        guard WindowsURLHandler.localDrivePath(path), app.lastPathComponent.caseInsensitiveCompare(Self.filename) == .orderedSame,
              GetDriveTypeW(Array(path.prefix(3).utf16) + [0]) == DRIVE_FIXED else { return nil }
        let server = app.deletingLastPathComponent().appendingPathComponent(Self.serverPath)
        var directory = server.deletingLastPathComponent()
        while directory.path.count > 3 {
            let attributes = GetFileAttributesW(WindowsFiles.wide(directory))
            guard attributes != INVALID_FILE_ATTRIBUTES, attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { return nil }
            directory = directory.deletingLastPathComponent()
        }
        let files = WindowsFileSystem()
        guard let main = files.metadata(app, followingSymbolicLinks: false), main.isRegularFile,
              let peer = files.metadata(server, followingSymbolicLinks: false), peer.isRegularFile else { return nil }
        return [main, peer]
    }

    func resolve(candidates: () -> [URL] = { WindowsAntigravityInstallation.candidates(environment: ProcessInfo.processInfo.environment) }) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let cached, stamp(cached.app) == cached.stamp { return cached.app }
        cached = nil
        for app in candidates().map(\.standardizedFileURL) {
            if let before = stamp(app), matchesVersion(app), before == stamp(app) {
                cached = (app, before)
                return app
            }
        }
        return nil
    }
}
