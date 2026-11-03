import Foundation
import CommonCrypto
import PacerCore

extension ClaudeDesktopCredentialStore {
    /// Chromium's macOS v10 format uses PBKDF2-HMAC-SHA1(password, saltysalt,
    /// 1003), AES-128-CBC with a 16-space IV, and PKCS7 padding. Unknown formats
    /// fail closed. Only the decrypted token-cache object is interpreted.
    public static func decryptV10(_ encrypted: Data, password: Data) -> Data? {
        guard var key = deriveKey(password: password) else { return nil }
        defer { key.resetBytes(in: 0..<key.count) }
        return decryptV10(encrypted, derivedKey: key)
    }

    public static func deriveKey(password: Data) -> Data? {
        guard !password.isEmpty, password.count <= 4096 else { return nil }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: Int8.self).baseAddress,
                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        return Data(key)
    }

    public static func decryptV10(_ encrypted: Data, derivedKey: Data) -> Data? {
        guard encrypted.count <= 2 * 1024 * 1024, encrypted.count >= 19,
              encrypted.starts(with: Data("v10".utf8)), (encrypted.count - 3) % kCCBlockSizeAES128 == 0,
              derivedKey.count == kCCKeySizeAES128 else { return nil }
        let ciphertext = encrypted.dropFirst(3)
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        defer { _ = plaintext.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var count = 0
        let status = derivedKey.withUnsafeBytes { key in ciphertext.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key.baseAddress, key.count, iv, bytes.baseAddress, ciphertext.count, &plaintext, plaintext.count, &count)
        }
        }
        guard status == kCCSuccess, count > 0 else { return nil }
        return Data(plaintext.prefix(count))
    }
}
