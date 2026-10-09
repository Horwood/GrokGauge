import Foundation

// MARK: - "What's new from xAI": model, parsers and the read/unread engine.
// Everything here is public, no-login data (x.ai, docs.x.ai, Apple's lookup API) or a read-only
// look at local files (the Grok CLI's version, Grok Bot's Info.plist). Nothing here touches tokens.

public enum NewsSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case news, releaseNotes, grokCLI, grokApps, grokBotMac

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .news: return "xAI news"
        case .releaseNotes: return "API release notes"
        case .grokCLI: return "Grok CLI updates"
        case .grokApps: return "Grok apps (App Store)"
        case .grokBotMac: return "Grok Bot for Mac"
        }
    }

    /// Short label for item subtitles.
    public var shortName: String {
        switch self {
        case .news: return "xAI news"
        case .releaseNotes: return "Release notes"
        case .grokCLI: return "Grok CLI"
        case .grokApps: return "App Store"
        case .grokBotMac: return "Grok Bot"
        }
    }

    public var detail: String {
        switch self {
        case .news: return "New posts on x.ai/news (from x.ai's public sitemap)"
        case .releaseNotes: return "New models and API features (docs.x.ai release notes)"
        case .grokCLI: return "When a newer Grok CLI is out than the one installed (x.ai/cli/stable)"
        case .grokApps: return "New Grok and Grok Bot versions for iPhone and iPad (Apple's public lookup)"
        case .grokBotMac: return "When the Grok Bot app on this Mac updates (read-only, no network)"
        }
    }

    public var symbol: String {
        switch self {
        case .news: return "newspaper"
        case .releaseNotes: return "doc.text"
        case .grokCLI: return "terminal"
        case .grokApps: return "app.badge"
        case .grokBotMac: return "sparkles"
        }
    }

    /// Uses the network (vs. a local file read).
    public var isRemote: Bool { self != .grokBotMac }
}

public struct NewsItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable id used for read/unread: "news:<url>", "rn:<yyyy-mm>:<title>", "cli:<version>",
    /// "app:<trackId>:<version>", "botmac:<version>".
    public var id: String
    public var source: NewsSource
    public var title: String
    public var detail: String?
    public var date: Date?
    /// The date is only known to the month (release notes are grouped by month).
    public var monthOnly: Bool
    public var url: URL?
    /// A command the user can copy (e.g. `grok update`). GrokGauge never runs it.
    public var command: String?
    /// Offer "Open Grok Bot" (it updates itself).
    public var opensGrokBot: Bool

    public init(id: String, source: NewsSource, title: String, detail: String? = nil, date: Date? = nil,
                monthOnly: Bool = false, url: URL? = nil, command: String? = nil, opensGrokBot: Bool = false) {
        self.id = id
        self.source = source
        self.title = title
        self.detail = detail
        self.date = date
        self.monthOnly = monthOnly
        self.url = url
        self.command = command
        self.opensGrokBot = opensGrokBot
    }
}

/// Only these https hosts are ever linked from an item.
public enum NewsLinks {
    public static let allowedHosts: Set<String> = ["x.ai", "docs.x.ai", "apps.apple.com", "x.com", "cursor.com"]
    public static let xaiProfile = URL(string: "https://x.com/xai")!
    public static let grokProfile = URL(string: "https://x.com/grok")!
    public static let releaseNotesPage = URL(string: "https://docs.x.ai/developers/release-notes")!
    public static let grokBotDownload = URL(string: "https://cursor.com/download/bot")!
    public static let cliUpdateCommand = "grok update"

    public static func safe(_ s: String?) -> URL? {
        guard let s, var c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", let host = c.host?.lowercased(), allowedHosts.contains(host) else { return nil }
        c.user = nil
        c.password = nil
        return c.url
    }
}

// MARK: - Text helpers

