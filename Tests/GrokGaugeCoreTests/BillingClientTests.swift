import Foundation
import Testing
@testable import GrokGaugeCore

/// Scripted replies; records each request and which connection (transport) carried it.
final class ScriptedTransports: @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var error: URLError? = nil }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var log: [(transport: Int, request: URLRequest)] = []
    private(set) var made = 0
    private(set) var closed: Set<Int> = []

    init(_ replies: [Reply]) { self.replies = replies }

    func make() -> BillingTransport {
        let id = lock.withLock { made += 1; return made }
        return Transport(id: id, owner: self)
    }

    fileprivate func next(_ id: Int, _ request: URLRequest) throws -> (Data, URLResponse) {
        let reply = lock.withLock { () -> Reply in
            log.append((id, request))
            return replies.isEmpty ? Reply(status: 599, body: "") : replies.removeFirst()
        }
        if let e = reply.error { throw e }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/3", headerFields: [:])!
        return (Data(reply.body.utf8), response)
    }

    fileprivate func close(_ id: Int) { lock.withLock { _ = closed.insert(id) } }

    struct Transport: BillingTransport {
        let id: Int
        let owner: ScriptedTransports
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) { try owner.next(id, request) }
        func close() { owner.close(id) }
    }
}

let okBilling = """
{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-06T20:57:54.858014+00:00",
  "end":"2026-10-13T20:57:54.858014+00:00"},"creditUsagePercent":12}}
"""

@Suite struct BillingClientTests {
    /// Token in the fixture is valid for 3+ hours at this time, so no renewal happens.
    let early = ISODate.parse("2026-10-07T04:00:00Z")!

    func client(_ script: ScriptedTransports, _ tmp: TempAuthDir) -> BillingClient {
        let refresher = MockRefresher { _, _ in throw AuthError.refreshRejected }
        let auth = AuthSession(authURL: tmp.authURL, refresher: refresher, lockTimeout: 1, clock: { early })
        return BillingClient(appVersion: "test", auth: auth, retryDelay: 0, makeTransport: { script.make() })
    }

    // Regression (2026-10-08): one reused HTTP/3 connection answered every request with 400 for ~14 min
    // while new connections got 200. A 400 must be retried once on a brand-new connection.
    @Test func http400IsRetriedOnAFreshConnection() async throws {
        let tmp = try TempAuthDir()
        let script = ScriptedTransports([.init(status: 400, body: #"{"error":"upstream request timed out"}"#),
                                         .init(status: 200, body: okBilling)])
        let s = try await client(script, tmp).fetch()
        #expect(s.percent == 12)
        #expect(script.log.map(\.transport) == [1, 2])     // second try went out on a new transport
        #expect(script.closed == [1, 2])                   // and nothing is kept for the next refresh
    }

    @Test func eachRefreshOpensItsOwnConnection() async throws {
        let tmp = try TempAuthDir()
        let script = ScriptedTransports([.init(status: 200, body: okBilling), .init(status: 200, body: okBilling)])
        let c = client(script, tmp)
        _ = try await c.fetch()
        _ = try await c.fetch()
        #expect(script.log.map(\.transport) == [1, 2])
        #expect(script.closed == [1, 2])
    }

    @Test func persistent400SurfacesTheServerMessage() async throws {
        let tmp = try TempAuthDir()
        let script = ScriptedTransports([.init(status: 400, body: #"{"error":"Invalid request"}"#),
                                         .init(status: 400, body: #"{"code":3,"error":"Invalid request for user_ABC123xyz789"}"#)])
        await #expect(throws: FetchError.http(400, message: "Invalid request for ‹redacted›")) {
            try await client(script, tmp).fetch()
        }
        #expect(script.log.count == 2)
    }

    @Test func rateLimitAndAuthAreNotRetriedOnANewConnection() async throws {
        let tmp = try TempAuthDir()
        let script = ScriptedTransports([.init(status: 429, body: "slow down")])
        await #expect(throws: FetchError.http(429, message: "slow down")) { try await client(script, tmp).fetch() }
        #expect(script.log.count == 1)

        let offline = ScriptedTransports([.init(status: 0, body: "", error: URLError(.notConnectedToInternet))])
        await #expect(throws: FetchError.network("You're offline")) { try await client(offline, tmp).fetch() }
        #expect(offline.log.count == 1)
    }

    @Test func dropped5xxConnectionIsRetried() async throws {
        let tmp = try TempAuthDir()
        let script = ScriptedTransports([.init(status: 0, body: "", error: URLError(.networkConnectionLost)),
                                         .init(status: 200, body: okBilling)])
        _ = try await client(script, tmp).fetch()
        #expect(script.log.map(\.transport) == [1, 2])
    }

    @Test func requestCarriesOnlyTheExpectedHeaders() async throws {
        let tmp = try TempAuthDir()
        let script = ScriptedTransports([.init(status: 200, body: okBilling)])
        _ = try await client(script, tmp).fetch()
        let r = try #require(script.log.first?.request)
        #expect(r.url == BillingClient.endpoint)
        #expect(r.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer access-OLD")
        #expect(r.value(forHTTPHeaderField: "x-grok-client-mode") == "cli")
        #expect(r.value(forHTTPHeaderField: "User-Agent") == "GrokGauge/test (macOS menu bar)")
        #expect(Set(r.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) ==
                ["authorization", "accept", "x-grok-client-mode", "user-agent"])
    }
}

@Suite struct ServerErrorMessageTests {
    func extract(_ s: String) -> String? { ServerErrorMessage.extract(from: Data(s.utf8)) }

    @Test func readsCommonShapes() {
        #expect(extract(#"{"error":"Bad request"}"#) == "Bad request")
        #expect(extract(#"{"error":{"message":"Period not found","code":5}}"#) == "Period not found")
        #expect(extract(#"{"message":"Try again later"}"#) == "Try again later")
        #expect(extract("upstream connect error\n") == "upstream connect error")
        #expect(extract("<html><body>400 Bad Request</body></html>") == nil)
        #expect(extract("") == nil)
        #expect(extract(#"{"error":""}"#) == nil)
        #expect(extract(#"{"status":400}"#) == nil)
    }

    @Test func neverLeaksSecrets() {
        let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1In0.c2lnbmF0dXJlLXN0dWZm"
        let m = extract(#"{"error":"token \#(jwt) for me@example.com rejected (Authorization: Bearer abc.def)"}"#)!
        #expect(!m.contains("eyJ"))
        #expect(!m.contains("me@example.com"))
        #expect(!m.contains("abc.def"))
        #expect(m.contains("rejected"))
        let opaque = String(repeating: "k", count: 40)
        #expect(!(extract(#"{"error":"bad key \#(opaque)"}"#) ?? "").contains(opaque))
    }

    @Test func isShortAndSingleLine() {
        let long = String(repeating: "word ", count: 100)
        let m = extract(#"{"error":"\#(long)"}"#)!
        #expect(m.count <= ServerErrorMessage.maxLength)
        #expect(m.hasSuffix("…"))
        #expect(extract("line one\r\nline\ttwo") == "line one line two")
    }
}
