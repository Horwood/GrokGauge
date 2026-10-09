import Foundation
import Testing
@testable import GrokGaugeCore

// MARK: - Fixtures

private let sitemapXML = """
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>https://x.ai/news</loc><lastmod>2026-10-01T00:00:00.000Z</lastmod></url>
<url><loc>https://x.ai/news/grok-4-7</loc><lastmod>2026-09-20T00:00:00.000Z</lastmod></url>
<url><loc>https://x.ai/news/team-bots</loc><lastmod>2026-09-28T00:00:00.000Z</lastmod></url>
<url><loc>https://x.ai/careers</loc><lastmod>2026-10-05T00:00:00.000Z</lastmod></url>
<url><loc>https://x.ai/news/a/b</loc><lastmod>2026-10-05T00:00:00.000Z</lastmod></url>
<url><loc>https://evil.example/news/team-bots</loc></url>
<url><loc>https://x.ai/news/old-post</loc></url>
</urlset>
"""

private let articleHTML = """
<html><head><title>Team Bots &amp; you | SpaceXAI</title>
<meta name="description" content="Shared AI teammates that learn as they work &#8212; in Slack.">
<script type="application/ld+json">{"@type":"NewsArticle","datePublished":"2026-09-28T16:00:00.000Z"}</script>
</head><body></body></html>
"""

private let releaseNotesMD = """
# Release Notes

Stay up to date with the latest changes to the xAI API.

## October

### Grok 4.7 is available

[Grok 4.7](/developers/models/grok-4.7) is now available as `grok-4.7` with **2M** context.

More text.

### Batch API discounts

Batch requests now cost 50% less.

## September

### Voice Agent API

The \\_voice\\_ endpoint is GA.

## January

### New Year model

Hello.

## December

### Old one

Body.
"""

private let lookupJSON = """
{"resultCount":3,"results":[
 {"trackId":6670324846,"trackName":"Grok AI","version":"1.4.50","currentVersionReleaseDate":"2026-10-07T17:00:00Z",
  "releaseNotes":"Improvements to Chat\\n\\n- Voice fixes\\n- Imagine updates\\n- More","trackViewUrl":"https://apps.apple.com/us/app/grok-ai/id6670324846?uo=4"},
 {"trackId":6794501026,"trackName":"Grok Bot","version":"0.70.0","currentVersionReleaseDate":"2026-10-06T10:00:00Z",
  "releaseNotes":"","trackViewUrl":"https://apps.apple.com/us/app/grok-bot/id6794501026?uo=4"},
 {"trackId":1,"trackName":"Impostor","version":"9.9","trackViewUrl":"https://apps.apple.com/us/app/x/id1"}
]}
"""

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    Calendar.utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private func item(_ id: String, _ src: NewsSource = .news, date: Date? = nil) -> NewsItem {
    NewsItem(id: id, source: src, title: id, date: date)
}

// MARK: - Parsers

@Suite struct WhatsNewParserTests {
    @Test func sitemapKeepsOnlyNewsArticlesNewestFirst() {
        let entries = NewsSitemap.parse(Data(sitemapXML.utf8))
        let slugs = entries.map { $0.slug }
        #expect(slugs == ["team-bots", "grok-4-7", "old-post"])
        #expect(entries.first?.url.absoluteString == "https://x.ai/news/team-bots")
        #expect(NewsSitemap.title(fromSlug: "grok-4-7") == "Grok 4 7")
    }

    @Test func articleMetaReadsTitleSummaryAndDate() {
        let m = ArticleMeta.parse(Data(articleHTML.utf8))
        #expect(m.title == "Team Bots & you")
        #expect(m.summary == "Shared AI teammates that learn as they work — in Slack.")
        #expect(m.published == ISODate.parse("2026-09-28T16:00:00.000Z"))
    }

