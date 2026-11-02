#if os(Windows)
import Foundation
import CWindowsSupport

/// Desktop metadata from the official Harness package. CLI/session detection
/// remains independent; opening an app requires a validated desktop binary.
public enum WindowsDeepSeekApplication {
    public static let filename = "DeepSeek Harness.exe"
    private static let product = Array("DeepSeek Harness".utf16) + [0]
    // The published 0.2.1-rc.5 desktop retains Electron's CompanyName. It is
    // not the package.json author; keep this aligned with binary provenance.
    private static let company = Array("GitHub, Inc.".utf16) + [0]

    public static func isApplication(_ url: URL) -> Bool {
        guard url.isFileURL, url.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame else { return false }
        let path = WindowsCodexExecutableDiscovery.path(url)
        guard localPath(path) else { return false }
        return pacer_windows_product_matches(Array(path.utf16) + [0], product, company) != 0
    }
    public static func find(applicationURLs: [URL]? = nil, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            registeredPaths: () -> [String] = registryPaths) -> URL? {
        var candidates: [URL] = []
        if let applicationURLs {
            candidates = applicationURLs.prefix(12).flatMap { root in
                root.pathExtension.caseInsensitiveCompare("exe") == .orderedSame ? [root]
                    : [root.appendingPathComponent(filename), root.appendingPathComponent("app/" + filename)]
            }
        } else {
            candidates = registeredPaths().prefix(4).filter(localPath).map { URL(fileURLWithPath: $0) }
            let local = WindowsEnvironment.value("LOCALAPPDATA", in: environment)
                ?? WindowsCodexExecutableDiscovery.path(userHome.appendingPathComponent("AppData/Local"))
            if localPath(local) { candidates.append(URL(fileURLWithPath: local).appendingPathComponent("Programs/DeepSeek Harness/" + filename)) }
        }
        var seen = Set<String>()
        return candidates.prefix(28).first { seen.insert(WindowsCodexExecutableDiscovery.path($0).lowercased()).inserted && isApplication($0) }
    }
    public static func registryPaths() -> [String] {
        (0..<4).compactMap { index in
            var path = [UInt16](repeating: 0, count: 32768)
            guard pacer_harness_registry_path(index, &path, path.count) != 0 else { return nil }
            return String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
        }
    }
    private static func localPath(_ value: String) -> Bool {
        value.utf16.count < 32768 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }
}
#endif
