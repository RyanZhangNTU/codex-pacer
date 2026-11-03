import CWindowsSupport

/// The shared sources use only CryptoKit's one-shot SHA-256 operation.
/// Windows computes it with CNG instead of carrying a second crypto library.
public enum SHA256 {
    public static func hash<D: Collection>(data: D) -> [UInt8] where D.Element == UInt8 {
        let bytes = Array(data)
        var digest = [UInt8](repeating: 0, count: 32)
        let success = bytes.withUnsafeBufferPointer { input in
            digest.withUnsafeMutableBufferPointer { output in
                pacer_sha256(input.baseAddress, input.count, output.baseAddress)
            }
        }
        precondition(success != 0, "SHA-256 provider unavailable")
        return digest
    }
}