    @Test func releaseNotesBecomeItemsWithInferredYears() {
        let items = ReleaseNotes.parse(Data(releaseNotesMD.utf8), now: day(2026, 10, 8))
        let titles = items.map { $0.title }
        #expect(titles == ["Grok 4.7 is available", "Batch API discounts", "Voice Agent API", "New Year model", "Old one"])
        #expect(items[0].detail == "Grok 4.7 is now available as grok-4.7 with 2M context.")
        #expect(items[2].detail == "The _voice_ endpoint is GA.")
        #expect(items[0].monthOnly)
        #expect(items[0].id.hasPrefix("rn:2026-10:"))
        #expect(items[3].id.hasPrefix("rn:2026-01:"))
        #expect(items[4].id.hasPrefix("rn:2025-12:"))     // months wrapped: previous year
        #expect(items[0].url == NewsLinks.releaseNotesPage)
        // Stable ids across fetches (read marks survive).
        #expect(ReleaseNotes.parse(Data(releaseNotesMD.utf8), now: day(2026, 10, 9)).map { $0.id } == items.map { $0.id })
    }

    @Test func releaseNotesFirstMonthLaterThanNowIsLastYear() {
        let items = ReleaseNotes.parse(Data("## December\n\n### Thing\n\nx\n".utf8), now: day(2026, 3, 1))
        #expect(items.first?.id.hasPrefix("rn:2025-12:") == true)
    }

    @Test func cliPointerAcceptsOnlyAVersion() {
        #expect(GrokCLIVersion.parsePointer(Data("1.0.50\n".utf8)) == "1.0.50")
        #expect(GrokCLIVersion.parsePointer(Data("1.1.0-beta.2".utf8)) == "1.1.0-beta.2")
        #expect(GrokCLIVersion.parsePointer(Data("<html>nope</html>".utf8)) == nil)
        #expect(GrokCLIVersion.parsePointer(Data("".utf8)) == nil)
    }

    @Test func cliItemOnlyWhenNewer() {
        let i = GrokCLIVersion.item(latest: "1.0.50", installed: "1.0.46", published: nil)
        #expect(i?.id == "cli:1.0.50")
        #expect(i?.command == "grok update")
        #expect(GrokCLIVersion.item(latest: "1.0.46", installed: "1.0.46", published: nil) == nil)
        #expect(GrokCLIVersion.item(latest: "1.0.40", installed: "1.0.46", published: nil) == nil)
        #expect(GrokCLIVersion.item(latest: "1.0.50", installed: nil, published: nil) == nil)
    }

    @Test func installedCLIVersionFromSymlinkOrVersionJSON() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grokhome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        #expect(GrokCLIVersion.installed(grokHome: home) == nil)
        try Data(#"{"version":"1.0.44","checked_at":"x"}"#.utf8).write(to: home.appendingPathComponent("version.json"))
        #expect(GrokCLIVersion.installed(grokHome: home) == "1.0.44")
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("bin/grok").path,
                                                   withDestinationPath: "../downloads/grok-1.0.46-macos-aarch64")
        #expect(GrokCLIVersion.installed(grokHome: home) == "1.0.46")
        #expect(GrokCLIVersion.version(fromBinaryName: "grok-1.1.0-beta.2-macos-x86_64") == "1.1.0-beta.2")
        #expect(GrokCLIVersion.version(fromBinaryName: "grok-garbage") == nil)
    }

    @Test func appStoreLookupKeepsOnlyGrokApps() {
        let items = AppStoreLookup.parse(Data(lookupJSON.utf8))
        #expect(items.count == 2)
        #expect(items[0].id == "app:6670324846:1.4.50")
        #expect(items[0].title == "Grok AI 1.4.50 for iPhone and iPad")
        #expect(items[0].url?.absoluteString == "https://apps.apple.com/us/app/grok-ai/id6670324846")
        #expect(items[0].detail == "Improvements to Chat Voice fixes Imagine updates")
        #expect(items[1].detail == nil)
        #expect(AppStoreLookup.parse(Data("garbage".utf8)).isEmpty)
    }

    @Test func grokBotMacVersionFromInfoPlist() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Grok Bot \(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.68.1"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let found = GrokBotMacApp.installed(in: [URL(fileURLWithPath: "/nonexistent/Grok Bot.app"), app])
        #expect(found?.version == "0.68.1")
        let i = GrokBotMacApp.item(found!)
        #expect(i.id == "botmac:0.68.1")
        #expect(i.opensGrokBot)
    }

    @Test func linksAreLimitedToKnownHttpsHosts() {
        #expect(NewsLinks.safe("https://x.ai/news/a") != nil)
        #expect(NewsLinks.safe("http://x.ai/news/a") == nil)
        #expect(NewsLinks.safe("https://x.ai.evil.example/") == nil)
        #expect(NewsLinks.safe("javascript:alert(1)") == nil)
        #expect(NewsLinks.safe("https://user:pw@docs.x.ai/x")?.absoluteString == "https://docs.x.ai/x")
    }
}

