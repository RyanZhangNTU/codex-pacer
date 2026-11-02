import Foundation
import CWindowsSupport

/// The shared sources use only CryptoKit's one-shot SHA-256 operation.
/// Windows computes it with CNG instead of carrying a second crypto library.
public enum SHA256 {
    public static func hash<D: DataProtocol>(data: D) -> [UInt8] {
        let bytes = Data(data)
        var digest = [UInt8](repeating: 0, count: 32)
        let success = bytes.withUnsafeBytes { raw in
            pacer_sha256(raw.bindMemory(to: UInt8.self).baseAddress, bytes.count, &digest)
        }
        precondition(success != 0, "SHA-256 provider unavailable")
        return digest
    }
}
