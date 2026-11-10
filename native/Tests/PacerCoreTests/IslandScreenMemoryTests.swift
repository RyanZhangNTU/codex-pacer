import Foundation
import XCTest
@testable import PacerCore
import PacerTestSupport

/// Each display keeps its own place: Notch or Free Move with its spot.
final class IslandScreenMemoryTests: XCTestCase {
    private typealias Memory = IslandScreenMemory
    private typealias Place = IslandScreenMemory.Place
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = testDefaultsName("IslandScreenMemoryTests")
        defer { removeTestDefaults(name) }
        try body(XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testDisplaysKeepTheirOwnPlaceAndFirstVisitsMoveNothing() throws {
        try withDefaults { defaults in
            XCTAssertTrue(Memory.isEnabled(in: defaults), "On unless turned off")
            let left = IslandPlacement(edge: .left, x: 0, y: 0.4)
            Place(mode: .floating, position: .bottomLeft, placement: left).apply(to: defaults)

            // Launch, or the option just turned on: the display starts from the current place.
            XCTAssertFalse(Memory.arrive(at: "dell", name: "DELL", hasNotch: false, switched: false, defaults: defaults, now: start))
            XCTAssertEqual(Memory.load(from: defaults).place(for: "dell"), Place(mode: .floating, position: .bottomLeft, placement: left))

            // A notched display reached for the first time takes the notch and keeps the spot for Free Move.
            XCTAssertTrue(Memory.arrive(at: "builtin", name: "Built-in", hasNotch: true, switched: true, defaults: defaults, now: start + 1))
            XCTAssertEqual(Place.current(in: defaults), Place(mode: .notch, position: .bottomLeft, placement: left))

            // Free Move on the built-in display stays there.
            let top = IslandPlacement(edge: .top, x: 0.3, y: 0)
            Place(mode: .floating, position: .bottomLeft, placement: top).apply(to: defaults)
            Memory.rememberCurrent(for: "builtin", name: "Built-in", defaults: defaults, now: start + 2)

            // Back on the DELL: its own place returns, and back again.
            XCTAssertTrue(Memory.arrive(at: "dell", name: "DELL", hasNotch: false, switched: true, defaults: defaults, now: start + 3))
            XCTAssertEqual(IslandPlacement.load(from: defaults), left)
            XCTAssertTrue(Memory.arrive(at: "builtin", name: "Built-in", hasNotch: true, switched: true, defaults: defaults, now: start + 4))
            XCTAssertEqual(Place.current(in: defaults), Place(mode: .floating, position: .bottomLeft, placement: top))

            // A display without a notch reached for the first time keeps the place in use.
            XCTAssertFalse(Memory.arrive(at: "portrait", name: "DELL P", hasNotch: false, switched: true, defaults: defaults, now: start + 5))
            XCTAssertEqual(Memory.load(from: defaults).place(for: "portrait"), Place(mode: .floating, position: .bottomLeft, placement: top))

            // Return to Top Center clears the spot and the corner on that display only.
            Place(mode: .floating, position: nil, placement: nil).apply(to: defaults)
            XCTAssertNil(IslandPlacement.load(from: defaults)); XCTAssertNil(IslandPosition.saved(in: defaults))
            Memory.rememberCurrent(for: "portrait", name: "DELL P", defaults: defaults, now: start + 6)
            XCTAssertEqual(Memory.load(from: defaults).place(for: "builtin")?.placement, top)
        }
    }

    func testMemoryKeepsTheRecentDisplaysAndSkipsDamagedEntries() throws {
        try withDefaults { defaults in
            var memory = Memory()
            for index in 0..<(Memory.limit + 2) {
                memory.remember(Place(mode: .notch), for: "display-\(index)", name: "Display \(index)", at: start + Double(index))
            }
            XCTAssertEqual(memory.entries.count, Memory.limit)
            XCTAssertNil(memory.place(for: "display-0")); XCTAssertNil(memory.place(for: "display-1"))
            memory.save(to: defaults)
            XCTAssertEqual(Memory.load(from: defaults), memory, "A saved memory reads back the same")

            let json = #"{"version":1,"displays":{"good":{"mode":"floating","edge":"right","x":1,"y":0.5,"name":"A","used":5},"#
                + #""unknown":{"mode":"sideways"},"outside":{"mode":"floating","edge":"left","x":2,"y":0.5},"":{"mode":"notch"}}}"#
            defaults.set(Data(json.utf8), forKey: Memory.defaultsKey)
            let loaded = Memory.load(from: defaults)
            XCTAssertEqual(Set(loaded.entries.keys), ["good", "outside"], "An unreadable mode drops only its display")
            XCTAssertEqual(loaded.place(for: "good")?.placement, IslandPlacement(edge: .right, x: 1, y: 0.5))
            XCTAssertNil(loaded.place(for: "outside")?.placement, "A spot off the screen is forgotten, not the display")
            defaults.set(Data(repeating: 32, count: Memory.byteLimit + 1), forKey: Memory.defaultsKey)
            XCTAssertTrue(Memory.load(from: defaults).entries.isEmpty)
            defaults.set(false, forKey: Memory.enabledKey)
            XCTAssertFalse(Memory.isEnabled(in: defaults))
        }
    }
}
