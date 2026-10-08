import Foundation

public struct RefreshedTokens: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: TimeInterval?

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

extension RefreshedTokens: CustomStringConvertible {
    public var description: String { "RefreshedTokens(expiresIn: \(String(describing: expiresIn)), tokens: <redacted>)" }
}

public enum RefreshError: Error, Equatable {
    case rejected(String)      // terminal OAuth error (invalid_grant / invalid_client)
    case transient(String)     // network, 5xx, 429, malformed response...
    case notAllowed            // issuer/token endpoint isn't https://auth.x.ai
    case notConfigured         // entry lacks refresh_token / issuer / client id
}

public protocol TokenRefreshing: Sendable {
    func refresh(_ credential: GrokCredential) async throws -> RefreshedTokens
}

/// Renews a Grok CLI login exactly like the CLI does (xai-org/grok-build, `xai-grok-login/src/oidc`):
/// 1. `GET {oidc_issuer}/.well-known/openid-configuration` (no credentials) to find `token_endpoint`.
/// 2. `POST token_endpoint` form-encoded: `grant_type=refresh_token`, `refresh_token`, `client_id`
///    (+ `principal_type` / `principal_id` when the login has them).
/// 3. Read `access_token`, optional rotated `refresh_token`, and `expires_in`.
/// Only `https://auth.x.ai` is accepted for both the issuer and the token endpoint.
public final class OIDCTokenRefresher: TokenRefreshing, @unchecked Sendable {
    public static let allowedHost = "auth.x.ai"

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host?.lowercased() == allowedHost,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return true
    }

    public func refresh(_ c: GrokCredential) async throws -> RefreshedTokens {
        guard let rt = c.refreshToken, let issuer = c.issuer, let clientID = c.clientID, c.canRefresh else {
            throw RefreshError.notConfigured
        }
        let issuerURL = URL(string: issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer)
        guard Self.isAllowed(issuerURL), let issuerURL else { throw RefreshError.notAllowed }

        let tokenEndpoint = try await discoverTokenEndpoint(issuerURL)
        guard Self.isAllowed(tokenEndpoint) else { throw RefreshError.notAllowed }

        var fields = [("grant_type", "refresh_token"), ("refresh_token", rt), ("client_id", clientID)]
        if let pt = c.principalType { fields.append(("principal_type", pt)) }
        if let pid = c.principalID { fields.append(("principal_id", pid)) }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(fields).utf8)

        // One retry for failures that never reached the server or were clearly server-side.
        var lastError: RefreshError = .transient("Refresh failed")
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            do {
                return try await exchange(request)
            } catch let e as RefreshError {
                lastError = e
                if case .transient(let why) = e, why.hasPrefix("retryable:") { continue }
                throw e
            }
        }
        if case .transient(let why) = lastError {
            throw RefreshError.transient(why.replacingOccurrences(of: "retryable:", with: ""))
        }
        throw lastError
    }

    private func exchange(_ request: URLRequest) async throws -> RefreshedTokens {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                throw RefreshError.transient("retryable:network")
            default:
                throw RefreshError.transient("network")
            }
        }
        guard let http = response as? HTTPURLResponse else { throw RefreshError.transient("bad response") }
        guard (200..<300).contains(http.statusCode) else {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            if let code, code == "invalid_grant" || code == "invalid_client" {
                throw RefreshError.rejected(code)
            }
            if http.statusCode >= 500 || http.statusCode == 429 {
                throw RefreshError.transient("retryable:HTTP \(http.statusCode)")
            }
            throw RefreshError.transient("HTTP \(http.statusCode)")   // body never surfaced
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: FlexibleNumber?
        }
        guard let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !parsed.access_token.isEmpty else { throw RefreshError.transient("malformed token response") }
        return RefreshedTokens(accessToken: parsed.access_token,
                               refreshToken: (parsed.refresh_token?.isEmpty ?? true) ? nil : parsed.refresh_token,
                               expiresIn: parsed.expires_in?.value)
    }

    private func discoverTokenEndpoint(_ issuer: URL) async throws -> URL {
        let url = issuer.appendingPathComponent(".well-known").appendingPathComponent("openid-configuration")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirects())
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let endpoint = (doc["token_endpoint"] as? String).flatMap(URL.init(string:))
            else { throw RefreshError.transient("discovery failed") }
            return endpoint
        } catch let e as RefreshError {
            throw e
        } catch {
            throw RefreshError.transient("discovery unreachable")
        }
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }
}

/// Refuses every redirect so a bearer or refresh token can never be forwarded to another URL.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