// MARK: - Read/unread engine

@Suite struct WhatsNewStateTests {
    @Test func firstFetchMarksEverythingReadThenNewItemsAreUnread() {
        var s = WhatsNewState()
        let first = s.apply(.news, items: [item("a"), item("b")])
        #expect(first.isEmpty)
        #expect(s.unread(enabled: [.news]).isEmpty)
        let second = s.apply(.news, items: [item("c"), item("a"), item("b")])
        #expect(second.map { $0.id } == ["c"])
        #expect(s.unread(enabled: [.news]).map { $0.id } == ["c"])
        // Same list again: nothing "new" to notify about, but c stays unread.
        #expect(s.apply(.news, items: [item("c"), item("a")]).isEmpty)
        #expect(s.unread(enabled: [.news]).count == 1)
        s.markAllRead()
        #expect(s.unread(enabled: [.news]).isEmpty)
    }

    @Test func eachSourceHasItsOwnFirstRun() {
        var s = WhatsNewState()
        s.apply(.news, items: [item("a")])
        #expect(s.apply(.grokApps, items: [item("app:1:1", .grokApps)]).isEmpty)
        let new = s.apply(.grokApps, items: [item("app:1:2", .grokApps)])
        #expect(new.map { $0.id } == ["app:1:2"])
        #expect(s.items(for: .news).count == 1)          // other sources untouched
    }

    @Test func markReadAndDisabledSourcesDontCount() {
        var s = WhatsNewState()
        s.apply(.news, items: [])
        s.apply(.grokCLI, items: [])
        s.apply(.news, items: [item("a")])
        s.apply(.grokCLI, items: [item("cli:2", .grokCLI)])
        #expect(s.unread(enabled: [.news, .grokCLI]).count == 2)
        #expect(s.unread(enabled: [.news]).count == 1)
        s.markRead("a")
        #expect(s.unread(enabled: [.news]).isEmpty)
    }

    @Test func latestIsNewestFirstFilteredAndLimited() {
        var s = WhatsNewState()
        s.apply(.news, items: [item("old", date: day(2026, 9, 1)), item("new", date: day(2026, 10, 7)), item("undated")])
        s.apply(.grokApps, items: [item("app", .grokApps, date: day(2026, 10, 1))])
        #expect(s.latest(enabled: [.news, .grokApps], limit: 3).map { $0.id } == ["new", "app", "old"])
        #expect(s.latest(enabled: [.grokApps]).map { $0.id } == ["app"])
        #expect(s.latest(enabled: [.news], limit: 5).last?.id == "undated")
    }

    @Test func scheduleAndBackoff() {
        var s = WhatsNewState()
        let t0 = day(2026, 10, 8)
        #expect(s.isDue(.news, interval: 6 * 3600, now: t0))
        s.apply(.news, items: [], now: t0)
        #expect(!s.isDue(.news, interval: 6 * 3600, now: t0.addingTimeInterval(5 * 3600)))
        #expect(s.isDue(.news, interval: 6 * 3600, now: t0.addingTimeInterval(6 * 3600)))
        // Failures back off 5 min, 10 min … never longer than the interval.
        s.recordFailure(.news, "Timed out", now: t0)
        #expect(!s.isDue(.news, interval: 6 * 3600, now: t0.addingTimeInterval(200)))
        #expect(s.isDue(.news, interval: 6 * 3600, now: t0.addingTimeInterval(301)))
        s.recordFailure(.news, "Timed out", now: t0)
        #expect(!s.isDue(.news, interval: 6 * 3600, now: t0.addingTimeInterval(301)))
        #expect(s.isDue(.news, interval: 6 * 3600, now: t0.addingTimeInterval(601)))
        for _ in 0..<20 { s.recordFailure(.news, "x", now: t0) }
        #expect(s.isDue(.news, interval: 2 * 3600, now: t0.addingTimeInterval(2 * 3600)))
        #expect(s.state(.news).lastError == "x")
        s.apply(.news, items: [], now: t0)
        #expect(s.state(.news).failures == 0)
        #expect(s.state(.news).lastError == nil)
    }

