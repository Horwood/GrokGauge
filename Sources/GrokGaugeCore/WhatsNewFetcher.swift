import Foundation

/// One GET. The real one is an ephemeral URLSession; tests script replies.
public protocol NewsHTTP: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral session: no cookies, no disk cache, short timeouts. Redirects are followed only to
/// https URLs on the same host (docs.x.ai moves pages around within its own site).
public final class URLSessionNewsHTTP: NewsHTTP, @unchecked Sendable {
    private let session: URLSession
    public static let maxBytes = 3 * 1024 * 1024

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: SameHostRedirects())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= Self.maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, http)
    }
}

final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url?.host, let to = request.url,
              to.scheme == "https", to.host == from else { return nil }
        return request
    }
}

/// Result of checking one source.
public struct NewsFetchResult: Sendable {
    public var items: [NewsItem]?          // nil: not modified (keep what we have)
    public var etag: String?
    public var lastModified: String?
    public var note: String?               // short status for Diagnostics, e.g. "installed 1.0.46, latest 1.0.50"
}

public enum NewsFetchError: Error, Equatable, Sendable {
    case http(Int)
    case network(String)
    case unreadable
    case notInstalled

    public var message: String {
        switch self {
        case .http(let c): return "HTTP \(c)"
        case .network(let m): return m
        case .unreadable: return "Couldn't read the reply (format changed?)"
        case .notInstalled: return "Not installed on this Mac"
        }
    }
}

/// Fetches and parses each What's new source. Sends only a GrokGauge User-Agent: no logins, tokens or ids.
public struct WhatsNewFetcher: Sendable {
    public static let newsSitemap = URL(string: "https://x.ai/sitemap.xml")!
    public static let releaseNotesMarkdown = URL(string: "https://docs.x.ai/developers/release-notes.md")!
    /// Article pages fetched per check, for titles of newly listed posts.
    public static let maxArticleFetches = 5

    public let http: NewsHTTP
    public let userAgent: String
    public var grokHome: URL
    public var grokBotApps: [URL]

    public init(appVersion: String, http: NewsHTTP = URLSessionNewsHTTP(),
                grokHome: URL = GrokCLIVersion.defaultHome, grokBotApps: [URL] = GrokBotMacApp.candidates) {
        self.http = http
        self.userAgent = "GrokGauge/\(appVersion) (macOS menu bar)"
        self.grokHome = grokHome
        self.grokBotApps = grokBotApps
    }

