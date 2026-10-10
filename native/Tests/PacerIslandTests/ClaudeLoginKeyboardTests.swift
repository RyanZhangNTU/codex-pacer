import AppKit
import XCTest
@testable import PacerIsland

@MainActor
final class ClaudeLoginKeyboardTests: XCTestCase {
    private final class ConsumingContentView: NSView {
        var received: [NSEvent] = []
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            received.append(event)
            return true
        }
    }

    func testLoginWindowRunsContinueBeforeConsumingContentAndLeavesOtherChordsInResponderChain() throws {
        _ = NSApplication.shared
        let window = ClaudeLoginWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = ConsumingContentView()
        window.contentView = content
        var continues = 0
        window.onContinue = { continues += 1 }

        func key(_ flags: NSEvent.ModifierFlags, characters: String = "\r", code: UInt16 = 36) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        XCTAssertTrue(window.performKeyEquivalent(with: try key(.command)))
        XCTAssertEqual(continues, 1)
        XCTAssertTrue(content.received.isEmpty, "Continue must run before focused content can consume the shortcut")
        XCTAssertTrue(window.performKeyEquivalent(with: try key([.command, .capsLock])))
        XCTAssertEqual(continues, 2)
        XCTAssertTrue(content.received.isEmpty)

        let otherModifiers: [NSEvent.ModifierFlags] = [[], [.command, .shift], [.command, .option], [.command, .control], [.command, .function]]
        for flags in otherModifiers {
            XCTAssertTrue(window.performKeyEquivalent(with: try key(flags)))
        }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(.command, characters: "w", code: 13)))
        XCTAssertEqual(continues, 2, "Plain Return, other modifiers and Command-W must retain their native meaning")
        XCTAssertEqual(content.received.count, 6)

        window.onContinue = nil
        XCTAssertTrue(window.performKeyEquivalent(with: try key(.command)))
        XCTAssertEqual(continues, 2)
        XCTAssertEqual(content.received.count, 7, "A released login action must no longer intercept content")
    }
}
