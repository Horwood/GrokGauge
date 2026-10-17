import Foundation

// MARK: - Service status (public status pages; no login, nothing about the user is sent)

/// The two public status pages GrokGauge shows as dots in the dropdown.
public enum ServiceSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case xai, cursor
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xai: return "xAI"
        case .cursor: return "Cursor"
        }
    }

    /// The page a click opens.
    public var pageURL: URL {
        switch self {
        case .xai: return URL(string: "https://status.x.ai")!
        case .cursor: return URL(string: "https://status.cursor.com")!
        }
    }

    /// JSON summary (xAI's own; Cursor's is the standard Statuspage v2 API).
    public var summaryURL: URL {
        switch self {
        case .xai: return URL(string: "https://data.x.ai/status/summary.json")!
        case .cursor: return URL(string: "https://status.cursor.com/api/v2/summary.json")!
        }
    }

    /// Used when the summary fails or its shape changes (xAI's RSS incident feed).
    public var fallbackURL: URL? {
        switch self {
        case .xai: return URL(string: "https://status.x.ai/feed.xml")!
        case .cursor: return nil
        }
    }

    /// Components named first when they're affected.
    public var highlighted: [String] {
        switch self {
        case .xai: return []
        case .cursor: return ["Grok Bot", "Cloud Agents"]
        }
    }
}

/// Worst first is the higher raw value. `unknown` (gray) is a failed or unreadable check.
public enum ServiceHealth: Int, Codable, Comparable, Sendable {
    case unknown = -1
    case normal = 0
    case maintenance = 1
    case degraded = 2
    case partialOutage = 3
    case outage = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The usage palette level the dot takes; nil means gray.
    public var level: UsageLevel? {
        switch self {
        case .unknown: return nil
        case .normal: return .normal
        case .maintenance, .degraded, .partialOutage: return .warning
        case .outage: return .critical
        }
    }

    public var label: String {
        switch self {
        case .unknown: return "Status unavailable"
        case .normal: return "All systems normal"
        case .maintenance: return "Maintenance"
        case .degraded: return "Degraded"
        case .partialOutage: return "Partial outage"
        case .outage: return "Outage"
        }
    }

    /// A component's status word. Anything other than available/operational counts as a problem;
    /// words we don't know are shown as "Degraded".
    public static func component(_ raw: String) -> ServiceHealth {
        let s = raw.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch s {
        case "available", "operational", "ok", "up", "normal": return .normal
        case "under_maintenance", "maintenance", "scheduled_maintenance": return .maintenance
        case "partial_outage", "partial": return .partialOutage
        case "major_outage", "outage", "unavailable", "down", "full_outage", "critical":
            return .outage
        default: return .degraded   // degraded_performance, disruption, and anything new
        }
    }

    /// The page-wide indicator (Statuspage: none, minor, major, critical, maintenance).
    public static func indicator(_ raw: String) -> ServiceHealth {
        switch raw.lowercased() {
        case "none", "operational", "available", "ok": return .normal
        case "maintenance": return .maintenance
        case "major", "critical", "outage": return .outage
        default: return .degraded
        }
    }
}

/// What one status page said at one moment.
public struct ServiceStatusReport: Equatable, Sendable {
    public var source: ServiceSource
    public var health: ServiceHealth
    /// Problem components, highlighted ones first (e.g. ["Grok Bot", "Imagine"]).
    public var affected: [String]
    /// The page's own wording, e.g. "Partial System Outage".
    public var pageDescription: String?
    /// Names of open incidents.
    public var incidents: [String]
    /// The URL this report came from (summary JSON or the RSS fallback).
    public var via: URL
    public var checkedAt: Date

    public init(source: ServiceSource, health: ServiceHealth, affected: [String] = [], pageDescription: String? = nil,
                incidents: [String] = [], via: URL, checkedAt: Date) {
        self.source = source
        self.health = health
        self.affected = affected
        self.pageDescription = pageDescription
        self.incidents = incidents
        self.via = via
        self.checkedAt = checkedAt
    }

    /// "All systems normal", "Degraded: Imagine", "Outage: Cloud Agents, Grok Bot +1".
    public var summary: String {
        guard health != .normal, health != .unknown else { return health.label }
        if affected.isEmpty {
            if let d = pageDescription, !d.isEmpty { return d }
            if let i = incidents.first { return "\(health.label): \(i)" }
            return health.label
        }
        let shown = affected.prefix(2).joined(separator: ", ")
        let more = affected.count > 2 ? " +\(affected.count - 2)" : ""
        return "\(health.label): \(shown)\(more)"
    }

