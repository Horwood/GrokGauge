import Foundation

public enum FetchError: Error, Equatable {
    case auth(AuthError)
    case unauthorized(Int)      // 401 / 403 from the endpoint
    case http(Int)
    case network(String)
    case badResponse
}

/// Fetches the shared weekly usage pool from the (unofficial) Grok CLI billing endpoint.
public final class BillingClient: @unchecked Sendable {
    public static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private let session: URLSession
    private let userAgent: String

    public init(appVersion: String = "dev") {
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

    public func fetch(now: Date = Date()) async throws -> UsageSnapshot {
        let credential: GrokCredential
        do {
            credential = try AuthStore.load(now: now)
        } catch let e as AuthError {
            throw FetchError.auth(e)
        }

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
            return try UsageParser.parse(data, now: now)
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

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
