import Foundation

/// Invoked only by a conversation-opening action. The remote resolver does not
/// provision software, change settings, authenticate, or send a prompt.
public enum ClaudeRemoteResume {
    public static func command(sessionID: String) -> String? {
        guard sessionID.count == 36, let session = UUID(uuidString: sessionID),
              let script = resourceData() else { return nil }
        return "python3 -u -c 'import base64;exec(base64.b64decode(\"\(script.base64EncodedString())\").decode(\"utf-8\"))' " +
            session.uuidString.lowercased()
    }

    static func resourceData() -> Data? {
        guard let url = Bundle.module.url(forResource: "claude_remote_resume", withExtension: "py"),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }
}
