import XCTest
@testable import PacerCore

final class ClaudeWebQuotaTests: XCTestCase {
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let org = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let otherOrg = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let usage = Data(#"{"five_hour":{"utilization":12,"resets_at":"2027-01-15T13:00:00Z"},"seven_day":{"utilization":34,"resets_at":1800604800}}"#.utf8)

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    private func cookies(_ token: String = "fixture-web-session", organization: String? = nil) -> ClaudeWebSession {
        ClaudeWebSession(cookieHeader: "sessionKey=" + token + "; cf_clearance=fixture-clearance",
                         sessionHash: ClaudeQuotaDecoder.digest(token), organizationID: organization)
    }

    private func accountData() throws -> Data { try JSONSerialization.data(withJSONObject: ["uuid": account]) }
    private func organizationsData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [["uuid": org, "name": "Synthetic A"], ["uuid": otherOrg, "name": "Synthetic B"]])
    }
    private func response(_ request: URLRequest, data: Data, status: Int = 200, headers: [String: String]? = nil) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func testReadOnlyExactHostTrueResetsAndCachedIdentityAvoidRepeatedMetadataRequests() async throws {
        let session = cookies(organization: org), binding = ClaudeWebAccountBinding(accountID: account, organizationID: org)
        let accountReply = try accountData(), orgReply = try organizationsData(), payload = usage, capturedAt = date
        let paths = Box<[String]>([])
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { binding }, transport: { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.scheme, "https"); XCTAssertEqual(request.url?.host, "claude.ai")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), session.cookieHeader)
            paths.value.append(request.url!.path)
            let data = request.url!.path == "/api/account" ? accountReply : request.url!.path == "/api/organizations" ? orgReply : payload
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { capturedAt })
        let first = try await value.readQuota(), second = try await value.readQuota()
        XCTAssertEqual(first.windows.map(\.usedPercent), [12, 34])
        XCTAssertNotNil(first.windows[0].resetsAt)
        XCTAssertEqual(first.windows[1].resetsAt, Date(timeIntervalSince1970: 1_800_604_800))
        XCTAssertEqual(second.capturedAt, date)
        XCTAssertEqual(first.accountScope, ClaudeQuotaDecoder.digest("claude|" + account + "|" + org))
        XCTAssertEqual(paths.value, ["/api/account", "/api/organizations", "/api/organizations/" + org + "/usage", "/api/organizations/" + org + "/usage"])
        let source = await value.currentSource()
        XCTAssertEqual(source, .webSession)
    }

    func testOrganizationMustBeSelectedAndCannotGuessFirstMembership() async throws {
        let session = cookies(), chosen = Box<String?>(nil), capturedAt = date
        let accountReply = try accountData(), orgReply = try organizationsData(), payload = usage, calls = Box(0)
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { ClaudeWebAccountBinding() },
            selectedOrganizationProvider: { chosen.value }, transport: { request in
                calls.value += 1
                let data = request.url!.path == "/api/account" ? accountReply : request.url!.path == "/api/organizations" ? orgReply : payload
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, now: { capturedAt })
        do { _ = try await value.readQuota(); XCTFail("Membership order must not choose the quota owner") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .organizationSelectionRequired) }
        XCTAssertEqual(calls.value, 2)
        let choices = await value.organizations()
        XCTAssertEqual(choices.map(\.id), [org, otherOrg])
        chosen.value = otherOrg
        let snapshot = try await value.readQuota()
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(snapshot.accountScope, ClaudeQuotaDecoder.digest("claude|" + account + "|" + otherOrg))
    }

    func testAccountAndSessionChangesCannotPublishPreviousOwnerQuota() async throws {
        let current = Box(cookies(organization: org)), binding = Box(ClaudeWebAccountBinding(accountID: account, organizationID: org))
        let accountReply = try accountData(), orgReply = try organizationsData(), payload = usage, capturedAt = date
        let changeDuringUsage = Box(false), replacement = cookies("replacement-fixture-session", organization: org)
        let value = ClaudeWebQuotaClient(cookieProvider: { current.value }, metadataProvider: { binding.value }, transport: { request in
            let path = request.url!.path
            if path.contains("/usage"), changeDuringUsage.value { current.value = replacement }
            let data = path == "/api/account" ? accountReply : path == "/api/organizations" ? orgReply : payload
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { capturedAt })
        _ = try await value.readQuota()
        changeDuringUsage.value = true
        do { _ = try await value.readQuota(); XCTFail("Changed web session must reject an in-flight result") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .accountChanged) }
        let cleared = await value.currentAccountScope()
        XCTAssertNil(cleared)
        changeDuringUsage.value = false
        binding.value = ClaudeWebAccountBinding(accountID: "dddddddd-dddd-dddd-dddd-dddddddddddd", organizationID: org)
        do { _ = try await value.readQuota(); XCTFail("Observed account must match browser account") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .accountChanged) }
    }

    func testChallengePreservesVerifiedCookieScopeAndDoesNotRetryOrMisreportExpiredLogin() async throws {
        let session = cookies(organization: org), binding = ClaudeWebAccountBinding(accountID: account, organizationID: org)
        let accountReply = try accountData(), orgReply = try organizationsData(), payload = usage, capturedAt = date
        let challenge = Box(false), calls = Box(0)
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { binding }, transport: { request in
            calls.value += 1
            if challenge.value { return (Data("<html>challenge</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil,
                headerFields: ["cf-mitigated": "challenge", "Content-Type": "text/html"])!) }
            let data = request.url!.path == "/api/account" ? accountReply : request.url!.path == "/api/organizations" ? orgReply : payload
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { capturedAt })
        let first = try await value.readQuota()
        challenge.value = true
        do { _ = try await value.readQuota(); XCTFail("Challenge is unavailable quota, not expired login") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .webChallenge) }
        XCTAssertEqual(calls.value, 4)
        let retained = await value.currentAccountScope()
        XCTAssertEqual(retained, first.accountScope)
        XCTAssertNotNil(ClaudeWebQuotaDecoder.sessionKey(session))
    }

    func testUsageQueryFallbackIsOneReadAnd401ClearsIdentityWithoutChangingCookieProvider() async throws {
        let session = cookies(organization: org), binding = ClaudeWebAccountBinding(accountID: account, organizationID: org)
        let accountReply = try accountData(), orgReply = try organizationsData(), payload = usage, capturedAt = date
        let status = Box(200), queries = Box<[String?]>([])
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { binding }, transport: { request in
            let path = request.url!.path
            if path.contains("/usage") {
                queries.value.append(request.url?.query)
                let code = status.value == 401 ? 401 : request.url?.query == nil ? 200 : 400
                return (payload, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            return (path == "/api/account" ? accountReply : orgReply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { capturedAt })
        _ = try await value.readQuota()
        XCTAssertEqual(queries.value, ["cedar_ember=1", nil])
        status.value = 401
        do { _ = try await value.readQuota(); XCTFail("Authentication rejection must need sign in") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .notLoggedIn) }
        let scope = await value.currentAccountScope()
        XCTAssertNil(scope)
        XCTAssertEqual(queries.value.count, 3)
        XCTAssertNotNil(ClaudeWebQuotaDecoder.sessionKey(session))
    }

    func testRetryAfterIsScopedToSessionAndDoesNotPollDuringDelay() async throws {
        let current = Box(cookies(organization: org)), binding = ClaudeWebAccountBinding(accountID: account, organizationID: org)
        let accountReply = try accountData(), orgReply = try organizationsData(), payload = usage
        let clock = Box(date), status = Box(200), calls = Box(0)
        let value = ClaudeWebQuotaClient(cookieProvider: { current.value }, metadataProvider: { binding }, transport: { request in
            calls.value += 1
            let path = request.url!.path, code = path.contains("/usage") ? status.value : 200
            let data = path == "/api/account" ? accountReply : path == "/api/organizations" ? orgReply : payload
            return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }, now: { clock.value })
        let original = try await value.readQuota()
        status.value = 429
        do { _ = try await value.readQuota() } catch { XCTAssertEqual(error as? ClaudeQuotaError, .unavailable) }
        clock.value = date.addingTimeInterval(30)
        do { _ = try await value.readQuota() } catch { XCTAssertEqual(error as? ClaudeQuotaError, .unavailable) }
        XCTAssertEqual(calls.value, 4)
        let retained = await value.currentAccountScope(), retry = await value.nextRetryAt()
        XCTAssertEqual(retained, original.accountScope)
        XCTAssertEqual(retry, date.addingTimeInterval(120))
        current.value = cookies("new-fixture-session", organization: org)
        status.value = 200
        _ = try await value.readQuota()
        XCTAssertEqual(calls.value, 7)
    }

    func testInvalidCookieHashMalformedOrganizationsAndForeignReplyAreRejected() async throws {
        let malformed = ClaudeWebSession(cookieHeader: "sessionKey=fixture-session", sessionHash: String(repeating: "a", count: 64))
        XCTAssertNil(ClaudeWebQuotaDecoder.sessionKey(malformed))
        XCTAssertNil(ClaudeWebQuotaDecoder.sessionKey(ClaudeWebSession(cookieHeader: "sessionKey=x\r\nOther: injected", sessionHash: ClaudeQuotaDecoder.digest("x"))))
        XCTAssertThrowsError(try ClaudeWebQuotaDecoder.organizations(Data("[]".utf8)))
        XCTAssertThrowsError(try ClaudeWebQuotaDecoder.organizations(try JSONSerialization.data(withJSONObject: [["uuid": org], ["uuid": org]])))
        let capturedAt = date, session = cookies(organization: org)
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { ClaudeWebAccountBinding() }, transport: { _ in
            (Data("{}".utf8), HTTPURLResponse(url: URL(string: "https://untrusted.example/api/account")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { capturedAt })
        do { _ = try await value.readQuota(); XCTFail("A reply from another host must not be accepted") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .invalidReply) }
    }

    func testChangedOrganizationDuringBackoffCannotRetainPreviousQuotaAndJSON403ClearsScope() async throws {
        let session = cookies(), selected = Box<String?>(org), binding = ClaudeWebAccountBinding(accountID: account)
        let accountReply = try accountData(), orgReply = try organizationsData(), payload = usage
        let clock = Box(date), status = Box(200), calls = Box(0)
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { binding },
            selectedOrganizationProvider: { selected.value }, transport: { request in
                calls.value += 1
                let path = request.url!.path, code = path.contains("/usage") ? status.value : 200
                let data = path == "/api/account" ? accountReply : path == "/api/organizations" ? orgReply : payload
                return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
            }, now: { clock.value })
        _ = try await value.readQuota()
        status.value = 429
        do { _ = try await value.readQuota() } catch { }
        selected.value = otherOrg
        clock.value = date.addingTimeInterval(30)
        do { _ = try await value.readQuota() } catch { XCTAssertEqual(error as? ClaudeQuotaError, .unavailable) }
        XCTAssertEqual(calls.value, 4)
        let changed = await value.currentAccountScope()
        XCTAssertNil(changed)
        status.value = 200; clock.value = date.addingTimeInterval(121)
        let next = try await value.readQuota()
        XCTAssertEqual(next.accountScope, ClaudeQuotaDecoder.digest("claude|" + account + "|" + otherOrg))
        status.value = 403
        do { _ = try await value.readQuota(); XCTFail("Revoked permission must reject quota") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .denied) }
        let denied = await value.currentAccountScope()
        XCTAssertNil(denied)
        XCTAssertNotNil(ClaudeWebQuotaDecoder.sessionKey(session))
    }

    func testCancellationStopsOwnedRequest() async throws {
        let capturedAt = date, session = cookies(organization: org), started = Box(false)
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { ClaudeWebAccountBinding() }, transport: { _ in
            started.value = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw ClaudeQuotaError.connectionFailed
        }, now: { capturedAt })
        let task = Task { try await value.readQuota() }
        for _ in 0..<100 where !started.value { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must interrupt the owned request") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testUnexpectedTransportErrorCannotExposeRequestOrCookieText() async throws {
        struct PrivateTransportFailure: LocalizedError {
            var errorDescription: String? { "synthetic-private-cookie-and-account-text" }
        }
        let capturedAt = date, session = cookies(organization: org)
        let value = ClaudeWebQuotaClient(cookieProvider: { session }, metadataProvider: { ClaudeWebAccountBinding() },
            transport: { _ in throw PrivateTransportFailure() }, now: { capturedAt })
        do { _ = try await value.readQuota(); XCTFail("transport failure must be sanitized") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .connectionFailed) }
    }
}