    @Test func roundTripsThroughDisk() throws {
        var s = WhatsNewState()
        // Whole-second times (seconds-since-1970 doubles can't hold every sub-second Date exactly).
        s.apply(.news, items: [item("a", date: day(2026, 10, 1))], now: day(2026, 10, 7))
        s.apply(.news, items: [item("b"), item("a", date: day(2026, 10, 1))], now: day(2026, 10, 8))
        s.update(.news) { $0.etag = "\"abc\"" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try s.save(to: url)
        let back = WhatsNewState.load(from: url)
        #expect(back == s)
        #expect(WhatsNewState.load(from: URL(fileURLWithPath: "/nonexistent/x.json")) == WhatsNewState())
    }
}

// MARK: - Settings

@Suite struct WhatsNewSettingsTests {
    @Test func defaultsAllSourcesOnNotificationsOffSixHours() {
        let w = GaugeSettings().whatsNew
        #expect(w.enabled == Set(NewsSource.allCases))
        #expect(!w.notify)
        #expect(w.interval == .six)
        #expect(w.interval(for: .grokCLI) == 2 * 3600)
        #expect(w.interval(for: .news) == 6 * 3600)
        #expect(GaugeSettings().showsWhatsNewSection)
    }

    @Test func settingsFrom091GetTheSectionBeforeTheRefreshRow() throws {
        // A 0.9.1 save: no whatsNew key, no whatsNew section.
        var old = GaugeSettings()
        old.sections = old.sections.filter { $0.id != .whatsNew }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "whatsNew")
        let decoded = try JSONDecoder().decode(GaugeSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.whatsNew == .standard)
        let ids = decoded.sections.map { $0.id }
        #expect(ids.contains(.whatsNew))
        let i = ids.firstIndex(of: .whatsNew)!
        #expect(ids[i + 1] == .refreshRow)
    }

    @Test func roundTripsAndToleratesBadValues() throws {
        var s = GaugeSettings()
        s.whatsNew.news = false
        s.whatsNew.notify = true
        s.whatsNew.interval = .day
        let back = try JSONDecoder().decode(GaugeSettings.self, from: JSONEncoder().encode(s))
        #expect(back.whatsNew == s.whatsNew)
        let partial = try JSONDecoder().decode(WhatsNewSettings.self, from: Data(#"{"interval":5,"notify":"yes","grokCLI":false}"#.utf8))
        #expect(partial.interval == .six)
        #expect(!partial.notify)
        #expect(!partial.grokCLI)
        #expect(partial.news)
    }

    @Test func sectionHiddenWhenNoSourcesOrUnchecked() {
        var s = GaugeSettings()
        for src in NewsSource.allCases { s.whatsNew.set(src, false) }
        #expect(!s.showsWhatsNewSection)
        s.whatsNew.set(.news, true)
        #expect(s.showsWhatsNewSection)
        if let i = s.sections.firstIndex(where: { $0.id == .whatsNew }) { s.sections[i].visible = false }
        #expect(!s.showsWhatsNewSection)
    }
}

// MARK: - Fetcher (scripted HTTP)

private final class ScriptedHTTP: NewsHTTP, @unchecked Sendable {
    var replies: [String: (Int, String, [String: String])] = [:]
    var failing: Set<String> = []
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); requests.append(request); lock.unlock()
        let key = request.url!.absoluteString
        if failing.contains(key) { throw URLError(.timedOut) }
        guard let reply = replies[key] else { throw URLError(.cannotFindHost) }
        let (code, body, headers) = reply
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
    }
}

