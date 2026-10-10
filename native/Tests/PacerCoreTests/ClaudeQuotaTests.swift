import XCTest
@testable import PacerCore

final class ClaudeQuotaTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testUsageWindowsKeepExactPercentagesAndAuthoritativeResets() throws {
        let value = try ClaudeQuotaDecoder.decodeUsage(Data(#"{"five_hour":{"utilization":23.5,"resets_at":"2027-01-15T13:00:00.123Z"},"seven_day":{"utilization":41.25,"resets_at":1800604800},"seven_day_sonnet":{"utilization":12,"resets_at":"2027-01-15T13:00:00Z"},"seven_day_opus":null}"#.utf8), capturedAt: date, accountScope: "scope", plan: "max")
        XCTAssertEqual(value.buckets.map(\.id), ["claude", "claude/sonnet"])
        XCTAssertEqual(value.buckets.first?.plan, "max")
        XCTAssertEqual(value.windows.map(\.durationMinutes), [300, 10080, 10080])
        XCTAssertEqual(value.windows.map(\.usedPercent), [23.5, 41.25, 12])
        XCTAssertEqual(value.windows[1].resetsAt, date.addingTimeInterval(604800))
        XCTAssertEqual(value.windows[1].remainingPercent, 58.75)
        XCTAssertEqual(value.accountScope, "scope")
        XCTAssertNil(value.credits)
        XCTAssertNil(value.resetCredits)
    }

    func testMissingPercentageAndMissingResetRemainIndependentUnknowns() throws {
        let value = try ClaudeQuotaDecoder.decodeUsage(Data(#"{"five_hour":{"utilization":null,"resets_at":1800000300},"seven_day":{"utilization":0,"resets_at":null}}"#.utf8), capturedAt: date)
        XCTAssertNil(value.windows[0].remainingPercent)
        XCTAssertEqual(value.windows[1].remainingPercent, 100)
        XCTAssertNil(value.windows[1].pacePercent(at: date))
        XCTAssertNil(value.windows[1].resetsAt)
        for invalid in [#"{"five_hour":{"utilization":true}}"#, #"{"five_hour":{"utilization":"23"}}"#,
                        #"{"five_hour":{"utilization":-2}}"#, #"{"five_hour":null}"#] {
            XCTAssertThrowsError(try ClaudeQuotaDecoder.decodeUsage(Data(invalid.utf8))) {
                XCTAssertEqual($0 as? ClaudeQuotaError, .unavailable)
            }
        }
    }

    func testStatusLineOptionalWindowsAndExpiredDeadlineDoNotInventPace() throws {
        let value = try ClaudeQuotaDecoder.decodeStatusLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":18.5,"resets_at":1799999999},"seven_day":null}}"#.utf8), capturedAt: date)
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertEqual(value.windows[0].usedPercent, 18.5)
        XCTAssertNil(value.windows[0].pacePercent(at: date))
        XCTAssertThrowsError(try ClaudeQuotaDecoder.decodeStatusLine(Data(#"{"context_window":{"used_percentage":90}}"#.utf8)))
    }

    func testModelScopedWeeklyLimitsAreDistinctAndBounded() throws {
        let value = try ClaudeQuotaDecoder.decodeUsage(Data(#"{"five_hour":{"utilization":4},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Claude Model"}},"percent":40,"resets_at":1800604800},{"kind":"weekly_scoped","scope":{"model":{"display_name":"Claude Model"}},"percent":50},{"kind":"other","scope":{"model":{"display_name":"Other"}},"percent":60}]}"#.utf8), capturedAt: date)
        XCTAssertEqual(value.buckets.count, 2)
        XCTAssertEqual(value.buckets[1].name, "Claude Model")
        XCTAssertEqual(value.buckets[1].windows[0].remainingPercent, 60)
        XCTAssertEqual(value.buckets[1].windows[0].durationMinutes, 10080)
    }

    func testDesktopHistorySelectsLatestMatchingOrganizationWithoutResetGuess() throws {
        let data = Data(#"{"version":2,"samples":[{"t":1799999700000,"org":"active","u":{"fh":15,"sd":25}},{"t":1800000000000,"org":"other","u":{"fh":99}},{"t":1799999800000,"org":"active","u":{"fh":20,"sd":30}},{"t":1800001000000,"org":"active","u":{"fh":80}}]}"#.utf8)
        let value = try ClaudeQuotaDecoder.decodeDesktopHistory(data, organizationID: "active", accountScope: "verified", now: date)
        XCTAssertEqual(value.capturedAt, date.addingTimeInterval(-200))
        XCTAssertEqual(value.windows.map(\.usedPercent), [20, 30])
        XCTAssertTrue(value.windows.allSatisfy { $0.resetsAt == nil && $0.pacePercent(at: date) == nil })
        XCTAssertThrowsError(try ClaudeQuotaDecoder.decodeDesktopHistory(data, organizationID: "absent", accountScope: "verified", now: date))
        XCTAssertThrowsError(try ClaudeQuotaDecoder.decodeDesktopHistory(Data(#"{"version":1,"samples":[{"t":1800000000000,"fh":50}]}"#.utf8), organizationID: "active", accountScope: "verified", now: date))
    }

    func testUsageMalformedAndOversizedBodiesProduceSanitizedErrors() {
        for data in [Data(#"{"error":"private-fixture-message"}"#.utf8), Data("[]".utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try ClaudeQuotaDecoder.decodeUsage(data)) {
                XCTAssertTrue($0 is ClaudeQuotaError)
                XCTAssertFalse($0.localizedDescription.contains("private-fixture-message"))
            }
        }
    }

    func testCustomHomeDoesNotReadDefaultCredentialServiceOrIdentity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"accountUuid":"account","organizationUuid":"org"}}"#.utf8)
            .write(to: root.appendingPathComponent(".claude.json"))
        try Data(#"{"claudeAiOauth":{"accessToken":"test-custom-token","expiresAt":1800000100000,"subscriptionType":"pro"}}"#.utf8)
            .write(to: custom.appendingPathComponent(".credentials.json"))
        XCTAssertEqual(ClaudeCredentialStore.serviceName(userHome: root, home: root.appendingPathComponent(".claude")), "Claude Code-credentials")
        XCTAssertNotEqual(ClaudeCredentialStore.serviceName(userHome: root, home: custom), "Claude Code-credentials")
        XCTAssertNil(ClaudeCredentialStore.identity(userHome: root, home: custom))
        let credential = try XCTUnwrap(ClaudeCredentialStore.read(userHome: root, home: custom, environment: [:]))
        XCTAssertEqual(credential.token, "test-custom-token")
        XCTAssertEqual(credential.scope, ClaudeQuotaDecoder.digest("claude-token|test-custom-token"))
        let overridden = try XCTUnwrap(ClaudeCredentialStore.read(userHome: root, home: root.appendingPathComponent(".claude"), environment: ["CLAUDE_CODE_OAUTH_TOKEN": "test-override"]))
        XCTAssertEqual(overridden.scope, ClaudeQuotaDecoder.digest("claude-token|test-override"))
        XCTAssertNotEqual(overridden.scope, ClaudeCredentialStore.identity(userHome: root, home: root.appendingPathComponent(".claude"))?.scope)
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-quota-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

final class ClaudeQuotaClientTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = String(repeating: "a", count: 64)
    private let usage = Data(#"{"five_hour":{"utilization":10,"resets_at":1800018000},"seven_day":{"utilization":20,"resets_at":1800604800}}"#.utf8)

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func client(_ root: URL, credentialProvider: (@Sendable () throws -> ClaudeOAuthCredential?)? = nil,
                        desktopCredentialProvider: (@Sendable () throws -> ClaudeOAuthCredential?)? = nil,
                        identityProvider: (@Sendable () -> (scope: String, organizationID: String)?)? = nil,
                        now: (@Sendable () -> Date)? = nil,
                        transport: @escaping ClaudeQuotaClient.Transport) -> ClaudeQuotaClient {
        let capturedAt = date, accountScope = scope
        let clock: @Sendable () -> Date = now ?? { capturedAt }
        return ClaudeQuotaClient(statusLineURL: root.appendingPathComponent("statusline.json"),
            credentialProvider: credentialProvider ?? {
                ClaudeOAuthCredential(token: "fixture-token", expiresAt: nil, plan: "pro", scope: accountScope)
            }, desktopCredentialProvider: desktopCredentialProvider,
            identityProvider: identityProvider ?? { (accountScope, "fixture-org") }, transport: transport, now: clock)
    }

    func testLiveReadIsGetOnlyAndReturnsTrueResetsWithSource() async throws {
        let root = try directory(), payload = usage
        defer { try? FileManager.default.removeItem(at: root) }
        let value = client(root) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertNil(request.httpBody)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let snapshot = try await value.readQuota()
        XCTAssertEqual(snapshot.windows[0].resetsAt, date.addingTimeInterval(18000))
        let source = await value.currentSource(), currentScope = await value.currentAccountScope()
        XCTAssertEqual(source, .oauthUsage)
        XCTAssertEqual(currentScope, scope)
    }

    func testRecentScopeMatchedOfficialSampleRetainsOriginalCaptureTime() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample: [String: Any] = ["captured_at": date.timeIntervalSince1970 - 30, "account_scope": scope,
            "payload": ["rate_limits": ["five_hour": ["used_percentage": 22, "resets_at": date.timeIntervalSince1970 + 100]]]]
        try JSONSerialization.data(withJSONObject: sample).write(to: root.appendingPathComponent("statusline.json"))
        let value = client(root) { _ in XCTFail("recent official data should not call private service"); throw ClaudeQuotaError.connectionFailed }
        let snapshot = try await value.readQuota()
        XCTAssertEqual(snapshot.capturedAt, date.addingTimeInterval(-30))
        XCTAssertEqual(snapshot.windows[0].usedPercent, 22)
        let source = await value.currentSource()
        XCTAssertEqual(source, .statusLine)
    }

    func testPassiveStatusLineOnlyNeverReadsCredentialsOrHTTPAndRejectsOldSample() async throws {
        let root = try directory(), capturedAt = date, savedScope = scope
        defer { try? FileManager.default.removeItem(at: root) }
        let sample: [String: Any] = ["captured_at": capturedAt.timeIntervalSince1970 - 30, "account_scope": savedScope,
            "payload": ["rate_limits": ["five_hour": ["used_percentage": 22, "resets_at": capturedAt.timeIntervalSince1970 + 100]]]]
        let url = root.appendingPathComponent("statusline.json")
        try JSONSerialization.data(withJSONObject: sample).write(to: url)
        let clock = Box(capturedAt)
        let value = ClaudeQuotaClient(statusLineURL: url, credentialProvider: {
            XCTFail("passive samples must not access credentials"); throw ClaudeQuotaError.keychainAccessRequired
        }, identityProvider: { (savedScope, "fixture-org") }, transport: { _ in
            XCTFail("passive samples must not access HTTP"); throw ClaudeQuotaError.connectionFailed
        }, now: { clock.value })
        let fresh = await value.readStatusLineOnly()
        XCTAssertEqual(fresh?.capturedAt, capturedAt.addingTimeInterval(-30))
        let source = await value.currentSource()
        XCTAssertEqual(source, .statusLine)
        clock.value = capturedAt.addingTimeInterval(31)
        let expired = await value.readStatusLineOnly()
        XCTAssertNil(expired)
    }

    func testDifferentAccountAndFutureCacheNeverOverrideLiveAccount() async throws {
        let root = try directory(), payload = usage
        defer { try? FileManager.default.removeItem(at: root) }
        for (accountScope, timestamp) in [(String(repeating: "b", count: 64), date.timeIntervalSince1970),
                                         (scope, date.timeIntervalSince1970 + 60)] {
            let sample: [String: Any] = ["captured_at": timestamp, "account_scope": accountScope,
                "payload": ["rate_limits": ["five_hour": ["used_percentage": 99]]]]
            try JSONSerialization.data(withJSONObject: sample).write(to: root.appendingPathComponent("statusline.json"))
            let value = client(root) { request in (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            let snapshot = try await value.readQuota()
            XCTAssertEqual(snapshot.windows[0].usedPercent, 10)
            XCTAssertEqual(snapshot.accountScope, scope)
        }
    }

    func testTokenChangeWithUnchangedSavedIdentityRejectsInFlightReply() async throws {
        let root = try directory(), payload = usage, accountScope = scope
        defer { try? FileManager.default.removeItem(at: root) }
        let token = Box("first-fixture-token")
        let value = client(root, credentialProvider: {
            ClaudeOAuthCredential(token: token.value, expiresAt: nil, plan: nil, scope: accountScope)
        }) { request in
            token.value = "second-fixture-token"
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await value.readQuota(); XCTFail("changed token must invalidate reply") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .accountChanged) }
        let source = await value.currentSource(), currentScope = await value.currentAccountScope()
        XCTAssertNil(source); XCTAssertNil(currentScope)
    }

    func testCredentialExpiryAndHttpFailureContainNoResponseDetails() async throws {
        let root = try directory(), accountScope = scope, expiration = date.addingTimeInterval(-1)
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = client(root, credentialProvider: {
            ClaudeOAuthCredential(token: "fixture-token", expiresAt: expiration, plan: nil, scope: accountScope)
        }) { _ in XCTFail("expired token must not be sent"); throw ClaudeQuotaError.connectionFailed }
        do { _ = try await expired.readQuota(); XCTFail("expiry must remain unavailable") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .credentialsExpired) }
        for (status, expected) in [(401, ClaudeQuotaError.notLoggedIn), (403, .denied), (429, .unavailable), (503, .connectionFailed)] {
            let value = client(root) { request in
                (Data("private-fixture-response".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await value.readQuota(); XCTFail("HTTP error must remain unavailable") }
            catch {
                XCTAssertEqual(error as? ClaudeQuotaError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private-fixture-response"))
            }
        }
    }

    func testCallerCancellationStopsOwnedQuotaRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "request started")
        let value = client(root) { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw ClaudeQuotaError.connectionFailed
        }
        let task = Task { try await value.readQuota() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled read must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let source = await value.currentSource()
        XCTAssertNil(source)
    }

    func testRejectedCliTokenUsesExistingScopedDesktopTokenWithoutRefresh() async throws {
        let root = try directory(), payload = usage, accountScope = scope
        defer { try? FileManager.default.removeItem(at: root) }
        let value = client(root, desktopCredentialProvider: {
            ClaudeOAuthCredential(token: "fixture-desktop-token", expiresAt: nil, plan: nil, scope: accountScope)
        }) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-desktop-token" ? 200 : 401
            return (payload, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let snapshot = try await value.readQuota()
        XCTAssertEqual(snapshot.accountScope, scope)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 10)
    }

    func testBackgroundCredentialAccessFailureHasActionableStaticError() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = client(root, credentialProvider: { throw ClaudeQuotaError.keychainAccessRequired },
                           desktopCredentialProvider: { throw ClaudeQuotaError.keychainAccessRequired }) { _ in
            XCTFail("blocked credential read must never make a request"); throw ClaudeQuotaError.connectionFailed
        }
        do { _ = try await value.readQuota(); XCTFail("access must remain unavailable") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .keychainAccessRequired) }
    }

    func testTransientFailureRetainsVerifiedScopeButAuthFailureClearsIt() async throws {
        let root = try directory(), payload = usage
        defer { try? FileManager.default.removeItem(at: root) }
        let status = Box(200)
        let value = client(root) { request in
            (payload, HTTPURLResponse(url: request.url!, statusCode: status.value, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await value.readQuota()
        status.value = 503
        do { _ = try await value.readQuota(); XCTFail("outage should throw") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .connectionFailed) }
        let retained = await value.currentAccountScope(), source = await value.currentSource()
        XCTAssertEqual(retained, scope)
        XCTAssertEqual(source, .oauthUsage)
        status.value = 401
        do { _ = try await value.readQuota(); XCTFail("auth failure should throw") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .notLoggedIn) }
        let cleared = await value.currentAccountScope()
        XCTAssertNil(cleared)
    }

    func testRejectedAuthenticationCannotResurrectOlderScopedStatusLineCache() async throws {
        let root = try directory(), payload = usage
        defer { try? FileManager.default.removeItem(at: root) }
        let sample: [String: Any] = ["captured_at": date.timeIntervalSince1970 - 120, "account_scope": scope,
            "payload": ["rate_limits": ["five_hour": ["used_percentage": 99]]]]
        try JSONSerialization.data(withJSONObject: sample).write(to: root.appendingPathComponent("statusline.json"))
        let value = client(root) { request in
            (payload, HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await value.readQuota(); XCTFail("rejected auth must not use old cache") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .notLoggedIn) }
        let currentScope = await value.currentAccountScope(), source = await value.currentSource()
        XCTAssertNil(currentScope); XCTAssertNil(source)
    }

    func testSuccessfulDesktopProviderIsPreferredUntilItsVerifiedCredentialChanges() async throws {
        let root = try directory(), payload = usage, accountScope = scope
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = Box<[String]>([]), cliAccepted = Box(false), desktopToken = Box("desktop-fixture-token")
        let value = client(root, desktopCredentialProvider: {
            ClaudeOAuthCredential(token: desktopToken.value, expiresAt: nil, plan: nil, scope: accountScope)
        }) { request in
            let desktop = request.value(forHTTPHeaderField: "Authorization") != "Bearer fixture-token"
            requests.value.append(desktop ? "desktop" : "cli")
            let status = desktop || cliAccepted.value ? 200 : 401
            return (payload, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await value.readQuota()
        XCTAssertEqual(requests.value, ["cli", "desktop"])
        _ = try await value.readQuota()
        XCTAssertEqual(requests.value, ["cli", "desktop", "desktop"])
        desktopToken.value = "changed-desktop-fixture-token"
        cliAccepted.value = true
        _ = try await value.readQuota()
        XCTAssertEqual(requests.value, ["cli", "desktop", "desktop", "cli"])
    }

    func testRetryAfterSuppressesNetworkKeepsVerifiedScopeAndDoesNotDelayAnotherAccount() async throws {
        let root = try directory(), payload = usage
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Box(date), account = Box(scope), token = Box("first-fixture-token"), status = Box(200), requests = Box(0)
        let value = client(root, credentialProvider: {
            ClaudeOAuthCredential(token: token.value, expiresAt: nil, plan: nil, scope: account.value)
        }, identityProvider: { (account.value, "fixture-org") }, now: { clock.value }) { request in
            requests.value += 1
            return (payload, HTTPURLResponse(url: request.url!, statusCode: status.value, httpVersion: nil,
                                            headerFields: ["Retry-After": "120"])!)
        }
        let original = try await value.readQuota()
        status.value = 429
        do { _ = try await value.readQuota(); XCTFail("429 should be unavailable") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .unavailable) }
        clock.value = date.addingTimeInterval(30)
        do { _ = try await value.readQuota(); XCTFail("backoff should be unavailable") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .unavailable) }
        XCTAssertEqual(requests.value, 2)
        let retained = await value.currentAccountScope(), retry = await value.nextRetryAt()
        XCTAssertEqual(retained, scope)
        XCTAssertEqual(retry, date.addingTimeInterval(120))
        XCTAssertEqual(original.capturedAt, date)
        account.value = String(repeating: "b", count: 64)
        token.value = "second-account-fixture-token"
        status.value = 200
        let changed = try await value.readQuota()
        XCTAssertEqual(requests.value, 3)
        XCTAssertEqual(changed.accountScope, account.value)
        let clearedRetry = await value.nextRetryAt()
        XCTAssertNil(clearedRetry)
        status.value = 429
        do { _ = try await value.readQuota() } catch { }
        clock.value = date.addingTimeInterval(151)
        status.value = 200
        _ = try await value.readQuota()
        XCTAssertEqual(requests.value, 5)
    }

    func testRetryAfterDateParsingIsBoundedAndUnknownHeadersRemainUnknown() {
        XCTAssertEqual(ClaudeQuotaClient.retryDate("3600", now: date), date.addingTimeInterval(600))
        XCTAssertEqual(ClaudeQuotaClient.retryDate("120.5", now: date), date.addingTimeInterval(120.5))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(ClaudeQuotaClient.retryDate(formatter.string(from: date.addingTimeInterval(120)), now: date), date.addingTimeInterval(120))
        for value in [nil, "", "NaN", "-30", "0", "unknown"] as [String?] {
            XCTAssertNil(ClaudeQuotaClient.retryDate(value, now: date))
        }
    }

    func testRecentOfficialSampleRemainsUsableDuringPrivateServiceBackoff() async throws {
        let root = try directory(), payload = usage
        defer { try? FileManager.default.removeItem(at: root) }
        let status = Box(200), requests = Box(0)
        let value = client(root) { request in
            requests.value += 1
            return (payload, HTTPURLResponse(url: request.url!, statusCode: status.value, httpVersion: nil,
                                            headerFields: ["Retry-After": "120"])!)
        }
        _ = try await value.readQuota()
        status.value = 429
        do { _ = try await value.readQuota(); XCTFail("private service should ask for backoff") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .unavailable) }
        let sample: [String: Any] = ["captured_at": date.timeIntervalSince1970 - 10, "account_scope": scope,
            "payload": ["rate_limits": ["five_hour": ["used_percentage": 22, "resets_at": date.timeIntervalSince1970 + 100]]]]
        let sampleURL = root.appendingPathComponent("statusline.json")
        try JSONSerialization.data(withJSONObject: sample).write(to: sampleURL)
        let snapshot = try await value.readQuota()
        XCTAssertEqual(snapshot.capturedAt, date.addingTimeInterval(-10))
        XCTAssertEqual(snapshot.windows[0].usedPercent, 22)
        let source = await value.currentSource(), retry = await value.nextRetryAt()
        XCTAssertEqual(source, .statusLine)
        XCTAssertEqual(retry, date.addingTimeInterval(120))
        XCTAssertEqual(requests.value, 2)
        try FileManager.default.removeItem(at: sampleURL)
        do { _ = try await value.readQuota(); XCTFail("private backoff must remain after sample disappears") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .unavailable) }
        XCTAssertEqual(requests.value, 2)
    }

    func testNarrowCredentialIsSavedOnlyAfterValidatedReplyAndSaveFailureIsObservable() async throws {
        let root = try directory(), payload = usage, capturedAt = date, savedScope = scope
        defer { try? FileManager.default.removeItem(at: root) }
        let status = Box(200), writes = Box(0), invalidations = Box(0)
        let value = ClaudeQuotaClient(statusLineURL: root.appendingPathComponent("absent-statusline.json"), credentialProvider: {
            ClaudeOAuthCredential(token: "fixture-token", expiresAt: capturedAt.addingTimeInterval(100), plan: nil, scope: savedScope)
        }, identityProvider: { (savedScope, "fixture-org") }, transport: { request in
            (payload, HTTPURLResponse(url: request.url!, statusCode: status.value, httpVersion: nil, headerFields: nil)!)
        }, now: { capturedAt }, persistVerifiedCredentials: true, rememberCredential: { index, credential in
            XCTAssertEqual(index, 0)
            XCTAssertEqual(credential.scope, savedScope)
            writes.value += 1
            return false
        }, invalidateCredential: { _ in invalidations.value += 1 })
        _ = try await value.readQuota()
        let saved = await value.connectionSaved()
        XCTAssertEqual(saved, false)
        XCTAssertEqual(writes.value, 1)
        status.value = 401
        do { _ = try await value.readQuota(); XCTFail("rejected credential must be unavailable") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .notLoggedIn) }
        XCTAssertEqual(writes.value, 1, "Rejected credentials must not be persisted")
        XCTAssertEqual(invalidations.value, 1)
    }

    func testAutomaticFileCredentialReadDoesNotImportTokenIntoPacerKeychain() async throws {
        let root = try directory(), payload = usage, capturedAt = date
        defer { try? FileManager.default.removeItem(at: root) }
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let home = userHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let identity: [String: Any] = ["oauthAccount": ["accountUuid": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "organizationUuid": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]]
        try JSONSerialization.data(withJSONObject: identity).write(to: userHome.appendingPathComponent(".claude.json"))
        let file: [String: Any] = ["claudeAiOauth": ["accessToken": "fixture-file-token", "expiresAt": capturedAt.addingTimeInterval(100).timeIntervalSince1970 * 1000]]
        try JSONSerialization.data(withJSONObject: file).write(to: home.appendingPathComponent(".credentials.json"))
        let active = try XCTUnwrap(ClaudeCredentialStore.identity(userHome: userHome, home: home)), writes = Box(0)
        let value = ClaudeQuotaClient(statusLineURL: root.appendingPathComponent("absent-statusline.json"), credentialProvider: {
            try ClaudeCredentialStore.read(userHome: userHome, home: home, environment: [:], cachedCredential: { _ in nil }, now: capturedAt)
        }, identityProvider: { (active.scope, active.organizationID) }, transport: { request in
            (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { capturedAt }, rememberCredential: { _, _ in writes.value += 1; return true })
        _ = try await value.readQuota()
        XCTAssertEqual(writes.value, 0)
        let saved = await value.connectionSaved()
        XCTAssertNil(saved)
    }
}
