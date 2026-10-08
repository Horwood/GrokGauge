import Foundation

public enum FetchError: Error, Equatable {
    case auth(AuthError)
    case unauthorized(Int)      // 401 / 403 from the endpoint, even after renewing
    case http(Int)
    case network(String)
    case badResponse
}

/// Fetches the shared weekly usage pool from the (unofficial) Grok CLI billing endpoint.
/// The access token goes only to `endpoint`; renewal (refresh token -> auth.x.ai) lives in `AuthSession`.
public final class BillingClient: @unchecked Sendable {
    public static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    public let auth: AuthSession
    private let session: URLSession
    private let userAgent: String

    public init(appVersion: String = "dev", auth: AuthSession = AuthSession()) {
        self.auth = auth
        let config = URLSessionConfiguration.ephemeral   // no disk cache, no cookie jar
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        userAgent = "GrokGauge/\(appVersion) (macOS menu bar)"
    }

    public func fetch() async throws -> UsageSnapshot {
        let first = try await credential(rejecting: nil)
        do {
            return try await fetchBilling(with: first)
        } catch FetchError.unauthorized {
            // Token refused: renew (or adopt a token the CLI renewed) and retry exactly once.
            let renewed = try await credential(rejecting: first)
            return try await fetchBilling(with: renewed)
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

    private func fetchBilling(with credential: GrokCredential) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            // Refuse redirects so the bearer token can never follow a redirect to another host.
            (data, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch let e as URLError {
            throw FetchError.network(Self.describe(e))
        } catch {
            throw FetchError.network("Request failed")
        }

        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw FetchError.unauthorized(http.statusCode)
        default: throw FetchError.http(http.statusCode)   // body intentionally never surfaced
        }

        do {
            return try UsageParser.parse(data, now: Date())
        } catch {
            throw FetchError.badResponse
        }
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost: return "You're offline"
        case .timedOut: return "Request timed out"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach grok.com"
        case .httpTooManyRedirects, .redirectToNonExistentLocation: return "Unexpected redirect"
        default: return "Network error"
        }
    }
}
