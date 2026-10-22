import Foundation
import Testing
@testable import GrokGaugeCore

private final class StatusHTTP: NewsHTTP, @unchecked Sendable {
    var replies: [String: (Int, String)] = [:]
    var failing: Set<String> = []
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let key = request.url!.absoluteString
        if failing.contains(key) { throw URLError(.timedOut) }
        guard let (code, body) = replies[key] else { throw URLError(.cannotFindHost) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct ServiceStatusTests {
    let now = Date(timeIntervalSince1970: 1_792_300_000)
    let xaiURL = ServiceSource.xai.summaryURL
    let cursorURL = ServiceSource.cursor.summaryURL
    let feedURL = ServiceSource.xai.fallbackURL!

    static let xaiOK = #"{"status":{"indicator":"none","description":"All systems operational"},"components":[{"id":"grok-com","name":"grok.com","status":"available"},{"id":"imagine","name":"Imagine","status":"available"},{"id":"voice","name":"Voice","status":"available"}],"incidents":[]}"#
    static let xaiImagine = #"{"status":{"indicator":"minor","description":"Some systems degraded"},"components":[{"id":"grok-com","name":"grok.com","status":"available"},{"id":"imagine","name":"Imagine","status":"degraded"}],"incidents":[{"name":"Imagine slow","status":"investigating"}]}"#
    static let cursorOK = #"{"page":{"id":"x","name":"Cursor"},"components":[{"name":"IDE","status":"operational","group":false},{"name":"Cloud Agents","status":"operational","group":false},{"name":"Grok Bot","status":"operational","group":false}],"incidents":[],"scheduled_maintenances":[],"status":{"indicator":"none","description":"All Systems Operational"}}"#
    static let cursorOutage = #"{"components":[{"name":"IDE","status":"degraded_performance"},{"name":"Cloud Agents","status":"major_outage"},{"name":"Automations","status":"partial_outage"},{"name":"Grok Bot","status":"degraded_performance"},{"name":"Group","status":"major_outage","group":true}],"incidents":[{"name":"Cloud Agents failing to start","status":"identified"}],"status":{"indicator":"major","description":"Partial System Outage"}}"#
    static let feedResolved = """
    <?xml version="1.0" encoding="UTF-8" ?><rss version="2.0"><channel><title>SpaceXAI System Status</title>
    <item><title>[grok.com] grok.com</title><category>outage</category><category>resolved</category></item>
    </channel></rss>
    """
    static let feedOpen = """
    <?xml version="1.0" encoding="UTF-8" ?><rss version="2.0"><channel><title>SpaceXAI System Status</title>
    <item><title>[Voice] Enterprise Voice Degraded</title><description><![CDATA[<h3>Status: INVESTIGATING</h3>]]></description><category>disruption</category><category>investigating</category></item>
    <item><title>[grok.com] grok.com down</title><category>outage</category><category>identified</category></item>
    <item><title>[API] Old one</title><category>outage</category><category>resolved</category></item>
    </channel></rss>
    """

    // MARK: Mapping

    @Test func componentStatusMapping() {
        #expect(ServiceHealth.component("available") == .normal)
        #expect(ServiceHealth.component("operational") == .normal)
        #expect(ServiceHealth.component("degraded_performance") == .degraded)
        #expect(ServiceHealth.component("partial_outage") == .partialOutage)
        #expect(ServiceHealth.component("major_outage") == .outage)
        #expect(ServiceHealth.component("unavailable") == .outage)
        #expect(ServiceHealth.component("under_maintenance") == .maintenance)
        // Anything else is a problem, shown as Degraded.
        #expect(ServiceHealth.component("brownout") == .degraded)
        #expect(ServiceHealth.component("") == .degraded)
    }

    @Test func indicatorMapping() {
        #expect(ServiceHealth.indicator("none") == .normal)
        #expect(ServiceHealth.indicator("minor") == .degraded)
        #expect(ServiceHealth.indicator("major") == .outage)
        #expect(ServiceHealth.indicator("critical") == .outage)
        #expect(ServiceHealth.indicator("maintenance") == .maintenance)
        #expect(ServiceHealth.indicator("weird") == .degraded)
    }

    @Test func palette() {
        #expect(ServiceHealth.normal.level == .normal)
        #expect(ServiceHealth.degraded.level == .warning)
        #expect(ServiceHealth.partialOutage.level == .warning)
        #expect(ServiceHealth.outage.level == .critical)
        #expect(ServiceHealth.unknown.level == nil)
        #expect(ServiceHealth.outage > ServiceHealth.degraded && ServiceHealth.normal > ServiceHealth.unknown)
    }

    // MARK: Parsing

    @Test func xaiSummaryNormal() throws {
        let r = try ServiceStatusParser.parseSummary(Data(Self.xaiOK.utf8), source: .xai, via: xaiURL, now: now)
        #expect(r.health == .normal)
        #expect(r.affected.isEmpty)
        #expect(r.line == "xAI: All systems normal")
        #expect(r.via == xaiURL && r.checkedAt == now)
    }

    @Test func xaiSummaryDegraded() throws {
        let r = try ServiceStatusParser.parseSummary(Data(Self.xaiImagine.utf8), source: .xai, via: xaiURL, now: now)
        #expect(r.health == .degraded)
        #expect(r.line == "xAI: Degraded: Imagine")
        #expect(r.incidents == ["Imagine slow"])
    }

    @Test func cursorSummaryNormal() throws {
        let r = try ServiceStatusParser.parseSummary(Data(Self.cursorOK.utf8), source: .cursor, via: cursorURL, now: now)
        #expect(r.line == "Cursor: All systems normal")
    }

    @Test func cursorOutageHighlightsGrokBotAndCloudAgents() throws {
        let r = try ServiceStatusParser.parseSummary(Data(Self.cursorOutage.utf8), source: .cursor, via: cursorURL, now: now)
        #expect(r.health == .outage)
        // Grok Bot and Cloud Agents first (in that order), then the rest worst first; group rows skipped.
        #expect(r.affected == ["Grok Bot", "Cloud Agents", "Automations", "IDE"])
        #expect(r.summary == "Outage: Grok Bot, Cloud Agents +2")
        #expect(r.pageDescription == "Partial System Outage")
    }

    @Test func indicatorOnlyUsesPageDescription() throws {
        let json = #"{"status":{"indicator":"minor","description":"Minor Service Outage"},"components":[{"name":"IDE","status":"operational"}],"incidents":[]}"#
        let r = try ServiceStatusParser.parseSummary(Data(json.utf8), source: .cursor, via: cursorURL, now: now)
        #expect(r.health == .degraded)
        #expect(r.summary == "Minor Service Outage")
    }

    @Test func unknownComponentStatusIsAProblem() throws {
        let json = #"{"status":{"indicator":"none"},"components":[{"name":"Voice","status":"flaky"}]}"#
        let r = try ServiceStatusParser.parseSummary(Data(json.utf8), source: .xai, via: xaiURL, now: now)
        #expect(r.health == .degraded)
        #expect(r.line == "xAI: Degraded: Voice")
    }

    @Test func changedShapeIsUnreadable() {
        for body in [#"{"page":{}}"#, #"{"components":[]}"#, #"{"components":[{"id":"x"}]}"#, "<html>", "[]"] {
            #expect(throws: ServiceStatusError.unreadable) {
                try ServiceStatusParser.parseSummary(Data(body.utf8), source: .xai, via: xaiURL, now: now)
            }
        }
    }

    @Test func feedWithOnlyResolvedIncidentsIsNormal() throws {
        let r = try ServiceStatusParser.parseFeed(Data(Self.feedResolved.utf8), via: feedURL, now: now)
        #expect(r.health == .normal)
        #expect(r.line == "xAI: All systems normal")
        #expect(r.via == feedURL)
    }

    @Test func feedOpenIncidents() throws {
        let r = try ServiceStatusParser.parseFeed(Data(Self.feedOpen.utf8), via: feedURL, now: now)
        #expect(r.health == .outage)
        #expect(r.affected == ["grok.com", "Voice"])
        #expect(r.summary == "Outage: grok.com, Voice")
        #expect(r.incidents == ["Enterprise Voice Degraded", "grok.com down"])
    }

    @Test func notAFeedIsUnreadable() {
        #expect(throws: ServiceStatusError.unreadable) {
            try ServiceStatusParser.parseFeed(Data("<html><body>hi</body></html>".utf8), via: feedURL, now: now)
        }
        #expect(throws: ServiceStatusError.unreadable) {
            try ServiceStatusParser.parseFeed(Data("not xml".utf8), via: feedURL, now: now)
        }
    }

    // MARK: Fetching

    @Test func fetchesSummaryWithHonestUserAgent() async throws {
        let http = StatusHTTP()
        http.replies[xaiURL.absoluteString] = (200, Self.xaiOK)
        let r = try await ServiceStatusFetcher(appVersion: "0.9.2", http: http).fetch(.xai, now: now)
        #expect(r.report.health == .normal)
        #expect(r.primaryError == nil)
        let req = try #require(http.requests.first)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "GrokGauge/0.9.2 (macOS menu bar)")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil && req.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func xaiFallsBackToFeedWhenSummaryFailsOrChanges() async throws {
        let http = StatusHTTP()
        http.replies[xaiURL.absoluteString] = (503, "")
        http.replies[feedURL.absoluteString] = (200, Self.feedOpen)
        let f = ServiceStatusFetcher(appVersion: "0.9.2", http: http)
        let r = try await f.fetch(.xai, now: now)
        #expect(r.report.via == feedURL)
        #expect(r.primaryError == "HTTP 503")
        #expect(r.report.health == .outage)

        http.replies[xaiURL.absoluteString] = (200, #"{"new":"shape"}"#)
        let r2 = try await f.fetch(.xai, now: now)
        #expect(r2.report.via == feedURL)
        #expect(r2.primaryError?.contains("format") == true)
    }

    @Test func failedFetchesThrow() async {
        let http = StatusHTTP()
        http.failing = [xaiURL.absoluteString, feedURL.absoluteString, cursorURL.absoluteString]
        let f = ServiceStatusFetcher(appVersion: "0.9.2", http: http)
        await #expect(throws: ServiceStatusError.network("Timed out")) { try await f.fetch(.xai, now: now) }
        // Cursor has no fallback.
        http.failing = []
        http.replies[cursorURL.absoluteString] = (404, "")
        await #expect(throws: ServiceStatusError.http(404)) { try await f.fetch(.cursor, now: now) }
        #expect(!http.requests.contains { $0.url == feedURL && $0.url?.host == "status.cursor.com" })
    }

    // MARK: Schedule

    @Test func pollingAndBackoff() {
        let t = now
        #expect(ServiceStatusSchedule.nextCheck(lastAttempt: nil, failures: 0) == .distantPast)
        #expect(ServiceStatusSchedule.nextCheck(lastAttempt: t, failures: 0) == t.addingTimeInterval(300))
        #expect(ServiceStatusSchedule.nextCheck(lastAttempt: t, failures: 1) == t.addingTimeInterval(300))
        #expect(ServiceStatusSchedule.nextCheck(lastAttempt: t, failures: 2) == t.addingTimeInterval(600))
        #expect(ServiceStatusSchedule.nextCheck(lastAttempt: t, failures: 3) == t.addingTimeInterval(1200))
        #expect(ServiceStatusSchedule.nextCheck(lastAttempt: t, failures: 9) == t.addingTimeInterval(1800))
    }

    @Test func notifiesOnlyNormalToOutage() {
        #expect(ServiceStatusSchedule.shouldNotify(previous: .normal, current: .outage))
        #expect(!ServiceStatusSchedule.shouldNotify(previous: .normal, current: .degraded))
        #expect(!ServiceStatusSchedule.shouldNotify(previous: .outage, current: .outage))
        #expect(!ServiceStatusSchedule.shouldNotify(previous: nil, current: .outage))
        #expect(!ServiceStatusSchedule.shouldNotify(previous: .unknown, current: .outage))
    }

    // MARK: Settings

    @Test func oldSettingsDecodeToDefaults() throws {
        let json = #"{"app":"GrokGauge","schema":1,"settings":{"sections":[{"id":"grokRing","visible":true},{"id":"grokBotRing","visible":true},{"id":"historyPace","visible":false}],"modifiedAt":"2026-10-08T12:00:00.000Z"}}"#
        let s = try SettingsSync.decode(Data(json.utf8))
        #expect(s.serviceStatus == .standard)
        #expect(s.serviceStatus.xai && s.serviceStatus.cursor && !s.serviceStatus.notify)
        // The new section lands right after the rings, shown, and the old choices are kept.
        // (0.9.3's Cursor ring also lands after the rings, switched off.)
        // (The Grok ring, added after 0.9.5, lands right after the Total ring, shown.)
        #expect(Array(s.sections.map(\.id).prefix(6)) == [.grokRing, .regularGrokRing, .grokBotRing, .cursorRing, .serviceStatus, .historyPace])
        #expect(!s.isVisible(.cursorRing))
        #expect(s.isVisible(.serviceStatus))
        #expect(!s.isVisible(.historyPace))
        #expect(s.showsServiceStatus)
    }

    @Test func settingsRoundTripAndPartialKeys() throws {
        var g = GaugeSettings()
        g.serviceStatus = ServiceStatusSettings(xai: true, cursor: false, notify: true)
        let back = try SettingsSync.decode(SettingsSync.encode(g))
        #expect(back.serviceStatus == g.serviceStatus)
        #expect(back.serviceStatus.enabled == [.xai])
        let partial = #"{"app":"GrokGauge","schema":1,"settings":{"serviceStatus":{"cursor":false,"notify":"yes"},"modifiedAt":"2026-10-08T12:00:00.000Z"}}"#
        let p = try SettingsSync.decode(Data(partial.utf8)).serviceStatus
        #expect(p == ServiceStatusSettings(xai: true, cursor: false, notify: false))
    }

    @Test func noSourcesHidesRow() {
        var g = GaugeSettings()
        g.serviceStatus = ServiceStatusSettings(xai: false, cursor: false)
        #expect(!g.showsServiceStatus)
    }
}
