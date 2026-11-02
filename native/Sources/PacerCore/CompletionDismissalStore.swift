import Foundation
import CryptoKit

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

    private let files: any PlatformFileSystem
    public init(fileURL: URL, files: any PlatformFileSystem) { self.fileURL = fileURL; self.files = files }

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
        guard let metadata = files.metadata(fileURL), metadata.isRegularFile, metadata.size <= Self.maximumBytes,
              let data = try? files.read(fileURL, offset: 0, maximumBytes: Self.maximumBytes + 1), data.count <= Self.maximumBytes,
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
        return files.replace(fileURL, with: data)
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
