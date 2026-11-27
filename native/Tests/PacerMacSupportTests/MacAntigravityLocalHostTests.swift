import Foundation
import XCTest
@testable import PacerCore
@testable import PacerMacSupport

final class MacAntigravityLocalHostTests: XCTestCase {
    private final class Response: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let headers: [String: String]
            switch url.lastPathComponent {
            case "encoded": headers = ["Content-Encoding": "gzip"]
            case "declared": headers = ["Content-Length": "5"]
            default: headers = [:]
            }
            let status = url.lastPathComponent == "denied" ? 403 : 200
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([1, 2]))
            client?.urlProtocol(self, didLoad: Data([3, 4]))
            if url.lastPathComponent == "overflow" { client?.urlProtocol(self, didLoad: Data([5])) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testChunkLimitAndDiscardedErrorBodies() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Response.self]
        func read(_ path: String) async throws -> (Int, Data) {
            let url = try XCTUnwrap(URL(string: "https://fixture.invalid/" + path))
            return try await MacAntigravityLocalHost.read(URLRequest(url: url), configuration: config, maximumBytes: 4)
        }
        let (ok, bytes) = try await read("exact")
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
        for path in ["overflow", "declared", "encoded"] {
            do { _ = try await read(path); XCTFail("Accepted an invalid response") }
            catch AntigravityLocalClient.Failure.oversized {}
        }
        let (denied, body) = try await read("denied")
        XCTAssertEqual(denied, 403)
        XCTAssertTrue(body.isEmpty)
    }
}
