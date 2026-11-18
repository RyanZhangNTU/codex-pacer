import Foundation

/// Pacer's local arrangement of sidebar pins. IDs are canonical, host-qualified activity IDs.
public struct PinnedConversationGroups: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public var name: String
        public var members: [String]
        public var collapsed: Bool
        public init(id: String, name: String, members: [String], collapsed: Bool = false) {
            self.id = id; self.name = name; self.members = members; self.collapsed = collapsed
        }
        enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", members = "Members", collapsed = "Collapsed" }
    }

    public struct Section: Equatable, Sendable {
        public let group: Group?
        public let members: [String]
    }

    // Match the existing Windows preferences format.
    public private(set) var profiles: [String: [Group]] = [:]
    enum CodingKeys: String, CodingKey { case profiles = "Profiles" }
    public init() {}
    public static func read(_ data: Data?) -> Self {
        guard let data, data.count <= 60 * 1024, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.profiles.count <= 32, value.profiles.values.allSatisfy(valid) else { return Self() }
        return value
    }
    private static func valid(_ groups: [Group]) -> Bool {
        var ids = Set<String>(), members = Set<String>()
        return groups.count <= 256 && groups.allSatisfy { group in
            !group.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ids.insert(group.id).inserted &&
            group.name.utf16.count <= 64 && group.members.count <= 256 && group.members.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && members.insert($0).inserted
            }
        }
    }
    /// Validates before replacing the current value, so an edit at a limit preserves every profile.
    public mutating func save(_ groups: [Group], profile: String) -> Data? {
        guard Self.valid(groups) else { return nil }
        var next = self
        next.profiles[profile] = groups.isEmpty ? nil : groups
        guard next.profiles.count <= 32, let data = try? JSONEncoder().encode(next), data.count <= 60 * 1024 else { return nil }
        self = next
        return data
    }

    public static func sections(_ groups: [Group], ids: [String], running: Set<String>) -> [Section] {
        var remaining = Set(ids), sections: [Section] = []
        func ranked(_ values: [String]) -> [String] {
            values.filter(running.contains) + values.filter { !running.contains($0) }
        }
        for group in groups {
            let visible = group.members.filter { remaining.remove($0) != nil }
            if !visible.isEmpty { sections.append(Section(group: group, members: ranked(visible))) }
        }
        sections.append(Section(group: nil, members: ranked(remaining.sorted())))
        func active(_ section: Section) -> Bool { section.members.first.map(running.contains) ?? false }
        return sections.filter(active) + sections.filter { !active($0) }
    }

    public static func move(_ members: [String], in groups: [Group], to destination: String?, name: String = "") -> [Group] {
        var moved: Set<String> = []
        let unique = members.filter { moved.insert($0).inserted }
        var result = groups.map { group in
            var value = group
            value.members.removeAll(where: moved.contains)
            return value
        }
        if let destination {
            if let index = result.firstIndex(where: { $0.id == destination }) { result[index].members += unique }
            else { result.append(Group(id: destination, name: name, members: unique)) }
        }
        return result.filter { !$0.members.isEmpty }
    }
    public static func dropGroup(_ source: String, in groups: [Group], at destination: String?, after: Bool, merge: Bool) -> [Group] {
        guard source != destination, let group = groups.first(where: { $0.id == source }),
              destination == nil || groups.contains(where: { $0.id == destination }) else { return groups }
        if merge { return destination == nil ? groups : move(group.members, in: groups, to: destination) }
        var result = groups.filter { $0.id != source }
        let index = result.firstIndex { $0.id == destination }.map { $0 + (after ? 1 : 0) } ?? result.endIndex
        result.insert(group, at: index)
        return result
    }
}
