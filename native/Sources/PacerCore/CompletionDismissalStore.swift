import Foundation
import CryptoKit
import Darwin

/// Persists acknowledged endings without retaining session, account or path text.
public struct CompletionDismissalStore: Sendable {
    /// Only a hashed source identity and a server timestamp survive. This
    /// bridges the same bounded idle-to-resolved transition across a relaunch.
    struct CloudEnding: Codable, Equatable, Sendable {
        let source: String
        let mark: Date
    }
    private struct Envelope: Codable {
        let version: Int
        let digests: [String]
        let cloudEndings: [CloudEnding]?
    }
    private static let maximumEntries = 512
    private static let maximumBytes = 64 * 1024
    private static let maximumCloudEndings = 128
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

    func loadDigests() -> [String] { load().digests }

    func load() -> (digests: [String], cloudEndings: [CloudEnding]) {
        guard let attributes = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, let size = attributes.fileSize, size <= Self.maximumBytes,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return ([], []) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumBytes + 1), data.count <= Self.maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.digests.count <= Self.maximumEntries,
              Set(envelope.digests).count == envelope.digests.count,
              envelope.digests.allSatisfy(Self.validDigest),
              Self.validCloudEndings(envelope.cloudEndings ?? []) else { return ([], []) }
        return (envelope.digests, envelope.cloudEndings ?? [])
    }

    @discardableResult
    func saveDigests(_ digests: [String], cloudEndings: [CloudEnding] = []) -> Bool {
        guard digests.count <= Self.maximumEntries, Set(digests).count == digests.count,
              digests.allSatisfy(Self.validDigest), Self.validCloudEndings(cloudEndings),
              let data = try? JSONEncoder().encode(Envelope(version: 1, digests: digests,
                  cloudEndings: cloudEndings.isEmpty ? nil : cloudEndings)),
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
    static func boundedCloudEndings(_ endings: [CloudEnding]) -> [CloudEnding] { Array(endings.suffix(maximumCloudEndings)) }
    private static func validCloudEndings(_ endings: [CloudEnding]) -> Bool {
        endings.count <= maximumCloudEndings && Set(endings.map(\.source)).count == endings.count && endings.allSatisfy {
            validDigest($0.source) && $0.mark.timeIntervalSince1970.isFinite
        }
    }
    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
