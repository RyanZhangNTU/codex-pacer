// Prints the public key of the Sparkle EdDSA private key on standard input, in the
// form `generate_keys -x` exports it: the base64 of a 32-byte seed, or of a legacy
// 64-byte private key followed by its 32-byte public key.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let line = readLine(), let key = Data(base64Encoded: line.trimmingCharacters(in: .whitespaces)) else {
    fail("The Sparkle private key is not base64.")
}
switch key.count {
case 32:
    guard let seed = try? Curve25519.Signing.PrivateKey(rawRepresentation: key) else { fail("The Sparkle private key is invalid.") }
    print(seed.publicKey.rawRepresentation.base64EncodedString())
case 96:
    print(key.suffix(32).base64EncodedString())
default:
    fail("The Sparkle private key has an unexpected length.")
}
