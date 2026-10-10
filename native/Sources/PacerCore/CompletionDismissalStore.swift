import Foundation
import CryptoKit
import Darwin

/// Persists acknowledged endings without retaining session, account or path text.
public struct CompletionDismissalStore: Sendable {
    private struct Envelope: Codable {
        let version: Int
        let digests: [String]
    }
    private static let maximumEntries = 512
    private static let maximumBytes = 64 * 1024
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var applicationDefault: CompletionDismissalStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland", isDirectory: true)
        return CompletionDismissalStore(fileURL: directory.appendingPathComponent("completion-dismissals-v1.json"))
    }

    static func digest(_ fields: [String]) -> String {
        // Length prefixes make opaque identifiers unambiguous without storing them.
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            data.append(Data("\(bytes.count):".utf8)); data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func loadDigests() -> [String] {
        guard let attributes = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, let size = attributes.fileSize, size <= Self.maximumBytes,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumBytes + 1), data.count <= Self.maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.digests.count <= Self.maximumEntries,
              Set(envelope.digests).count == envelope.digests.count,
              envelope.digests.allSatisfy(Self.validDigest) else { return [] }
        return envelope.digests
    }

    @discardableResult
    func saveDigests(_ digests: [String]) -> Bool {
        guard digests.count <= Self.maximumEntries, Set(digests).count == digests.count,
              digests.allSatisfy(Self.validDigest),
              let data = try? JSONEncoder().encode(Envelope(version: 1, digests: digests)),
              data.count <= Self.maximumBytes else { return false }
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".completion-dismissals-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return false }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.write(contentsOf: data); try handle.close() }
            catch { try? handle.close(); return false }
            return temporary.path.withCString { source in
                fileURL.path.withCString { destination in rename(source, destination) == 0 }
            }
        } catch { return false }
    }

    static func bounded(_ digests: [String]) -> [String] { Array(digests.suffix(maximumEntries)) }
    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
