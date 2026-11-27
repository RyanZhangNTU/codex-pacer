import Foundation

struct AntigravityModelCatalog {
    private struct Entry {
        let name: String
        let efforts: Set<String>
    }
    static let efforts: Set<String> = ["low", "medium", "high", "xhigh"]
    private var entries: [String: Entry] = [:]

    init() {}

    init(_ data: Data) throws {
        guard let models = try JSONFieldView.document(data).fields(["userStatus"])["userStatus"]?
            .fields(["cascadeModelConfigData"])["cascadeModelConfigData"]?
            .fields(["groupedModels"])["groupedModels"] else { return }
        try models.forEachField(maximumCount: 256) { id, value in
            guard !id.isEmpty, id.utf8.count <= 128, value.isObject else { return }
            let fields = try value.fields(["displayName", "supportedThinkingLevels"])
            guard let name = fields["displayName"]?.string(limit: 121), !name.isEmpty, name.utf8.count <= 120 else { return }
            let levels = try fields["supportedThinkingLevels"]?.elements(maximumCount: 16).compactMap {
                try $0.fields(["thinkingSuffix"])["thinkingSuffix"]?.string(limit: 16)
            } ?? []
            entries[id] = Entry(name: name, efforts: Self.efforts.intersection(levels))
        }
    }

    func resolve(_ id: String) -> AntigravityModel? {
        func model(_ base: String, effort: String?) -> AntigravityModel? {
            guard let entry = entries[base], effort.map(entry.efforts.contains) ?? true else { return nil }
            let shortened = ModelDisplay.name(base, provider: .antigravity)
            return AntigravityModel(name: shortened != base && (base.hasPrefix("claude-") || base.hasPrefix("gpt-"))
                ? shortened : entry.name, effort: effort)
        }
        if let exact = model(id, effort: nil) { return exact }
        guard let dash = id.lastIndex(of: "-") else { return nil }
        let effort = String(id[id.index(after: dash)...]), base = String(id[..<dash])
        if let exact = model(base, effort: effort) { return exact }
        return base.hasSuffix("-tiered") ? model(String(base.dropLast(7)), effort: effort) : nil
    }
}
