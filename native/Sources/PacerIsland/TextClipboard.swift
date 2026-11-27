import AppKit

/// Tests can redirect Copy actions without changing the user's clipboard.
@MainActor enum TextClipboard {
    static var write: (String) -> Bool = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
