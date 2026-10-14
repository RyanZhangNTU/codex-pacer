import Foundation
import CryptoKit

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

/// Only public client identifiers are read from the enrollment index. Key IDs,
/// public keys and signing credentials are neither decoded nor requested.
struct RemoteControlCatalogIdentity: Sendable {
    struct Client: Sendable { let accountUserID: String; let id: String }
    let clients: [Client]
    let localEnvironmentID: String?
    let selectedHost: String?
    var fingerprint: String {
        let value = clients.map { $0.accountUserID + ":" + $0.id }.sorted().joined(separator: "|") + "|" + (localEnvironmentID ?? "")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(home: URL) -> Self? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")), data.count <= 8 * 1024 * 1024,
              let fields = try? JSONFieldView.document(data).fields(["electron-remote-control-client-enrollments",
                  "electron-local-remote-control-environment-id", "selected-remote-host-id"]),
              let records = fields["electron-remote-control-client-enrollments"], records.isObject else { return nil }
        var clients: [Client] = []
        do {
            try records.forEachField(maximumCount: 64) { _, record in
                guard record.isObject else { return }
                let fields = try record.fields(["accountUserId", "clientId"])
                guard let user = fields["accountUserId"]?.string(), !user.isEmpty,
                      let id = fields["clientId"]?.string(), validIdentifier(id) else { return }
                clients.append(.init(accountUserID: user, id: id))
            }
        } catch { return nil }
        guard !clients.isEmpty else { return nil }
        return .init(clients: clients, localEnvironmentID: fields["electron-local-remote-control-environment-id"]?.string(),
                     selectedHost: fields["selected-remote-host-id"]?.string())
    }
    func clientID(for authorization: RemoteControlCatalogAuthorization) -> String? {
        // Prefer the current account-user identity, matching Desktop's routing.
        for user in authorization.accountUserIDs {
            let ids = Set(clients.filter { $0.accountUserID == user }.map(\.id))
            if ids.count == 1 { return ids.first }
            if ids.count > 1 { return nil }
        }
        return nil
    }
    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

actor RemoteControlCatalog {
    private enum CatalogError: Error { case status(Int) }
    private struct Refresh { let targets: [RemoteControlActivityTarget]?; let preserveCache: Bool }
    private struct Cache { let key: String; let targets: [RemoteControlActivityTarget]?; let expires: Date }
    private var cache: Cache?
    private var pending: (id: UUID, key: String, client: CodexClient, task: Task<Refresh, Never>)?
    private var desiredKey: String?
    private let fetch: @Sendable (URLRequest) async throws -> Data
    private let makeClient: @Sendable (URL) -> CodexClient?
    init(fetch: @escaping @Sendable (URLRequest) async throws -> Data = { try await RemoteControlCatalog.fetch($0) },
         makeClient: @escaping @Sendable (URL) -> CodexClient? = { home in
             guard let executable = CodexClient.findExecutable(customPath: UserDefaults.standard.string(forKey: "codexExecutable") ?? "") else { return nil }
             return CodexClient(executable: executable, home: home, timeout: 8)
         }) { self.fetch = fetch; self.makeClient = makeClient }

    private static func bindingKey(home: URL, identity: RemoteControlCatalogIdentity) -> String {
        home.path + "|" + identity.fingerprint + "|" + (CodexClient.authenticationFingerprint(home: home) ?? "missing")
    }
    private static func currentIdentity(home: URL, matching key: String) -> RemoteControlCatalogIdentity? {
        guard let identity = RemoteControlCatalogIdentity.read(home: home), bindingKey(home: home, identity: identity) == key else { return nil }
        return identity
    }
    private static func selected(_ targets: [RemoteControlActivityTarget]?, identity: RemoteControlCatalogIdentity) -> [RemoteControlActivityTarget]? {
        targets.map { values in
            values.sorted {
                if ($0.id == identity.selectedHost) != ($1.id == identity.selectedHost) { return $0.id == identity.selectedHost }
                if ($0.online == true) != ($1.online == true) { return $0.online == true }
                return $0.id < $1.id
            }.prefix(8).map { $0 }
        }
    }
    /// Fast, account-bound metadata for transport startup; it never does RPC
    /// or HTTP work. The full bounded directory stays cached before selection.
    func cachedTargets(home: URL) -> [RemoteControlActivityTarget]? {
        guard let identity = RemoteControlCatalogIdentity.read(home: home), let cache,
              cache.key == Self.bindingKey(home: home, identity: identity) else { return nil }
        return Self.selected(cache.targets, identity: identity)
    }

    func targets(home: URL, now: Date = Date()) async -> [RemoteControlActivityTarget]? {
        guard let identity = RemoteControlCatalogIdentity.read(home: home) else { await shutdown(); return nil }
        let key = Self.bindingKey(home: home, identity: identity)
        if desiredKey != key {
            desiredKey = key
            let previous = pending; pending = nil
            if let previous { previous.task.cancel(); await previous.client.shutdown() }
            guard desiredKey == key else { return nil }
        }
        if let cache, cache.key == key, now < cache.expires { return Self.selected(cache.targets, identity: identity) }
        if let pending, pending.key == key {
            let result = await pending.task.value
            guard desiredKey == key, let current = Self.currentIdentity(home: home, matching: key) else { return nil }
            return Self.selected(result.targets ?? (result.preserveCache && cache?.key == key ? cache?.targets : nil), identity: current)
        }
        guard let client = makeClient(home) else {
            return Self.selected(cache?.key == key ? cache?.targets : nil, identity: identity)
        }
        let id = UUID(), fetch = fetch
        let task = Task<Refresh, Never> {
            let result: Refresh
            do {
                let auth = try await client.remoteControlCatalogAuthorization()
                guard let clientID = identity.clientID(for: auth) else { throw CodexClientError.invalidResponse }
                guard Self.currentIdentity(home: home, matching: key) != nil else { throw CodexClientError.accountMismatch }
                result = .init(targets: try await Self.readTargets(authorization: auth, clientID: clientID, identity: identity, fetch: fetch), preserveCache: false)
            } catch CodexClientError.notLoggedIn { result = .init(targets: nil, preserveCache: false) }
            catch CodexClientError.accountMismatch { result = .init(targets: nil, preserveCache: false) }
            catch CatalogError.status(let status) where [401, 403, 404].contains(status) { result = .init(targets: nil, preserveCache: false) }
            catch { result = .init(targets: nil, preserveCache: true) }
            await client.shutdown()
            return Task.isCancelled ? .init(targets: nil, preserveCache: false) : result
        }
        pending = (id, key, client, task)
        let result = await task.value
        guard pending?.id == id else { return nil }
        pending = nil
        guard let current = Self.currentIdentity(home: home, matching: key) else {
            if cache?.key == key { cache = nil }
            return nil
        }
        let targets = result.targets ?? (result.preserveCache && cache?.key == key ? cache?.targets : nil)
        cache = .init(key: key, targets: targets, expires: now.addingTimeInterval(result.targets == nil ? 30 : 300))
        return Self.selected(targets, identity: current)
    }
    func invalidate() {
        if let cache { self.cache = .init(key: cache.key, targets: cache.targets, expires: .distantPast) }
    }
    func shutdown() async {
        desiredKey = nil
        cache = nil
        if let current = pending { pending = nil; current.task.cancel(); await current.client.shutdown() }
    }
    static func readTargets(authorization: RemoteControlCatalogAuthorization, clientID: String,
                            identity: RemoteControlCatalogIdentity,
                            fetch: @Sendable (URLRequest) async throws -> Data) async throws -> [RemoteControlActivityTarget] {
        guard RemoteControlCatalogIdentity.validIdentifier(clientID) else { throw CodexClientError.invalidResponse }
        var targets: [String: RemoteControlActivityTarget] = [:], cursor: String?, seen: Set<String> = []
        for page in 0..<8 {
            try Task.checkCancellation()
            var components = URLComponents(url: authorization.backendOrigin, resolvingAgainstBaseURL: false)!
            components.path = "/backend-api/codex/remote/control/clients/\(clientID)/environments"
            components.queryItems = [.init(name: "limit", value: "100")] + (cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
            guard let url = components.url else { throw CodexClientError.invalidResponse }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "GET"
            request.setValue("Bearer " + authorization.token, forHTTPHeaderField: "Authorization")
            request.setValue(authorization.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("codex-pacer-island", forHTTPHeaderField: "originator")
            request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
            let data = try await fetch(request)
            guard data.count <= 512 * 1024 else { throw CodexClientError.invalidResponse }
            let fields = try JSONFieldView.document(data).fields(["items", "cursor"])
            guard let items = fields["items"], items.isArray else { throw CodexClientError.invalidResponse }
            for item in try items.elements(maximumCount: 100) {
                guard item.isObject else { throw CodexClientError.invalidResponse }
                let row = try item.fields(["env_id", "display_name", "name", "host_name", "online"])
                guard let id = row["env_id"]?.string(), RemoteControlCatalogIdentity.validIdentifier(id) else { throw CodexClientError.invalidResponse }
                if id == identity.localEnvironmentID { continue }
                func name(_ key: String) -> String? {
                    row[key]?.string(limit: 128).map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }) }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
                }
                let label = name("display_name") ?? name("name") ?? name("host_name") ?? "Remote Control (\(id.suffix(8)))"
                let host = "remote-control:" + id
                targets[host] = .init(id: host, name: label, online: row["online"]?.boolean())
            }
            guard let next = fields["cursor"], !next.isNull else { break }
            guard let value = next.string(limit: 2048), !value.isEmpty, seen.insert(value).inserted, page < 7 else { throw CodexClientError.invalidResponse }
            cursor = value
        }
        return targets.values.sorted {
            if ($0.id == identity.selectedHost) != ($1.id == identity.selectedHost) { return $0.id == identity.selectedHost }
            if ($0.online == true) != ($1.online == true) { return $0.online == true }
            return $0.id < $1.id
        }
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func fetch(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodexClientError.invalidResponse }
        guard response.statusCode == 200 else { throw CatalogError.status(response.statusCode) }
        guard response.expectedContentLength <= 512 * 1024 else { throw CodexClientError.invalidResponse }
        var data = Data()
        for try await byte in stream {
            guard data.count < 512 * 1024 else { throw CodexClientError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