@Suite struct WhatsNewFetcherTests {
    private func cliHome(_ version: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"version":"\#(version)"}"#.utf8).write(to: home.appendingPathComponent("version.json"))
        return home
    }

    @Test func sendsHonestUserAgentAndNoCredentials() async throws {
        let http = ScriptedHTTP()
        http.replies[AppStoreLookup.url.absoluteString] = (200, lookupJSON, [:])
        let f = WhatsNewFetcher(appVersion: "0.9.1", http: http)
        let r = try await f.fetch(.grokApps, state: WhatsNewState())
        #expect(r.items?.count == 2)
        let req = try #require(http.requests.first)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "GrokGauge/0.9.1 (macOS menu bar)")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func cliUsesConditionalRequestAndHonors304() async throws {
        let home = try cliHome("1.0.46")
        defer { try? FileManager.default.removeItem(at: home) }
        let http = ScriptedHTTP()
        let primary = GrokCLIVersion.pointerURLs[0].absoluteString
        http.replies[primary] = (200, "1.0.50\n", ["ETag": "\"v50\"", "Last-Modified": "Thu, 08 Oct 2026 01:22:57 GMT"])
        let f = WhatsNewFetcher(appVersion: "0.9.1", http: http, grokHome: home)
        var state = WhatsNewState()
        let r = try await f.fetch(.grokCLI, state: state)
        #expect(r.items?.map { $0.id } == ["cli:1.0.50"])
        #expect(r.items?.first?.date == WhatsNewFetcher.httpDate("Thu, 08 Oct 2026 01:22:57 GMT"))
        #expect(r.etag == "\"v50\"")
        state.update(.grokCLI) { $0.etag = r.etag; $0.lastModified = r.lastModified }

        http.replies[primary] = (304, "", [:])
        let again = try await f.fetch(.grokCLI, state: state)
        #expect(again.items == nil)
        #expect(http.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v50\"")
        #expect(http.requests.last?.value(forHTTPHeaderField: "If-Modified-Since") == "Thu, 08 Oct 2026 01:22:57 GMT")
    }

    @Test func cliFallsBackToTheMirrorAndReportsUpToDate() async throws {
        let home = try cliHome("1.0.50")
        defer { try? FileManager.default.removeItem(at: home) }
        let http = ScriptedHTTP()
        http.failing.insert(GrokCLIVersion.pointerURLs[0].absoluteString)
        http.replies[GrokCLIVersion.pointerURLs[1].absoluteString] = (200, "1.0.50", [:])
        let r = try await WhatsNewFetcher(appVersion: "0.9.1", http: http, grokHome: home).fetch(.grokCLI, state: WhatsNewState())
        #expect(r.items == [])
        #expect(r.note == "up to date (1.0.50)")
        #expect(http.requests.count == 2)
    }

    @Test func cliNotInstalledMakesNoRequest() async {
        let http = ScriptedHTTP()
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        await #expect(throws: NewsFetchError.notInstalled) {
            try await WhatsNewFetcher(appVersion: "0.9.1", http: http, grokHome: empty).fetch(.grokCLI, state: WhatsNewState())
        }
        #expect(http.requests.isEmpty)
    }

    @Test func newsReadsSitemapThenArticleTitles() async throws {
        let http = ScriptedHTTP()
        http.replies[WhatsNewFetcher.newsSitemap.absoluteString] = (200, sitemapXML, [:])
        http.replies["https://x.ai/news/team-bots"] = (200, articleHTML, [:])
        let f = WhatsNewFetcher(appVersion: "0.9.1", http: http)
        let r = try await f.fetch(.news, state: WhatsNewState())
        let items = try #require(r.items)
        #expect(items.map { $0.id } == ["news:https://x.ai/news/team-bots", "news:https://x.ai/news/grok-4-7", "news:https://x.ai/news/old-post"])
        #expect(items[0].title == "Team Bots & you")
        #expect(items[1].title == "Grok 4 7")            // article fetch failed: slug title
        // A second check doesn't refetch an article whose real title we already have.
        var state = WhatsNewState()
        state.apply(.news, items: items)
        let before = http.requests.count
        _ = try await f.fetch(.news, state: state)
        let refetched = http.requests[before...].contains { $0.url?.absoluteString == "https://x.ai/news/team-bots" }
        #expect(!refetched)
    }

    @Test func errorsAreShortAndTyped() async {
        let http = ScriptedHTTP()
        http.replies[WhatsNewFetcher.releaseNotesMarkdown.absoluteString] = (403, "<html>blocked</html>", [:])
        let f = WhatsNewFetcher(appVersion: "0.9.1", http: http)
        await #expect(throws: NewsFetchError.http(403)) { try await f.fetch(.releaseNotes, state: WhatsNewState()) }
        http.replies[WhatsNewFetcher.releaseNotesMarkdown.absoluteString] = (200, "no headings here", [:])
        await #expect(throws: NewsFetchError.unreadable) { try await f.fetch(.releaseNotes, state: WhatsNewState()) }
        http.failing.insert(WhatsNewFetcher.releaseNotesMarkdown.absoluteString)
        await #expect(throws: NewsFetchError.network("Timed out")) { try await f.fetch(.releaseNotes, state: WhatsNewState()) }
    }
}