    func request(_ url: URL, accept: String, state: NewsSourceState? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        if let e = state?.etag { r.setValue(e, forHTTPHeaderField: "If-None-Match") }
        if let m = state?.lastModified { r.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
        return r
    }

    /// GET with conditional headers. Returns nil data for 304 Not Modified.
    func load(_ url: URL, accept: String, state: NewsSourceState?) async throws -> (Data?, HTTPURLResponse) {
        let reply: (Data, HTTPURLResponse)
        do {
            reply = try await http.get(request(url, accept: accept, state: state))
        } catch let e as URLError {
            throw NewsFetchError.network(e.code == .timedOut ? "Timed out" : e.code == .notConnectedToInternet ? "Offline" : "Network error")
        } catch {
            throw NewsFetchError.network("Network error")
        }
        let (data, resp) = reply
        if resp.statusCode == 304 { return (nil, resp) }
        guard (200..<300).contains(resp.statusCode) else { throw NewsFetchError.http(resp.statusCode) }
        return (data, resp)
    }

    public func fetch(_ source: NewsSource, state: WhatsNewState, now: Date = Date()) async throws -> NewsFetchResult {
        switch source {
        case .news: return try await fetchNews(state: state)
        case .releaseNotes: return try await fetchReleaseNotes(state: state.state(.releaseNotes), now: now)
        case .grokCLI: return try await fetchCLI(state: state.state(.grokCLI))
        case .grokApps: return try await fetchApps()
        case .grokBotMac:
            guard let i = GrokBotMacApp.installed(in: grokBotApps) else { throw NewsFetchError.notInstalled }
            return NewsFetchResult(items: [GrokBotMacApp.item(i)], note: "installed \(i.version)")
        }
    }

    func fetchNews(state: WhatsNewState) async throws -> NewsFetchResult {
        let st = state.state(.news)
        let (data, resp) = try await load(Self.newsSitemap, accept: "application/xml, text/xml", state: st)
        guard let data else { return NewsFetchResult(items: nil, etag: st.etag, lastModified: st.lastModified) }
        let entries = NewsSitemap.parse(data, limit: 8)
        guard !entries.isEmpty else { throw NewsFetchError.unreadable }
        let known = Dictionary(state.items(for: .news).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [NewsItem] = []
        var fetched = 0
        for e in entries {
            let id = "news:\(e.url.absoluteString)"
            if let k = known[id], k.title != NewsSitemap.title(fromSlug: e.slug) {
                items.append(k)        // already have the real title
                continue
            }
            var item = NewsItem(id: id, source: .news, title: NewsSitemap.title(fromSlug: e.slug), date: e.lastModified, url: e.url)
            if fetched < Self.maxArticleFetches,
               let reply = try? await load(e.url, accept: "text/html", state: nil), let page = reply.0 {
                fetched += 1
                let meta = ArticleMeta.parse(page)
                if let t = meta.title { item.title = t }
                item.detail = meta.summary
                if let p = meta.published { item.date = p }
            }
            items.append(item)
        }
        return NewsFetchResult(items: items, etag: resp.value(forHTTPHeaderField: "ETag"),
                               lastModified: resp.value(forHTTPHeaderField: "Last-Modified"),
                               note: "\(items.count) recent posts")
    }

    func fetchReleaseNotes(state st: NewsSourceState, now: Date) async throws -> NewsFetchResult {
        let (data, resp) = try await load(Self.releaseNotesMarkdown, accept: "text/markdown, text/plain", state: st)
        guard let data else { return NewsFetchResult(items: nil, etag: st.etag, lastModified: st.lastModified) }
        let items = ReleaseNotes.parse(data, now: now)
        guard !items.isEmpty else { throw NewsFetchError.unreadable }
        return NewsFetchResult(items: items, etag: resp.value(forHTTPHeaderField: "ETag"),
                               lastModified: resp.value(forHTTPHeaderField: "Last-Modified"),
                               note: "\(items.count) recent notes")
    }

    func fetchCLI(state st: NewsSourceState) async throws -> NewsFetchResult {
        guard let installed = GrokCLIVersion.installed(grokHome: grokHome) else { throw NewsFetchError.notInstalled }
        var lastError = NewsFetchError.unreadable
        for (i, url) in GrokCLIVersion.pointerURLs.enumerated() {
            do {
                // Conditional headers only for the primary URL (the mirror has its own ETag).
                let (data, resp) = try await load(url, accept: "text/plain", state: i == 0 ? st : nil)
                let published = resp.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
                guard let data else {
                    return NewsFetchResult(items: nil, etag: st.etag, lastModified: st.lastModified, note: "installed \(installed)")
                }
                guard let latest = GrokCLIVersion.parsePointer(data) else { throw NewsFetchError.unreadable }
                let item = GrokCLIVersion.item(latest: latest, installed: installed, published: published)
                return NewsFetchResult(items: item.map { [$0] } ?? [],
                                       etag: i == 0 ? resp.value(forHTTPHeaderField: "ETag") : nil,
                                       lastModified: i == 0 ? resp.value(forHTTPHeaderField: "Last-Modified") : nil,
                                       note: item == nil ? "up to date (\(installed))" : "installed \(installed), latest \(latest)")
            } catch let e as NewsFetchError {
                lastError = e
            }
        }
        throw lastError
    }

    func fetchApps() async throws -> NewsFetchResult {
        let (data, _) = try await load(AppStoreLookup.url, accept: "application/json", state: nil)
        let items = AppStoreLookup.parse(data ?? Data())
        guard !items.isEmpty else { throw NewsFetchError.unreadable }
        return NewsFetchResult(items: items, note: items.map { $0.title.components(separatedBy: " for ").first ?? $0.title }
            .joined(separator: ", "))
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}
