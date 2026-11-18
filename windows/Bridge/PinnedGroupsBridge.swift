import Foundation
import PacerCore

// WPF supplies host-local preference values and row IDs. The same policy drives the Mac outline.
private struct PinnedGroupRequest: Decodable {
    let groups: [PinnedConversationGroups.Group]
    var ids: [String]?, running: Set<String>?, members: [String]?
    var source: String?, destination: String?, name: String?
    var after: Bool?, merge: Bool?
}
private struct GroupSection: Encodable { let group: String?; let members: [String] }

@_cdecl("pacer_pinned_groups_project")
public func pacerPinnedGroupsProject(_ action: Int32, _ input: UnsafePointer<UInt8>?, _ count: Int32,
                                     _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32) -> Int32 {
    guard let input, count > 0, count <= 1024 * 1024, let output, capacity > 0,
          let request = try? JSONDecoder().decode(PinnedGroupRequest.self, from: Data(bytes: input, count: Int(count))) else { return 0 }
    let encoder = JSONEncoder()
    let result: Data?
    switch action {
    case 0:
        guard let ids = request.ids, let running = request.running else { return 0 }
        result = try? encoder.encode(PinnedConversationGroups.sections(request.groups, ids: ids, running: running)
            .map { GroupSection(group: $0.group?.id, members: $0.members) })
    case 1:
        guard let members = request.members else { return 0 }
        result = try? encoder.encode(PinnedConversationGroups.move(members, in: request.groups, to: request.destination, name: request.name))
    case 2:
        guard let source = request.source, let after = request.after, let merge = request.merge else { return 0 }
        result = try? encoder.encode(PinnedConversationGroups.dropGroup(source, in: request.groups, at: request.destination, after: after, merge: merge))
    default: return 0
    }
    guard let result, result.count <= 1024 * 1024 else { return 0 }
    if result.count > Int(capacity) { return -Int32(result.count) }
    result.copyBytes(to: output, count: result.count)
    return Int32(result.count)
}