    /// "xAI: All systems normal"
    public var line: String { "\(source.title): \(summary)" }
}

public enum ServiceStatusError: Error, Equatable, Sendable {
    case http(Int)
    case network(String)
    case unreadable

    public var message: String {
        switch self {
        case .http(let c): return "HTTP \(c)"
        case .network(let m): return m
        case .unreadable: return "Couldn't read the reply (format changed?)"
        }
    }
}

// MARK: - Parsing

public enum ServiceStatusParser {
    private struct Summary: Decodable {
        struct Status: Decodable { let indicator: String?; let description: String? }
        struct Component: Decodable {
            let name: String?
            let status: String?
            let group: Bool?
            let only_show_if_degraded: Bool?
        }
        struct Incident: Decodable { let name: String?; let status: String? }
        let status: Status?
        let components: [Component]?
        let incidents: [Incident]?
    }

    /// Parses a status summary: Cursor's Statuspage v2 `summary.json` or xAI's `summary.json` (same idea:
    /// `status.indicator`, `components[].name/status`, `incidents[]`). Throws `unreadable` when the shape changed.
    public static func parseSummary(_ data: Data, source: ServiceSource, via: URL, now: Date = Date()) throws -> ServiceStatusReport {
        guard let s = try? JSONDecoder().decode(Summary.self, from: data),
              let comps = s.components, !comps.isEmpty,
              comps.contains(where: { $0.name != nil && $0.status != nil }) else {
            throw ServiceStatusError.unreadable
        }
        var health = s.status?.indicator.map(ServiceHealth.indicator) ?? .normal
        var affected: [(String, ServiceHealth)] = []
        for c in comps where c.group != true {
            guard let name = c.name, let status = c.status else { continue }
            let h = ServiceHealth.component(status)
            if h != .normal { affected.append((name, h)) }
            health = max(health, h)
        }
        let open = (s.incidents ?? []).filter { ($0.status ?? "").lowercased() != "resolved" }.compactMap(\.name)
        if s.status?.indicator == nil, comps.allSatisfy({ ServiceHealth.component($0.status ?? "") == .normal }), !open.isEmpty {
            health = max(health, .degraded)
        }
        return ServiceStatusReport(source: source, health: health,
                                   affected: order(affected, highlighted: source.highlighted),
                                   pageDescription: s.status?.description, incidents: open, via: via, checkedAt: now)
    }

    /// Highlighted components first, then worst first, then by name.
    static func order(_ items: [(String, ServiceHealth)], highlighted: [String]) -> [String] {
        func rank(_ n: String) -> Int { highlighted.firstIndex { $0.caseInsensitiveCompare(n) == .orderedSame } ?? highlighted.count }
        return items.sorted { a, b in
            if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
        }.map(\.0)
    }

