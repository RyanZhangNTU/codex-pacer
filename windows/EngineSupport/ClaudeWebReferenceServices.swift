import Foundation
import PacerCore
import FoundationNetworking

/// Available only to the explicit demo/reference CLI fixture. Requests still
/// pass through the original client and cookie bridge; transport never connects.
extension ClaudeQuotaServices {
    static func reference(bridge: ClaudeWebBridge, now: @escaping @Sendable () -> Date) -> Self {
        .init(makeClient: { home, organization, context in
            BridgedClaudeQuotaClient(bridge: bridge, home: home, organization: organization, context: context,
                metadataProvider: { .init() }, transport: { request in
                    guard request.httpMethod == "GET", let url = request.url, url.scheme == "https", url.host == "claude.ai" else { throw ClaudeQuotaError.invalidReply }
                    let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                    let secondAccount = cookie.contains("sessionKey=fixture-claude-account-b")
                    let account = secondAccount ? "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" : "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                    let authenticated = cookie.contains("sessionKey=fixture-claude-account-a") || cookie.contains("sessionKey=fixture-claude-account-b")
                    let status = !authenticated ? 401 : cookie.contains("pacer_fixture_status=503") ? 503 : cookie.contains("pacer_fixture_status=429") ? 429 : 200
                    var payload: Any
                    switch url.path {
                    case "/api/account": payload = ["uuid": account]
                    case "/api/organizations": payload = secondAccount ? [["uuid": "33333333-3333-4333-8333-333333333333", "name": "Synthetic second account workspace"]] : [
                        ["uuid": "11111111-1111-4111-8111-111111111111", "name": "Synthetic workspace A"],
                        ["uuid": "22222222-2222-4222-8222-222222222222", "name": "Synthetic workspace B"]]
                    default:
                        guard url.path.hasPrefix("/api/organizations/"), url.path.hasSuffix("/usage") else { throw ClaudeQuotaError.invalidReply }
                        let used = url.path.contains("22222222-") ? 55 : 25
                        payload = ["five_hour": ["utilization": used, "resets_at": now().addingTimeInterval(1800).timeIntervalSince1970],
                                   "seven_day": ["utilization": used + 10, "resets_at": now().addingTimeInterval(604800).timeIntervalSince1970]]
                    }
                    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Retry-After": "120"])!
                    return (try JSONSerialization.data(withJSONObject: payload), response)
                }, now: now)
        }, history: nil)
    }
}

extension ClaudeCloudServices {
    static func reference(bridge: ClaudeWebBridge, now: @escaping @Sendable () -> Date) -> Self {
        .init(makeClient: { input in
            BridgedClaudeCloudClient(bridge: bridge, input: input, transport: { request in
                guard request.httpMethod == "GET", let url = request.url, url.scheme == "https", url.host == "claude.ai",
                      url.path.hasPrefix("/v1/code/") else { throw ClaudeCloudFailure.invalidReply }
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                let secondAccount = cookie.contains("sessionKey=fixture-claude-account-b")
                let authenticated = secondAccount || cookie.contains("sessionKey=fixture-claude-account-a")
                let organization = request.value(forHTTPHeaderField: "x-organization-uuid") ?? ""
                let allowed = secondAccount ? organization == "33333333-3333-4333-8333-333333333333" :
                    ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"].contains(organization)
                let status = !authenticated ? 401 : !allowed ? 403 : cookie.contains("pacer_fixture_status=503") ? 503 : 200
                let suffix = organization.hasPrefix("333") ? "3" : organization.hasPrefix("222") ? "2" : "1"
                let project = "chan_project" + suffix, worker = "cse_worker" + suffix, coordinator = "cse_coordinator" + suffix
                let body: [String: Any]
                if url.path == "/v1/code/channels" {
                    body = ["channels": [["id": project, "name": "Synthetic cloud project " + suffix,
                        "overview_session_id": coordinator, "last_activity_at": ISO8601DateFormatter().string(from: now())]]]
                } else if url.path.hasSuffix("/threads") {
                    body = ["sections": [["data": [["id": "cmsg_thread" + suffix, "thread_status": "working", "thread_any_session_working": true,
                        "title": "Synthetic cloud thread " + suffix, "bound_sessions": [["id": worker]]]]]]]
                } else if url.path.hasSuffix("/events") { body = ["events": []] }
                else { body = ["session": ["id": url.path.hasSuffix(worker) ? worker : coordinator,
                    "worker_status": "running", "connection_status": "connected", "status_bucket": "working"]] }
                return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!)
            }, streamLines: { _ in AsyncThrowingStream { continuation in continuation.yield(Data(": synthetic keepalive".utf8)) } }, now: now)
        })
    }
}
