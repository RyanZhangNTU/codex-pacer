import Foundation
import XCTest
@testable import PacerCore

final class VisibilityAndInteractionScenarioTableTests: XCTestCase {
    private typealias F = PresentationScenarioFixtures
    private struct Visibility: Decodable { let provider: AgentProvider, host: String?, embedded: Bool, order: [String], hidden: [String] }
    func testEveryOriginalProviderHostEmbeddingAndOrderPermutation() throws {
        let rows = try F.table("visibility", as: [Visibility].self)
        XCTAssertEqual(rows.count, 16)
        let parent = "019a0000-0000-7000-8000-000000000001", child = "019a0000-0000-7000-8000-000000000002"
        for row in rows {
            var root = SessionActivity(id: row.provider.activityID(sessionID: parent, sourceHostID: row.host), sourceHostID: row.host,
                provider: row.provider, sessionID: parent)
            if row.provider == .codex { root.setCodexOrigin(.init(embedded: row.embedded, ignored: false)) }
            else { root.setClaudeLaunch(embedded: row.embedded) }
            var descendant = SessionActivity(id: row.provider.activityID(sessionID: child, sourceHostID: row.host), sourceHostID: row.host,
                provider: row.provider, sessionID: child)
            descendant.updateParent(parent)
            let other = SessionActivity(id: AgentProvider.deepseek.activityID(sessionID: child, sourceHostID: row.host), sourceHostID: row.host,
                provider: .deepseek, sessionID: child)
            let roles = ["root": root, "child": descendant, "other": other]
            let values = try row.order.map { try XCTUnwrap(roles[$0]) }
            let expected = try Set(row.hidden.map { try XCTUnwrap(roles[$0]).id })
            XCTAssertEqual(EmbeddedSessionVisibility.embeddedActivityIDs(values), expected, "\(row.provider)/\(row.host ?? "local")/\(row.embedded)/\(row.order)")
            XCTAssertFalse(descendant.launchedByEmbeddingApp)
        }
    }
    private struct Point: Decodable { let step: Int, value: Double }
    private struct Interaction: Decodable { let hoverDuration: Double, navigationErrorDuration: Double, points: [Point] }
    func testEveryOriginalEaseOutSampleUsesTheFixedNumericTable() throws {
        let table = try F.table("task-row", as: Interaction.self)
        XCTAssertEqual(TaskRowInteraction.hoverDuration, table.hoverDuration)
        XCTAssertEqual(TaskRowInteraction.navigationErrorDuration, table.navigationErrorDuration)
        XCTAssertEqual(table.points.map(\.step), Array(0...120))
        for row in table.points {
            XCTAssertEqual(TaskRowInteraction.hoverProgress(Double(row.step) / 120), row.value, accuracy: 0.00001, "step \(row.step)")
        }
        XCTAssertEqual(TaskRowInteraction.hoverProgress(-1), 0)
        XCTAssertEqual(TaskRowInteraction.hoverProgress(2), 1)
        XCTAssertEqual(TaskRowInteraction.hoverProgress(.nan), 0)
        XCTAssertEqual(TaskRowInteraction.hoverProgress(.infinity), 0)
    }
}
