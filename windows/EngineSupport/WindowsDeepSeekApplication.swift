#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

/// Desktop metadata from the official Harness package. CLI/session detection
/// remains independent; opening an app requires a validated desktop binary.
public enum WindowsDeepSeekApplication {
    public static let filename = "DeepSeek Harness.exe"
    private static let product = Array("DeepSeek Harness".utf16) + [0]
    // Keep these aligned with binary provenance, not the package.json author.
    // 0.2.2 and later carry DeepSeek's own CompanyName, the name they are signed
    // with; the published 0.2.1-rc.5 desktop retained Electron's.
    private static let companies = ["Hangzhou DeepSeek Artificial Intelligence Co., Ltd.", "GitHub, Inc."].map { Array($0.utf16) + [0] }

    public static func isApplication(_ url: URL) -> Bool {
        guard url.isFileURL, url.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame else { return false }
        let path = WindowsCodexExecutableDiscovery.path(url)
        guard localPath(path) else { return false }
        let wide = Array(path.utf16) + [0]
        return companies.contains { pacer_windows_product_matches(wide, product, $0) != 0 }
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
