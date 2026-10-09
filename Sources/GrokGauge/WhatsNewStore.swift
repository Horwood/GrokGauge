import AppKit
import Combine
import GrokGaugeCore

/// Drives "What's new from xAI": checks enabled sources on their schedule (first check ~60 s after
/// launch), keeps items and read marks in Application Support (never synced), and posts at most one
/// summary notification per check when the user turned notifications on.
@MainActor
final class WhatsNewStore: ObservableObject {
    @Published private(set) var state: WhatsNewState
    @Published private(set) var isChecking = false

    static let firstCheckDelay: TimeInterval = 60
    static let tick: TimeInterval = 10 * 60

    private let url: URL?
    private let fetcher: WhatsNewFetcher?
    private var settings: () -> WhatsNewSettings
    private var notify: (([NewsItem]) -> Void)?
    private var timer: Timer?
    private var pendingSave: DispatchWorkItem?

    init(url: URL? = WhatsNewState.defaultURL, fetcher: WhatsNewFetcher? = WhatsNewFetcher(appVersion: AppInfo.version),
         settings: @escaping () -> WhatsNewSettings = { .standard }, notify: (([NewsItem]) -> Void)? = nil) {
        self.url = url
        self.fetcher = fetcher
        self.settings = settings
        self.notify = notify
        state = url.map { WhatsNewState.load(from: $0) } ?? WhatsNewState()
    }

    /// Fixed state for --render-preview (no network, nothing saved).
    static func preview(_ state: WhatsNewState) -> WhatsNewStore {
        let s = WhatsNewStore(url: nil, fetcher: nil)
        s.state = state
        return s
    }

    /// Read-only copy of the saved state, for real-data previews (never fetches).
    static func savedPreview() -> WhatsNewStore {
        preview(WhatsNewState.load())
    }

    var enabled: Set<NewsSource> { settings().enabled }
    var unreadCount: Int { state.unread(enabled: enabled).count }
    func isUnread(_ item: NewsItem) -> Bool { state.isUnread(item) }

    func start() {
        guard fetcher != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in self?.checkDue() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDue() }
        }
        timer?.tolerance = 60
    }

    /// Checks every enabled source that's due (or all enabled sources when `force`).
    func checkDue(force: Bool = false) {
        guard let fetcher, !isChecking else { return }
        let s = settings()
        let now = Date()
        let due = NewsSource.allCases.filter { s.isOn($0) && (force || state.isDue($0, interval: s.interval(for: $0), now: now)) }
        guard !due.isEmpty else { return }
        isChecking = true
        Task {
            var fresh: [NewsItem] = []
            for source in due {
                do {
                    let r = try await fetcher.fetch(source, state: state, now: Date())
                    var st = state
                    if let items = r.items {
                        fresh += st.apply(source, items: items)
                    } else {
                        st.apply(source, items: st.items(for: source))   // 304: same items, counts as a success
                    }
                    st.update(source) { $0.etag = r.etag; $0.lastModified = r.lastModified; $0.note = r.note }
                    state = st
                } catch let e as NewsFetchError {
                    var st = state
                    if e == .notInstalled {
                        st.apply(source, items: [])
                        st.update(source) { $0.note = e.message }
                    } else {
                        st.recordFailure(source, e.message)
                    }
                    state = st
                } catch {
                    var st = state
                    st.recordFailure(source, "Unexpected error")
                    state = st
                }
            }
            isChecking = false
            scheduleSave()
            if settings().notify, !fresh.isEmpty { notify?(fresh) }
        }
    }

    func markRead(_ item: NewsItem) {
        guard state.isUnread(item) else { return }
        state.markRead(item.id)
        scheduleSave()
    }

    func markAllRead() {
        state.markAllRead()
        scheduleSave()
    }

    /// Opens the item's page (only allow-listed https hosts) and marks it read.
    func open(_ item: NewsItem) {
        markRead(item)
        if item.opensGrokBot {
            Launcher.openGrokBot()
        } else if let u = item.url, NewsLinks.safe(u.absoluteString) != nil {
            NSWorkspace.shared.open(u)
        }
    }

    func copyCommand(_ item: NewsItem) {
        guard let c = item.command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c, forType: .string)
        markRead(item)
    }

    /// One line per source for Settings › Diagnostics (times and short words only).
    func diagnostics() -> [SourceDiagnostics] {
        let s = settings()
        return NewsSource.allCases.map { src in
            let st = state.state(src)
            let status: String
            if !s.isOn(src) {
                status = "Off"
            } else if st.lastAttempt == nil {
                status = "Not checked yet"
            } else if st.failures > 0 {
                status = "Retrying (\(st.failures) failed)"
            } else {
                status = "OK" + (st.note.map { " · \($0)" } ?? "")
            }
            return SourceDiagnostics(name: src.title, status: status, lastSuccess: st.lastSuccess,
                                     lastError: st.lastError, lastErrorAt: st.lastErrorAt)
        }
    }

    private func scheduleSave() {
        guard let url else { return }
        pendingSave?.cancel()
        let snapshot = state
        let work = DispatchWorkItem { try? snapshot.save(to: url) }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Sample items for --render-preview --demo.
    static func demoState(now: Date = Date()) -> WhatsNewState {
        var s = WhatsNewState()
        let items = [
            NewsItem(id: "cli:1.0.50", source: .grokCLI, title: "Grok CLI 1.0.50 is available",
                     detail: "You have 1.0.46. Update in Terminal with `grok update`.",
                     date: now.addingTimeInterval(-3 * 3600), command: NewsLinks.cliUpdateCommand),
            NewsItem(id: "news:team-bots", source: .news, title: "Team Bots: shared AI teammates that learn as they work",
                     date: now.addingTimeInterval(-10 * 86_400), url: URL(string: "https://x.ai/news/team-bots")),
            NewsItem(id: "app:6670324846:1.4.50", source: .grokApps, title: "Grok AI 1.4.50 for iPhone and iPad",
                     detail: "Improvements to Chat, Voice and Imagine", date: now.addingTimeInterval(-20 * 3600),
                     url: URL(string: "https://apps.apple.com/us/app/grok-ai/id6670324846")),
            NewsItem(id: "rn:grok-4.7", source: .releaseNotes, title: "Grok 4.7",
                     detail: "Grok 4.7 is now available on the xAI API as grok-4.7.",
                     date: now.addingTimeInterval(-17 * 86_400), monthOnly: true, url: NewsLinks.releaseNotesPage),
            NewsItem(id: "botmac:0.68.1", source: .grokBotMac, title: "Grok Bot for Mac 0.68.1",
                     date: now.addingTimeInterval(-30 * 86_400), opensGrokBot: true),
        ]
        for src in NewsSource.allCases {
            s.apply(src, items: [], now: now.addingTimeInterval(-3600))
            s.update(src) { $0.note = "demo" }
        }
        for src in NewsSource.allCases { s.apply(src, items: items.filter { $0.source == src }, now: now) }
        s.seen = ["botmac:0.68.1", "rn:grok-4.7"]
        return s
    }
}
