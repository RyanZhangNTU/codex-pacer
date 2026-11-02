import Foundation

struct RemoteControlCatalogAuthorization: Sendable {
    let token: String
    let accountID: String
    let accountUserIDs: [String]
    let backendOrigin: URL

    init(account: Data, auth: Data) throws {
        let accountFields = try JSONFieldView.document(account).fields(["account", "workspaceRouting"])
        guard let identity = accountFields["account"], identity.isObject,
              try identity.fields(["type"])["type"]?.string()?.lowercased() == "chatgpt" else { throw CodexClientError.notLoggedIn }
        let authFields = try JSONFieldView.document(auth).fields(["authMethod", "authToken"])
        guard authFields["authMethod"]?.string()?.lowercased() == "chatgpt",
              let token = authFields["authToken"]?.string(limit: 32_768) else { throw CodexClientError.notLoggedIn }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw CodexClientError.invalidResponse }
        let encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let payload = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)),
              let claims = try JSONFieldView.document(payload).fields(["https://api.openai.com/auth"])["https://api.openai.com/auth"] else { throw CodexClientError.invalidResponse }
        let fields = try claims.fields(["chatgpt_account_id", "account_id", "chatgpt_account_user_id", "account_user_id", "user_id"])
        guard let accountID = fields["chatgpt_account_id"]?.string() ?? fields["account_id"]?.string(),
              let user = fields["chatgpt_account_user_id"]?.string() ?? fields["account_user_id"]?.string(),
              !accountID.isEmpty, !user.isEmpty else { throw CodexClientError.invalidResponse }
        let routing = try accountFields["workspaceRouting"]?.fields(["chatgptAccountId", "backendOrigin"])
        if let routedID = routing?["chatgptAccountId"]?.string(), routedID != accountID { throw CodexClientError.accountMismatch }
        let origin = routing?["backendOrigin"]?.string(limit: 2048) ?? "https://chatgpt.com"
        guard let url = URL(string: origin), url.scheme == "https", let host = url.host,
              host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw CodexClientError.invalidResponse }
        self.token = token; self.accountID = accountID; backendOrigin = url
        accountUserIDs = [user] + (fields["user_id"]?.string().flatMap { $0 != user ? [$0] : nil } ?? [])
    }
}
