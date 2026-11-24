import Foundation
import XCTest
@testable import PacerCore
@testable import PacerIsland

/// Help → Collaboration's diagram, in both languages and both views: every
/// label on the grid and clear of the others, and Pacer's lane only in
/// Pacer's view. Checks the same layout as the Windows presentation tests.
final class CollaborationDiagramTests: XCTestCase {
    private func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.sharedResourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                                                              localization: language))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testLabelsStayOnTheGridAndApart() throws {
        let grid = CGRect(origin: .zero, size: CollaborationDiagram.size).insetBy(dx: -0.5, dy: -0.5)
        for language in ["en", "zh-Hans"] {
            let table = try strings(language)
            for throughPacer in [true, false] {
                let items = CollaborationDiagram.elements(throughPacer: throughPacer) { key in
                    table["help.collaboration." + key] ?? "missing " + key
                }
                let labels = items.compactMap { item -> CollaborationDiagram.Label? in if case .label(let label) = item { label } else { nil } }
                XCTAssertFalse(labels.contains { $0.text.hasPrefix("missing ") }, "\(language): every string exists")
                let boxes = labels.map { ($0.text, CollaborationDiagram.bounds($0)) }
                for (text, box) in boxes {
                    XCTAssertTrue(grid.contains(box), "\(language) \(throughPacer ? "Pacer" : "typical"): \(text) at \(box) leaves the grid")
                }
                for first in boxes.indices {
                    for second in boxes.indices where second > first {
                        // A mark's number sits on its dot, beside its words; anything else keeps clear.
                        let overlap = boxes[first].1.intersection(boxes[second].1)
                        XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 1,
                                      "\(language): \(boxes[first].0) and \(boxes[second].0) overlap")
                    }
                }
            }
        }
    }

    @MainActor
    func testNotesReadOnTheirTintInLightAndDark() {
        for light in [true, false] {
            for tone in [CollaborationDiagram.Tone.good, .bad] {
                let figure = CollaborationDiagram.figure(tone, light: light), note = CollaborationDiagram.note(tone, light: light)
                let name = "\(tone) \(light ? "light" : "dark")"
                XCTAssertGreaterThanOrEqual(CollaborationDiagram.contrast(note, figure), 4.5, name + ": the notes on the figure")
                XCTAssertGreaterThanOrEqual(CollaborationDiagram.contrast(CollaborationDiagram.card(light: light), note), 4.5,
                                            name + ": a mark's number on its dot")
            }
        }
        // The Codex work bar keeps Codex's own color; only the notes change.
        let pacer = CollaborationDiagram.elements(throughPacer: true) { $0 }
        XCTAssertTrue(pacer.contains(.bar(x: CollaborationDiagram.codex, y: 148, height: 128, ink: .good)))
        XCTAssertTrue(pacer.contains(.dot(center: CGPoint(x: 256, y: 172), ink: .goodNote)))
    }

    func testOnlyPacersViewHasItsLane() {
        let pacer = CollaborationDiagram.elements(throughPacer: true) { $0 }
        let typical = CollaborationDiagram.elements(throughPacer: false) { $0 }
        XCTAssertTrue(pacer.contains(.icon(.pacer, x: CollaborationDiagram.pacer)))
        XCTAssertTrue(pacer.contains(.lifeline(x: CollaborationDiagram.pacer, end: 388)))
        XCTAssertFalse(typical.contains { if case .icon(.pacer, _) = $0 { true } else { false } })
        XCTAssertFalse(typical.contains { if case .lifeline(let x, _) = $0 { x == CollaborationDiagram.pacer } else { false } })
        // You, Claude and Codex stay put between the two.
        for x in [CollaborationDiagram.claude, CollaborationDiagram.codex] {
            XCTAssertTrue(typical.contains { if case .icon(_, let at) = $0 { at == x } else { false } })
            XCTAssertTrue(pacer.contains { if case .icon(_, let at) = $0 { at == x } else { false } })
        }
        XCTAssertEqual(pacer.filter { if case .dot = $0 { true } else { false } }.count, 3, "Three differences")
        XCTAssertEqual(typical.filter { if case .dot = $0 { true } else { false } }.count, 3)
        XCTAssertNotEqual(CollaborationDiagram.summary(throughPacer: true), CollaborationDiagram.summary(throughPacer: false))
    }
}
