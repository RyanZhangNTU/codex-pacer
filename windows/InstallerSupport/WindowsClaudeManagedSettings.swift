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
    enum Root: UInt32 { case machine = 0x8000_0002, user = 0x8000_0001 }
    /// Claude Code takes each variable from HKLM policy first, then the
    /// managed files, and reads HKCU policy only when neither holds a document.
    static func telemetry(folder: URL = folder, machine: String? = policyDocument(.machine),
                          user: String? = policyDocument(.user)) -> ClaudeManagedTelemetry {
        var result = ClaudeManagedTelemetry(), machineFound = false
        if let machine { var source = ClaudeManagedTelemetry(); machineFound = source.merge(json: Data(machine.utf8)); result.fill(source) }
        let files = ClaudeManagedTelemetry.files(in: folder)
        result.fill(files.value)
        if !machineFound, !files.found, let user { var source = ClaudeManagedTelemetry(); source.merge(json: Data(user.utf8)); result.fill(source) }
        return result
    }
    /// The string value of `value` under `key` in one root. Other value types
    /// and missing keys give nil. Tests pass a key that always exists.
    static func policyDocument(_ root: Root, key: String = policyKey, value: String = policyValue) -> String? {
        // HKEY_LOCAL_MACHINE and HKEY_CURRENT_USER are C cast macros that
        // Swift does not import; their values are sign-extended LONGs.
        guard let handle = HKEY(bitPattern: Int(Int32(bitPattern: root.rawValue))) else { return nil }
        var size: DWORD = 0
        let key = key.wide, value = value.wide
        guard RegGetValueW(handle, key, value, DWORD(RRF_RT_REG_SZ), nil, nil, &size) == LSTATUS(ERROR_SUCCESS),
              size > 0, size <= 2 * 1024 * 1024 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
        size = DWORD(buffer.count * MemoryLayout<UInt16>.size)
        guard RegGetValueW(handle, key, value, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size) == LSTATUS(ERROR_SUCCESS) else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }
}

private extension String {
    var wide: [UInt16] { Array(utf16) + [0] }
}