    /// Parses xAI's RSS incident feed (`status.x.ai/feed.xml`). Incidents without a "resolved" (or "completed")
    /// category are open; their severity category ("outage", "disruption", "maintenance") sets the health,
    /// and the "[Component]" prefix of the title names what's affected. No open incidents means normal.
    public static func parseFeed(_ data: Data, source: ServiceSource = .xai, via: URL, now: Date = Date()) throws -> ServiceStatusReport {
        let parser = RSSIncidents(data: data)
        guard parser.parse() else { throw ServiceStatusError.unreadable }
        var health = ServiceHealth.normal
        var affected: [(String, ServiceHealth)] = []
        var incidents: [String] = []
        for item in parser.items {
            let cats = Set(item.categories.map { $0.lowercased() })
            if !cats.isDisjoint(with: ["resolved", "completed", "postmortem", "closed"]) { continue }
            let h: ServiceHealth
            if cats.contains("outage") || cats.contains("major") || cats.contains("critical") { h = .outage }
            else if cats.contains("maintenance") || cats.contains("scheduled") { h = .maintenance }
            else { h = .degraded }
            health = max(health, h)
            var title = item.title
            if title.hasPrefix("["), let end = title.firstIndex(of: "]") {
                let comp = String(title[title.index(after: title.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
                if !comp.isEmpty, !affected.contains(where: { $0.0 == comp }) { affected.append((comp, h)) }
                title = String(title[title.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            if !title.isEmpty { incidents.append(title) }
        }
        return ServiceStatusReport(source: source, health: health, affected: order(affected, highlighted: source.highlighted),
                                   pageDescription: nil, incidents: incidents, via: via, checkedAt: now)
    }
}

/// Minimal RSS reader: each <item>'s title and categories. Fails if there's no <channel> (not a feed).
final class RSSIncidents: NSObject, XMLParserDelegate {
    struct Item { var title = ""; var categories: [String] = [] }
    private let data: Data
    private(set) var items: [Item] = []
    private var current: Item?
    private var text = ""
    private var sawChannel = false

    init(data: Data) { self.data = data }

    func parse() -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldResolveExternalEntities = false
        return p.parse() && sawChannel
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "channel" { sawChannel = true }
        if name == "item" { current = Item() }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current?.title = t
        case "category": if !t.isEmpty { current?.categories.append(t) }
        case "item": if let c = current { items.append(c) }; current = nil
        default: break
        }
        text = ""
    }
}

// MARK: - Fetching

/// The result of checking one source: the report plus, when the fallback was used, why the summary failed.
public struct ServiceStatusResult: Equatable, Sendable {
    public var report: ServiceStatusReport
    public var primaryError: String?
}

public struct ServiceStatusFetcher: Sendable {
    public let http: NewsHTTP
    public let userAgent: String

    public init(appVersion: String, http: NewsHTTP = URLSessionNewsHTTP()) {
        self.http = http
        userAgent = "GrokGauge/\(appVersion) (macOS menu bar)"
    }

    /// GET with the honest User-Agent (x.ai answers 403 without one). No cookies, no credentials.
    func get(_ url: URL, accept: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await http.get(req) } catch let e as ServiceStatusError { throw e } catch {
            throw ServiceStatusError.network((error as? URLError).map { Self.describe($0) } ?? "Network error")
        }
        guard (200..<300).contains(resp.statusCode) else { throw ServiceStatusError.http(resp.statusCode) }
        return data
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost: return "Offline"
        case .timedOut: return "Timed out"
        case .cannotFindHost, .dnsLookupFailed: return "Host not found"
        default: return "Network error"
        }
    }

    /// Summary JSON first; for xAI, the RSS feed when the summary fails or its shape changed.
    public func fetch(_ source: ServiceSource, now: Date = Date()) async throws -> ServiceStatusResult {
        do {
            let data = try await get(source.summaryURL, accept: "application/json")
            return ServiceStatusResult(report: try ServiceStatusParser.parseSummary(data, source: source, via: source.summaryURL, now: now))
        } catch let primary as ServiceStatusError {
            guard let fallback = source.fallbackURL else { throw primary }
            let data = try await get(fallback, accept: "application/rss+xml, application/xml")
            let report = try ServiceStatusParser.parseFeed(data, source: source, via: fallback, now: now)
            return ServiceStatusResult(report: report, primaryError: primary.message)
        }
    }
}

// MARK: - Settings

/// Which status dots to show, and whether to notify on a new outage. Part of `GaugeSettings` (synced).
public struct ServiceStatusSettings: Codable, Equatable, Hashable, Sendable {
    public var xai: Bool
    public var cursor: Bool
    /// Notify when a source goes from normal to an outage. Off by default.
    public var notify: Bool

    public static let standard = ServiceStatusSettings()

    public init(xai: Bool = true, cursor: Bool = true, notify: Bool = false) {
        self.xai = xai
        self.cursor = cursor
        self.notify = notify
    }

    public func isOn(_ s: ServiceSource) -> Bool { s == .xai ? xai : cursor }
    public var enabled: [ServiceSource] { ServiceSource.allCases.filter(isOn) }

    enum CodingKeys: String, CodingKey { case xai, cursor, notify }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServiceStatusSettings()
        func v(_ k: CodingKeys, _ f: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? f }
        self.init(xai: v(.xai, d.xai), cursor: v(.cursor, d.cursor), notify: v(.notify, d.notify))
    }
}

/// Polling rules: every 5 minutes; after failures 5, 10, 20 … minutes, up to 30.
public enum ServiceStatusSchedule {
    public static let interval: TimeInterval = 5 * 60
    public static let maxBackoff: TimeInterval = 30 * 60
    /// Opening the dropdown re-checks at most this often.
    public static let openThrottle: TimeInterval = 30

    public static func nextCheck(lastAttempt: Date?, failures: Int) -> Date {
        guard let lastAttempt else { return .distantPast }
        let wait = failures <= 0 ? interval : min(maxBackoff, interval * pow(2, Double(failures - 1)))
        return lastAttempt.addingTimeInterval(wait)
    }

    /// Notify only when a source goes from normal to an outage (not for unknown/failed checks).
    public static func shouldNotify(previous: ServiceHealth?, current: ServiceHealth) -> Bool {
        previous == .normal && current == .outage
    }
}