enum NewsText {
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (k, v) in named where k != "&amp;" { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities (&#8217; &#x27;)
        while let r = out.range(of: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#, options: .regularExpression) {
            let body = out[r].dropFirst(2).dropLast()
            let value = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            out.replaceSubrange(r, with: value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? "")
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Markdown to one plain line: links keep their text, code ticks and emphasis go.
    static func plain(_ markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for t in ["**", "__", "`"] { s = s.replacingOccurrences(of: t, with: "") }
        s = s.replacingOccurrences(of: #"\\([_*\[\]()#`\\-])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*[*-]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…" : s
    }
}

// MARK: - x.ai news (sitemap + article metadata)

public enum NewsSitemap {
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var lastModified: Date?
        public var slug: String
    }

    /// News article URLs (`https://x.ai/news/<slug>`), newest first.
    public static func parse(_ data: Data, limit: Int = 10) -> [Entry] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        let blocks = xml.components(separatedBy: "<url>").dropFirst()
        for block in blocks {
            guard let loc = capture(#"<loc>\s*([^<\s]+)\s*</loc>"#, in: block),
                  let url = NewsLinks.safe(NewsText.decodeEntities(loc)), url.host == "x.ai",
                  let slug = slug(url.path) else { continue }
            let mod = capture(#"<lastmod>\s*([^<\s]+)\s*</lastmod>"#, in: block).flatMap(ISODate.parse)
            out.append(Entry(url: url, lastModified: mod, slug: slug))
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0.slug).inserted }
        out.sort { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        return Array(out.prefix(limit))
    }

    static func slug(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0] == "news",
              parts[1].range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else { return nil }
        return String(parts[1])
    }

    /// "grok-4-7" -> "Grok 4 7" (used until the article's own title is known).
    public static func title(fromSlug slug: String) -> String {
        let words = slug.split(separator: "-").map(String.init)
        guard let first = words.first else { return slug }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}

public struct ArticleMeta: Equatable, Sendable {
    public var title: String?
    public var summary: String?
    public var published: Date?

    /// Reads `<title>` (minus the " | Site" suffix), the description meta tag and `datePublished`.
    public static func parse(_ data: Data) -> ArticleMeta {
        guard let html = String(data: data.prefix(1_000_000), encoding: .utf8) else { return ArticleMeta() }
        var title = NewsSitemap.capture(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)"#, in: html)
            ?? NewsSitemap.capture(#"<title[^>]*>([^<]+)</title>"#, in: html)
        title = title.map { t in
            let d = NewsText.decodeEntities(t).trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = d.range(of: " | ", options: .backwards) { return String(d[..<r.lowerBound]) }
            return d
        }
        let summary = (NewsSitemap.capture(#"<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)"#, in: html)
            ?? NewsSitemap.capture(#"<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)"#, in: html))
            .map { NewsText.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let published = NewsSitemap.capture(#""datePublished"\s*:\s*"([^"]+)""#, in: html).flatMap(ISODate.parse)
        return ArticleMeta(title: title.flatMap { $0.isEmpty ? nil : NewsText.clip($0, 140) },
                           summary: summary.flatMap { $0.isEmpty ? nil : NewsText.clip($0, 220) },
                           published: published)
    }
}

// MARK: - docs.x.ai release notes (Markdown)

public enum ReleaseNotes {
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                         "september", "october", "november", "december"]

    /// Items in page order (newest first). The page has `## Month` and `### Item` headings but no year,
    /// so the year is inferred from `now`, stepping back a year whenever the months wrap.
    public static func parse(_ data: Data, now: Date = Date(), calendar: Calendar = .utc, limit: Int = 12) -> [NewsItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var items: [NewsItem] = []
        let nowParts = calendar.dateComponents([.year, .month], from: now)
        var year = nowParts.year ?? 2026
        var lastMonth: Int?
        var month: Int?
        var current: (title: String, body: [String])?

        func flush() {
            guard let c = current, let m = month else { current = nil; return }
            let title = NewsText.clip(NewsText.plain(c.title), 120)
            guard !title.isEmpty else { current = nil; return }
            let para = c.body.split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .first.map { $0.joined(separator: " ") } ?? ""
            let detail = NewsText.plain(para)
            let date = calendar.date(from: DateComponents(year: year, month: m, day: 1, hour: 12))
            let key = title.lowercased().replacingOccurrences(of: #"[^a-z0-9.]+"#, with: "-", options: .regularExpression)
            items.append(NewsItem(id: String(format: "rn:%04d-%02d:", year, m) + key, source: .releaseNotes, title: title,
                                  detail: detail.isEmpty ? nil : NewsText.clip(detail, 220), date: date, monthOnly: true,
                                  url: NewsLinks.releaseNotesPage))
            current = nil
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") && !line.hasPrefix("### ") {
                flush()
                let name = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                guard let idx = months.firstIndex(where: { name.hasPrefix($0) }) else { month = nil; continue }
                let m = idx + 1
                if let explicit = Int(name.split(separator: " ").last ?? "") , explicit > 2000 {
                    year = explicit
                } else if let last = lastMonth {
                    if m > last { year -= 1 }
                } else if let nowMonth = nowParts.month, m > nowMonth {
                    year -= 1
                }
                lastMonth = m
                month = m
            } else if line.hasPrefix("### ") {
                flush()
                current = (String(line.dropFirst(4)), [])
            } else if line.hasPrefix("#") {
                flush()
            } else if current != nil {
                current?.body.append(line)
            }
            if items.count >= limit { break }
        }
        if items.count < limit { flush() }
        return items
    }
}

public extension Calendar {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}

// MARK: - Grok CLI version

public enum GrokCLIVersion {
    public static let pointerURLs = [URL(string: "https://x.ai/cli/stable")!,
                                     URL(string: "https://storage.googleapis.com/grok-build-public-artifacts/cli/stable")!]

    /// The channel pointer is a bare version ("1.0.50"). Anything else (an HTML error page…) is rejected.
    public static func parsePointer(_ data: Data) -> String? {
        guard data.count < 64, let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        return s
    }

    /// The installed CLI's version without running it: the `~/.grok/bin/grok` symlink target
    /// (`../downloads/grok-1.0.46-macos-aarch64`), else `version` in `~/.grok/version.json`.
    public static func installed(grokHome: URL = defaultHome) -> String? {
        let link = grokHome.appendingPathComponent("bin/grok")
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
           let v = version(fromBinaryName: (target as NSString).lastPathComponent) {
            return v
        }
        let json = grokHome.appendingPathComponent("version.json")
        guard let data = try? Data(contentsOf: json),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String, parsePointer(Data(v.utf8)) != nil else { return nil }
        return v
    }

    /// "grok-1.0.46-macos-aarch64" -> "1.0.46"; "grok-1.1.0-beta.2-macos-x86_64" -> "1.1.0-beta.2".
    static func version(fromBinaryName name: String) -> String? {
        guard name.hasPrefix("grok-") else { return nil }
        var v = String(name.dropFirst(5))
        if let r = v.range(of: #"-(macos|darwin|linux|windows)(-.*)?$"#, options: .regularExpression) { v.removeSubrange(r) }
        return parsePointer(Data(v.utf8))
    }

    public static var defaultHome: URL {
        if let h = ProcessInfo.processInfo.environment["GROK_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    /// An item only when the published version is newer than the installed one.
    public static func item(latest: String, installed: String?, published: Date?) -> NewsItem? {
        guard let installed, UpdateCheck.isNewer(latest, than: installed) else { return nil }
        return NewsItem(id: "cli:\(latest)", source: .grokCLI, title: "Grok CLI \(latest) is available",
                        detail: "You have \(installed). Update in Terminal with `grok update`.",
                        date: published, command: NewsLinks.cliUpdateCommand)
    }
}

// MARK: - App Store (Apple's public lookup API)

public enum AppStoreLookup {
    /// Grok (iPhone/iPad) and Grok Bot (iPhone/iPad).
    public static let trackIDs = ["6670324846", "6794501026"]
    public static var url: URL {
        URL(string: "https://itunes.apple.com/lookup?id=\(trackIDs.joined(separator: ","))&country=us&entity=software")!
    }

    public static func parse(_ data: Data) -> [NewsItem] {
        struct Payload: Decodable { let results: [App]? }
        struct App: Decodable {
            let trackId: Int?
            let trackName: String?
            let version: String?
            let currentVersionReleaseDate: String?
            let releaseNotes: String?
            let trackViewUrl: String?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return (p.results ?? []).compactMap { a in
            guard let id = a.trackId, trackIDs.contains(String(id)), let name = a.trackName, let v = a.version,
                  var url = NewsLinks.safe(a.trackViewUrl) else { return nil }
            if var c = URLComponents(url: url, resolvingAgainstBaseURL: false) { c.query = nil; url = c.url ?? url }
            let notes = (a.releaseNotes ?? "").split(whereSeparator: \.isNewline)
                .map { NewsText.plain(String($0)) }.filter { !$0.isEmpty }.prefix(3).joined(separator: " ")
            return NewsItem(id: "app:\(id):\(v)", source: .grokApps,
                            title: "\(NewsText.clip(name, 40)) \(v) for iPhone and iPad",
                            detail: notes.isEmpty ? nil : NewsText.clip(notes, 220),
                            date: a.currentVersionReleaseDate.flatMap(ISODate.parse), url: url)
        }
    }
}

// MARK: - Grok Bot for Mac (read-only Info.plist)

public enum GrokBotMacApp {
    public static var candidates: [URL] {
        [URL(fileURLWithPath: "/Applications/Grok Bot.app"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Grok Bot.app")]
    }

    public struct Installed: Equatable, Sendable {
        public var version: String
        public var modified: Date?
    }

    public static func installed(in apps: [URL] = candidates) -> Installed? {
        for app in apps {
            let plist = app.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let v = obj["CFBundleShortVersionString"] as? String, !v.isEmpty else { continue }
            let mod = (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.modificationDate] as? Date
            return Installed(version: NewsText.clip(v, 24), modified: mod)
        }
        return nil
    }

    public static func item(_ i: Installed) -> NewsItem {
        NewsItem(id: "botmac:\(i.version)", source: .grokBotMac, title: "Grok Bot for Mac \(i.version)",
                 detail: "Grok Bot updates itself. Open it to see what's new.", date: i.modified,
                 url: NewsLinks.grokBotDownload, opensGrokBot: true)
    }
}

// MARK: - Local state (never synced)

public struct NewsSourceState: Codable, Equatable, Sendable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    public var failures = 0
    public var etag: String?
    public var lastModified: String?
    public var note: String?
    public init() {}
}

/// Items, read/unread and per-source fetch state, kept in
/// `~/Library/Application Support/GrokGauge/whatsnew.json`. Never synced.
public struct WhatsNewState: Codable, Equatable, Sendable {
    public static let maxSeen = 600

    public var schema = 1
    public var items: [NewsItem] = []
    public var seen: Set<String> = []
    /// Sources that completed their first fetch (whose items at that time were marked read).
    public var initialized: Set<NewsSource> = []
    public var sources: [String: NewsSourceState] = [:]

    public init() {}

    public func state(_ s: NewsSource) -> NewsSourceState { sources[s.rawValue] ?? NewsSourceState() }
    public mutating func update(_ s: NewsSource, _ f: (inout NewsSourceState) -> Void) {
        var st = state(s)
        f(&st)
        sources[s.rawValue] = st
    }

    public func items(for s: NewsSource) -> [NewsItem] { items.filter { $0.source == s } }

    /// Replaces one source's items. The first time a source succeeds, everything it returns is marked
    /// read (no backlog on first launch). Returns the items that are new and unread.
    @discardableResult
    public mutating func apply(_ source: NewsSource, items fresh: [NewsItem], now: Date = Date()) -> [NewsItem] {
        var unique: [NewsItem] = []
        var ids = Set<String>()
        for i in fresh where i.source == source && ids.insert(i.id).inserted { unique.append(i) }
        let before = Set(items(for: source).map(\.id))
        items = items.filter { $0.source != source } + unique
        update(source) { st in
            st.lastAttempt = now
            st.lastSuccess = now
            st.failures = 0
            st.lastError = nil
        }
        if !initialized.contains(source) {
            initialized.insert(source)
            seen.formUnion(unique.map(\.id))
            pruneSeen()
            return []
        }
        pruneSeen()
        return unique.filter { !seen.contains($0.id) && !before.contains($0.id) }
    }

    public mutating func recordFailure(_ source: NewsSource, _ message: String, now: Date = Date()) {
        update(source) { st in
            st.lastAttempt = now
            st.failures += 1
            st.lastError = message
            st.lastErrorAt = now
        }
    }

    public func isUnread(_ item: NewsItem) -> Bool { !seen.contains(item.id) }

    public func unread(enabled: Set<NewsSource>) -> [NewsItem] {
        items.filter { enabled.contains($0.source) && !seen.contains($0.id) }
    }

    public mutating func markRead(_ id: String) {
        seen.insert(id)
        pruneSeen()
    }

    public mutating func markAllRead() {
        seen.formUnion(items.map(\.id))
        pruneSeen()
    }

    /// Newest first (undated items last), from enabled sources only.
    public func latest(enabled: Set<NewsSource>, limit: Int = 4) -> [NewsItem] {
        let list = items.filter { enabled.contains($0.source) }.enumerated().sorted { a, b in
            let da = a.element.date ?? .distantPast, db = b.element.date ?? .distantPast
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
        return Array(list.prefix(limit))
    }

    /// Whether a source should be checked now: on schedule after a success, or after a growing backoff
    /// (5 min, 10, 20 … up to the interval) after failures.
    public func isDue(_ source: NewsSource, interval: TimeInterval, now: Date = Date()) -> Bool {
        let st = state(source)
        guard let attempt = st.lastAttempt else { return true }
        if st.failures > 0 {
            let wait = min(interval, Backoff.delay(attempt: st.failures, base: 300, cap: interval))
            return now.timeIntervalSince(attempt) >= wait
        }
        return now.timeIntervalSince(st.lastSuccess ?? attempt) >= interval
    }

    /// Keeps read marks only for items we still hold (plus a cap), so the file never grows unbounded.
    mutating func pruneSeen() {
        let live = Set(items.map(\.id))
        if seen.count > Self.maxSeen { seen = seen.intersection(live) }
    }

    // MARK: Disk

    public static var defaultURL: URL {
        UsageHistory.defaultURL.deletingLastPathComponent().appendingPathComponent("whatsnew.json")
    }

    public static func load(from url: URL = defaultURL) -> WhatsNewState {
        guard let data = try? Data(contentsOf: url) else { return WhatsNewState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(WhatsNewState.self, from: data)) ?? WhatsNewState()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: url, options: [.atomic])
    }
}
