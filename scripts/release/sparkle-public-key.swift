// Prints the public key of the Sparkle EdDSA private key on standard input, in the
// form `generate_keys -x` exports it: the base64 of a 32-byte seed, or of a legacy
// 64-byte expanded private key followed by its 32-byte public key.
// With `--verify PUBLIC SIGNATURE FILE` it instead checks a signature of FILE, so
// the caller can prove a legacy key's stored public half belongs to its private key.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count == 5, arguments[1] == "--verify" {
    guard let raw = Data(base64Encoded: arguments[2]), let signature = Data(base64Encoded: arguments[3]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[4])) else { fail("Cannot read the signature check inputs.") }
    guard key.isValidSignature(signature, for: data) else { fail("The Sparkle private key does not match its public key.") }
    exit(0)
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
