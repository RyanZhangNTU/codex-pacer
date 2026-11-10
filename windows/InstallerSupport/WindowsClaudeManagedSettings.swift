import Foundation
import PacerCore
import WinSDK

/// Settings an organization manages for Claude Code on this PC: the managed
/// settings file and its drop-in folder, and the `Settings` JSON value under
/// the machine and user policy keys. They are read only to learn whether they
/// claim Claude's trace exporter.
enum WindowsClaudeManagedSettings {
    static let folder = URL(fileURLWithPath: "C:/Program Files/ClaudeCode")
    static let policyKey = "SOFTWARE\\Policies\\ClaudeCode", policyValue = "Settings"
    static func telemetry(folder: URL = folder, policies: [String] = policyDocuments()) -> ClaudeManagedTelemetry {
        var result = ClaudeManagedTelemetry()
        for document in policies { result.merge(json: Data(document.utf8)) }
        if let data = small(folder.appendingPathComponent("managed-settings.json")) { result.merge(json: data) }
        let dropIns = folder.appendingPathComponent("managed-settings.d")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dropIns.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().prefix(64)
        for name in names { if let data = small(dropIns.appendingPathComponent(name)) { result.merge(json: data) } }
        return result
    }
    /// String values of `value` under `key` in HKLM, then HKCU. Other value
    /// types and missing keys are skipped. Tests pass a key that always exists.
    static func policyDocuments(key: String = policyKey, value: String = policyValue) -> [String] {
        // HKEY_LOCAL_MACHINE and HKEY_CURRENT_USER are C cast macros that
        // Swift does not import; their values are sign-extended LONGs.
        [0x8000_0002, 0x8000_0001].compactMap { (handle: UInt32) -> String? in
            guard let root = HKEY(bitPattern: Int(Int32(bitPattern: handle))) else { return nil }
            var size: DWORD = 0
            let key = key.wide, value = value.wide
            guard RegGetValueW(root, key, value, DWORD(RRF_RT_REG_SZ), nil, nil, &size) == LSTATUS(ERROR_SUCCESS),
                  size > 0, size <= 2 * 1024 * 1024 else { return nil }
            var buffer = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
            size = DWORD(buffer.count * MemoryLayout<UInt16>.size)
            guard RegGetValueW(root, key, value, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size) == LSTATUS(ERROR_SUCCESS) else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
        }
    }
    private static func small(_ url: URL) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= 2 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
}

private extension String {
    var wide: [UInt16] { Array(utf16) + [0] }
}
