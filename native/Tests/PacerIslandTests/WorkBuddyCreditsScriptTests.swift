import JavaScriptCore
import XCTest
@testable import PacerCore

/// WorkBuddy's credits script, run in JavaScriptCore against canned replies:
/// which endpoints it asks, and what reading comes back. The Mac runs it in
/// WebKit and Windows in WebView2; neither changes these rules.
final class WorkBuddyCreditsScriptTests: XCTestCase {
    private enum Fault: String, CaseIterable { case network, invalidJSON }
    private struct Route { var status = 200; var json: Any = NSNull(); var fault: Fault? = nil }
    private struct Run { let result: [String: Any]; let requests: [[String: Any]] }

    private func run(origin: String = "https://www.workbuddy.cn", selected: String? = nil, routes: [String: Route]) throws -> Run {
        let script = try XCTUnwrap(HarnessRegistry.descriptor(for: .workbuddy)?.accountCredits?.summaryScript)
        func literal(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        let table = try literal(routes.mapValues { ["status": $0.status, "json": $0.json, "fault": $0.fault?.rawValue ?? ""] })
        let storage = try literal(selected.map { ["CODEBUDDY_IDE_SELECTED_ACCOUNT_ID": $0] } ?? [:])
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() }
        context.evaluateScript("""
        const __origin = \(try literal(origin)), __routes = \(table), __storage = \(storage), __requests = [];
        var document = { baseURI: __origin + "/" };
        class URL { constructor(value) { this.origin = /^https?:\\/\\/[^\\/]+/.exec(value)[0]; } }
        class TextDecoder { decode(value) { return value ? value.text : ""; } }
        class AbortController { constructor() { this.signal = {}; } abort() {} }
        function setTimeout() { return 0; } function clearTimeout() {}
        var localStorage = { getItem: key => __storage[key] ?? null };
        function fetch(url, options) {
            __requests.push({ url: url.replace(__origin, ""), method: options?.method ?? "GET", headers: options?.headers ?? {} });
            const route = __routes[url.replace(__origin, "")];
            if (!route) return Promise.resolve({ status: 404, headers: { get: () => "text/html" }, body: null });
            if (route.fault === "network") return Promise.reject(new TypeError("Network error"));
            const text = route.fault === "invalidJSON" ? "{" : JSON.stringify(route.json); let sent = false;
            return Promise.resolve({ status: route.status, headers: { get: name => name.toLowerCase() === "content-type" ? "application/json" : null },
                body: { getReader: () => ({ read: async () => sent ? { done: true } : (sent = true, { done: false, value: { length: text.length, text } }),
                    cancel: async () => {} }) } });
        }
        var __output = null;
        (async function() {
        \(script)
        })().then(result => { __output = JSON.stringify({ result, requests: __requests }); },
                  error => { __output = JSON.stringify({ error: String(error) }); });
        """)
        var output: String?
        for _ in 0..<50 where output == nil {
            if let value = context.evaluateScript("__output"), !value.isNull, !value.isUndefined { output = value.toString() }
        }
        XCTAssertNil(failure)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output).utf8)) as? [String: Any])
        XCTAssertNil(object["error"])
        return Run(result: try XCTUnwrap(object["result"] as? [String: Any]), requests: object["requests"] as? [[String: Any]] ?? [])
    }

    private func decoded(_ result: [String: Any]) throws -> HarnessAccountCredits {
        try JSONDecoder().decode(HarnessAccountCredits.self, from: JSONSerialization.data(withJSONObject: result))
    }

    private static let accounts: [String: Any] = ["data": ["accounts": [
        ["type": "personal", "uid": "user-1"],
        ["type": "ultimate", "uid": "user-1", "enterpriseId": "ent-42"],
    ]]]
    private static let personal: [String: Route] = [
        "/billing/meter/get-user-resource-summary": Route(json: ["code": 0, "data": [
            "SubscriptionPackageCode": "TCACA_code_002_plan", "SubscriptionPackageName": "Pro",
            "Packages": [["CapacityUnit": "credits", "PackageCode": "TCACA_code_002_plan", "CycleRemainCapacity": 800,
                          "CycleTotalCapacity": 1000, "CycleUsedCapacity": 200, "CycleEndTime": "2099-11-30 23:59:59"]]]]),
        "/billing/meter/get-user-resource-paid-packages": Route(json: ["code": 0, "data": ["Accounts": [], "TotalCount": 0]]),
        "/billing/meter/get-user-resource-free-packages": Route(json: ["code": 0, "data": ["Accounts": [], "TotalCount": 0]]),
    ]
    private static let resetAt = ISO8601DateFormatter().date(from: "2099-12-01T00:00:00+08:00")!.timeIntervalSince1970

    func testAnEnterpriseMemberReadsTheCycleQuotaTheirAdministratorAssigns() throws {
        var routes = Self.personal
        routes["/console/accounts"] = Route(json: Self.accounts)
        routes["/billing/meter/get-enterprise-user-usage"] = Route(json: ["code": 0, "data": [
            "credit": 420.69, "limitNum": 2000, "cycleStartTime": "2099-11-01 00:00:00", "cycleEndTime": "2099-11-30 23:59:59"]])
        let run = try run(selected: "ent-42", routes: routes)
        XCTAssertEqual(run.result["state"] as? String, "ready")
        XCTAssertEqual(run.result["plan"] as? String, "企业版")
        let usage = try XCTUnwrap(run.requests.first { $0["url"] as? String == "/billing/meter/get-enterprise-user-usage" })
        XCTAssertEqual(usage["method"] as? String, "POST")
        XCTAssertEqual((usage["headers"] as? [String: Any])?["X-Enterprise-Id"] as? String, "ent-42")
        XCTAssertFalse(run.requests.contains { $0["url"] as? String == "/billing/meter/get-user-resource-summary" },
                       "The personal packages are not the enterprise member's balance")
        let reading = try XCTUnwrap(try decoded(run.result).reading(at: Date(timeIntervalSince1970: Self.resetAt - 86_400)))
        XCTAssertEqual(reading.total, 2000)
        XCTAssertEqual(reading.remaining, 1579.31, accuracy: 0.001)
        XCTAssertEqual(reading.cycle?.used ?? -1, 420.69, accuracy: 0.001)
        XCTAssertEqual(reading.cycle?.resetsAt?.timeIntervalSince1970, Self.resetAt, "The cycle resets the second after it ends")
    }

    func testAnEnterpriseGiftJoinsTheMonth() throws {
        var routes = Self.personal
        routes["/console/accounts"] = Route(json: Self.accounts)
        routes["/billing/meter/get-enterprise-user-usage"] = Route(json: ["code": 0, "data": [
            "credit": 100, "limitNum": 1000, "cycleEndTime": "2099-11-30 23:59:59",
            "exclusiveGift": ["hasGift": true, "usedCredits": 50, "totalCredits": 500, "remainCredits": 450, "nextResetAt": "2099-11-30 23:59:59"]]])
        let run = try run(selected: "ent-42", routes: routes)
        let reading = try XCTUnwrap(try decoded(run.result).reading(at: Date(timeIntervalSince1970: Self.resetAt - 86_400)))
        XCTAssertEqual(reading.total, 1500)
        XCTAssertEqual(reading.remaining, 1350, accuracy: 0.001)
        XCTAssertEqual(reading.cycle?.used ?? -1, 150, accuracy: 0.001)
    }

    func testAPersonalAccountKeepsReadingItsPackages() throws {
        var routes = Self.personal
        routes["/console/accounts"] = Route(json: ["data": ["accounts": [["type": "personal", "uid": "user-1", "lastLogin": true]]]])
        let personal = try run(routes: routes)
        XCTAssertEqual(personal.result["state"] as? String, "ready")
        XCTAssertEqual(personal.result["plan"] as? String, "Pro")
        XCTAssertEqual(personal.result["remaining"] as? Double, 800)
        XCTAssertFalse(personal.requests.contains { $0["url"] as? String == "/billing/meter/get-enterprise-user-usage" })
        // Without a stored choice, the account last signed into decides, as on the site.
        var enterprise = Self.personal
        enterprise["/console/accounts"] = Route(json: ["data": ["accounts": [
            ["type": "personal", "uid": "user-1"], ["type": "ultimate", "uid": "user-1", "enterpriseId": "ent-42", "lastLogin": true]]]])
        enterprise["/billing/meter/get-enterprise-user-usage"] = Route(json: ["code": 0, "data": ["credit": 0, "limitNum": 100, "cycleEndTime": "2099-11-30 23:59:59"]])
        XCTAssertEqual(try run(routes: enterprise).result["plan"] as? String, "企业版")
    }

    func testWithoutTheAccountListThePersonalPackagesAreRead() throws {
        let run = try run(routes: Self.personal)
        XCTAssertEqual(run.result["state"] as? String, "ready")
        XCTAssertEqual(run.result["plan"] as? String, "Pro")
    }

    func testFailedEnterpriseUsageDoesNotReadThePersonalBalance() throws {
        let accountsPath = "/console/accounts"
        let usagePath = "/billing/meter/get-enterprise-user-usage"
        var routes = Self.personal
        routes[accountsPath] = Route(json: Self.accounts)
        for fault in Fault.allCases {
            routes[usagePath] = Route(fault: fault)
            let run = try run(selected: "ent-42", routes: routes)
            XCTAssertEqual(run.result["state"] as? String, "unavailable", fault.rawValue)
            XCTAssertNil(try decoded(run.result).reading(), fault.rawValue)
            XCTAssertEqual(run.requests.compactMap { $0["url"] as? String }, [accountsPath, usagePath], fault.rawValue)
        }
    }

    func testAnUnlimitedQuotaOrAnExpiredSessionGivesNoBalance() throws {
        var routes = Self.personal
        routes["/console/accounts"] = Route(json: Self.accounts)
        routes["/billing/meter/get-enterprise-user-usage"] = Route(json: ["code": 0, "data": ["credit": 12, "limitNum": -1, "cycleEndTime": "2099-11-30 23:59:59"]])
        XCTAssertEqual(try run(selected: "ent-42", routes: routes).result["state"] as? String, "unavailable",
                       "An unlimited quota has no balance to draw")
        routes["/console/accounts"] = Route(status: 401, json: ["code": 401])
        XCTAssertEqual(try run(selected: "ent-42", routes: routes).result["state"] as? String, "signIn")
        routes["/console/accounts"] = Route(json: Self.accounts)
        routes["/billing/meter/get-enterprise-user-usage"] = Route(json: ["code": 401])
        XCTAssertEqual(try run(selected: "ent-42", routes: routes).result["state"] as? String, "signIn")
    }
}
