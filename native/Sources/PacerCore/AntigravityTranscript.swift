import Foundation

/// A replaced, truncated or partly-written transcript is common. Keep only projected
/// complete records from the current tail, never a buffer of unfinished private text.
struct AntigravityTranscript {
    struct Record: Equatable {
        let index: Int
        let type: String
        let created: Date
        let model: String?
    }

    private(set) var records: [Int: Record] = [:]
    private var stamp: PlatformFileMetadata?
    static let maximumBytes = 512 * 1024

    mutating func read(_ url: URL, files: any PlatformFileSystem) {
        guard let metadata = files.metadata(url), metadata.isRegularFile else { self = Self(); return }
        guard stamp != metadata else { return }
        self = Self()
        let length = Int(min(UInt64(Self.maximumBytes), metadata.size))
        let offset = metadata.size - UInt64(length)
        guard let data = try? files.read(url, offset: offset, maximumBytes: length), data.count == length,
              files.metadata(url) == metadata else { return }
        stamp = metadata
        var start = data.startIndex
        if offset > 0 {
            guard let newline = data.firstIndex(of: 10) else { return }
            start = newline + 1
        }
        var latestInput: Record?
        while start < data.endIndex, let end = data[start...].firstIndex(of: 10) {
            defer { start = end + 1 }
            guard end > start, let fields = try? JSONFieldView.document(data.subdata(in: start..<end))
                .fields(["step_index", "type", "status", "created_at", "model"]),
                  fields["status"]?.matchesStringLiteral("DONE") == true,
                  let index = fields["step_index"]?.integer(), index >= 0,
                  let type = fields["type"]?.string(limit: 64),
                  let created = AntigravityStore.date(fields["created_at"]?.string(limit: 48)) else { continue }
            let record = Record(index: index, type: type, created: created,
                                model: type == "PLANNER_RESPONSE" ? fields["model"]?.string(limit: 128) : nil)
            records[index] = record
            if type == "USER_INPUT" || index == 0 && type == "SYSTEM_MESSAGE" { latestInput = record }
            if records.count > 256 {
                for old in records.keys.sorted().prefix(128) { records.removeValue(forKey: old) }
            }
        }
        if let latestInput { records[latestInput.index] = latestInput }
    }
}

struct AntigravityModel: Equatable {
    let name: String
    let effort: String?

    init(name: String, effort: String?) { self.name = name; self.effort = effort }

    init?(id: String?, displayName: String? = nil) {
        guard let id, !id.isEmpty, id.count <= 128, !id.hasPrefix("MODEL_PLACEHOLDER_") else {
            guard let displayName, !displayName.isEmpty else { return nil }
            name = String(displayName.prefix(120)); effort = nil; return
        }
        var parts = id.split(separator: "-").map(String.init)
        guard let family = parts.first, ["gemini", "claude", "gpt"].contains(family) else {
            name = displayName ?? id; effort = nil; return
        }
        if let last = parts.last, ["low", "medium", "high", "xhigh"].contains(last) {
            effort = parts.removeLast()
            if parts.last == "tiered" { parts.removeLast() }
        } else { effort = nil }
        let base = parts.joined(separator: "-")
        let shortened = ModelDisplay.name(base, provider: .antigravity)
        if shortened != base { name = shortened; return }
        name = parts.map { $0 == "gpt" ? "GPT" : $0.capitalized }.joined(separator: " ")
    }
}
