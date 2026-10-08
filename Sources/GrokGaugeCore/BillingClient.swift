import Foundation

public enum FetchError: Error, Equatable {
    case auth(AuthError)
    case unauthorized(Int)      // 401 / 403 from the endpoint, even after renewing
    /// Any other non-2xx reply. `message` is the server's own error text, sanitized
    /// (no tokens, emails or ids) and shortened, when the reply carried one.
    case http(Int, message: String?)
    case network(String)
    case badResponse
    /// The reply is JSON but not shaped like the billing config GrokGauge knows ("xAI changed something").
    case unexpectedShape

    public var statusCode: Int? {
        switch self {
        case .unauthorized(let c), .http(let c, _): return c
        default: return nil
        }
    }

    /// Worth one immediate retry on a brand-new connection. A reused HTTP/2 or HTTP/3 connection stays
    /// pinned to one proxy instance; if that instance is failing (seen 2026-10-08: every request on one
    /// QUIC connection got 400 after ~5 s while fresh connections got 200), retrying on it can't help.
    var wantsFreshConnection: Bool {
        switch self {
        case .http(let code, _): return code == 400 || code == 408 || code == 421 || (500...599).contains(code)
        case .network(let m): return m != BillingClient.offlineMessage
        default: return false
        }
    }
}

/// One HTTP exchange. The real one is a URLSession; tests script replies.
public protocol BillingTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
    /// Drops pooled connections so the next request opens a new one.
    func close()
}

/// Ephemeral URLSession (no disk cache, no cookie jar) that refuses every redirect.
public final class URLSessionTransport: BillingTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Refuse redirects so the bearer token can never follow a redirect to another host.
        try await session.data(for: request, delegate: NoRedirects())
    }

    public func close() { session.finishTasksAndInvalidate() }
}

/// Fetches the shared weekly usage pool from the (unofficial) Grok CLI billing endpoint.
/// The access token goes only to `endpoint`; renewal (refresh token -> auth.x.ai) lives in `AuthSession`.
public final class BillingClient: @unchecked Sendable {
    public static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let offlineMessage = "You're offline"

    public let auth: AuthSession
    private let userAgent: String
    private let makeTransport: @Sendable () -> BillingTransport
    private let retryDelay: TimeInterval

    /// `makeTransport` and `retryDelay` exist for tests.
    public init(appVersion: String = "dev", auth: AuthSession = AuthSession(),
                retryDelay: TimeInterval = 2,
                makeTransport: @escaping @Sendable () -> BillingTransport = { URLSessionTransport() }) {
        self.auth = auth
        self.userAgent = "GrokGauge/\(appVersion) (macOS menu bar)"
        self.retryDelay = retryDelay
        self.makeTransport = makeTransport
    }

    /// Each refresh uses its own short-lived session, so a connection is never reused across refreshes
    /// (they're minutes apart; reuse saved nothing and could pin GrokGauge to a failing proxy instance).
    public func fetch() async throws -> UsageSnapshot {
        let transport = makeTransport()
        defer { transport.close() }
        do {
            return try await fetchOnce(transport)
        } catch let e as FetchError where e.wantsFreshConnection {
            transport.close()
            if retryDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000)) }
            let fresh = makeTransport()
            defer { fresh.close() }
            return try await fetchOnce(fresh)
        }
    }

    private func fetchOnce(_ transport: BillingTransport) async throws -> UsageSnapshot {
        let first = try await credential(rejecting: nil)
        do {
            return try await fetchBilling(with: first, transport)
        } catch FetchError.unauthorized {
            // Token refused: renew (or adopt a token the CLI renewed) and retry exactly once.
            let renewed = try await credential(rejecting: first)
            return try await fetchBilling(with: renewed, transport)
        }
    }

    private func credential(rejecting rejected: GrokCredential?) async throws -> GrokCredential {
        do {
            return try await auth.credential(rejecting: rejected).credential
        } catch let e as AuthError {
            throw FetchError.auth(e)
        } catch {
            throw FetchError.auth(.refreshUnavailable)
        }
    }

    func request(with credential: GrokCredential) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func fetchBilling(with credential: GrokCredential, _ transport: BillingTransport) async throws -> UsageSnapshot {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request(with: credential))
        } catch let e as URLError {
            throw FetchError.network(Self.describe(e))
        } catch {
            throw FetchError.network("Request failed")
        }

        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw FetchError.unauthorized(http.statusCode)
        default: throw FetchError.http(http.statusCode, message: ServerErrorMessage.extract(from: data))
        }

        do {
            return try UsageParser.parse(data, now: Date())
        } catch let e as UsageParserError where e.isShapeChange {
            throw FetchError.unexpectedShape
        } catch {
            throw FetchError.badResponse
        }
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet: return offlineMessage
        case .networkConnectionLost: return "Connection dropped"
        case .timedOut: return "Request timed out"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach grok.com"
        case .httpTooManyRedirects, .redirectToNonExistentLocation: return "Unexpected redirect"
        default: return "Network error"
        }
    }
}

/// Pulls a short, human-readable error out of a non-2xx reply body, for Diagnostics.
/// Only well-known fields are read, the text is scrubbed of anything that looks like a token,
/// email, id or path, and it's capped at `maxLength` characters. HTML error pages yield nil.
public enum ServerErrorMessage {
    public static let maxLength = 160

    public static func extract(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= 64 * 1024 else { return nil }
        var text: String?
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            text = message(in: obj, depth: 0)
        } else if let s = String(data: data, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.hasPrefix("<") { text = t }   // plain text, not an HTML page
        }
        return text.flatMap(sanitize)
    }

    private static func message(in obj: Any, depth: Int) -> String? {
        guard depth < 3 else { return nil }
        if let s = obj as? String { return s }
        guard let dict = obj as? [String: Any] else { return nil }
        for key in ["error", "message", "detail", "error_description", "msg"] {
            if let v = dict[key], let found = message(in: v, depth: depth + 1) { return found }
        }
        return nil
    }

    public static func sanitize(_ raw: String) -> String? {
        var s = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
        s = s.replacingOccurrences(of: #"(?i)bearer\s+\S+"#, with: "Bearer ‹redacted›", options: .regularExpression)
        s = DiagnosticsReport.scrub(s)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.count > maxLength { s = String(s.prefix(maxLength - 1)) + "…" }
        return s
    }
}
