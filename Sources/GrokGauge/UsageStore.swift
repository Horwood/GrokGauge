import AppKit
import Combine
import GrokGaugeCore
import Network

/// What went wrong on the most recent refresh, phrased for people.
enum UsageProblem: Equatable {
    /// No usable login and no `grok` command found: the Grok CLI needs installing first.
    case cliNotInstalled
    case signedOut
    case expired
    case network(String)
    /// Non-2xx reply; `message` is the server's own (sanitized) error text, if any.
    case server(Int, message: String?)
    case badResponse
    /// JSON came back, but not in the shape GrokGauge knows. Never shown as 0%.
    case changedShape

    var title: String {
        switch self {
        case .cliNotInstalled: return "Grok CLI not installed"
        case .signedOut: return "Sign in to Grok"
        case .expired: return "Grok login expired"
        case .network(let m): return m
        case .server(let code, _): return "Grok returned an error (\(code))"
        case .badResponse: return "Unexpected response"
        case .changedShape: return "xAI changed something"
        }
    }

    var detail: String {
        switch self {
        case .cliNotInstalled:
            return "GrokGauge reads your Grok usage through the Grok CLI's sign-in. Install the CLI with Homebrew "
                + "(`brew install --cask grok-build`) or xAI's installer, then run `grok login` in a new Terminal window. "
                + "The Grok Bot ring works without it."
        case .signedOut:
            return "Run `grok login` in Terminal. If it says “command not found”, open a new Terminal window "
                + "(or, if you used xAI's installer, run `~/.grok/bin/grok login`). GrokGauge notices the sign-in automatically."
        case .expired: return "GrokGauge couldn't renew it automatically. Run `grok login` to reconnect, then click Refresh."
        case .network: return "GrokGauge will retry automatically."
        case .server(_, let message?):
            // Shown as Markdown: drop markup characters so server text can't add links or styling.
            let plain = String(message.filter { !"[]()*_`<>#".contains($0) })
            return "Grok said: \u{201C}\(plain)\u{201D}. GrokGauge will retry automatically."
        case .server: return "GrokGauge will retry automatically."
        case .badResponse: return "Grok's reply wasn't readable. GrokGauge will retry automatically."
        case .changedShape:
            return "Grok's usage reply no longer looks the way GrokGauge expects, so it isn't showing a number "
                + "rather than guessing. Check Settings › About for an update."
        }
    }

    /// Line for Settings › Diagnostics: the title plus the server's sanitized message, when it sent one.
    var diagnosticsMessage: String {
        if case .server(_, let message?) = self { return "\(title): \(message)" }
        return title
    }

    /// Needs the user to install the CLI or sign in (no number can be shown until then).
    var needsLogin: Bool { self == .signedOut || self == .expired || self == .cliNotInstalled }

    /// Worth retrying soon with backoff (instead of waiting for the next scheduled refresh).
    var isTransient: Bool {
        switch self {
        case .network, .badResponse: return true
        // 400/408/421 have come from a failing proxy instance, not from a bad request: retry soon.
        case .server(let code, _): return code == 400 || code == 408 || code == 421 || code == 429 || code >= 500
        default: return false
        }
    }

    /// Short caption under the Total and Grok rings.
    var ringCaption: String {
        switch self {
        case .cliNotInstalled: return "Install the Grok CLI"
        case .signedOut, .expired: return "Run `grok login`"
        case .changedShape: return "xAI changed something"
        default: return "Can't reach Grok"
        }
    }

    init(_ error: Error) {
        switch error as? FetchError {
        case .auth(.notSignedIn)?, .auth(.unreadable)?: self = .signedOut
        case .auth(.expired)?, .auth(.refreshRejected)?, .unauthorized?: self = .expired
        case .auth(.refreshUnavailable)?: self = .network("Couldn't renew your Grok login")
        case .network(let m)?: self = .network(m)
        case .http(let code, let message)?: self = .server(code, message: message)
        case .unexpectedShape?: self = .changedShape
        case .badResponse?, nil: self = .badResponse
        }
    }
}

/// Why the Grok Bot ring has no number right now.
enum BotProblem: Equatable {
    case notInstalled
    case noReading
    case unavailable
    case stale(GrokBotSnapshot)
    case unrecognized

    init(_ error: GrokBotUsageError) {
        switch error {
        case .notInstalled: self = .notInstalled
        case .noReading: self = .noReading
        case .unavailable: self = .unavailable
        case .stale(let s): self = .stale(s)
        case .unrecognized: self = .unrecognized
        }
    }

    /// Short caption under the ring.
    var caption: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .noReading: return "Open Grok Bot to reconnect"
        case .stale: return "Open Grok Bot to update"
        case .unavailable: return "No weekly limit"
        case .unrecognized: return "Couldn't read usage"
        }
    }

    /// Whether opening Grok Bot is the fix.
    var opensGrokBot: Bool {
        switch self {
        case .noReading, .stale: return true
        default: return false
        }
    }

    var tooltip: String {
        switch self {
        case .notInstalled: return "Grok Bot isn't installed"
        case .noReading: return "Open Grok Bot to reconnect"
        case .stale(let s): return "Last reading (\(s.roundedPercent)%) is out of date. Open Grok Bot to update"
        case .unavailable: return "Grok Bot reports no personal weekly limit"
        case .unrecognized: return "Grok Bot's usage format changed; update GrokGauge"
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var problem: UsageProblem?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var botSnapshot: GrokBotSnapshot?
    @Published private(set) var botProblem: BotProblem?
    /// What the Grok Bot ring shows: Grok Bot's own allowance, or its share of the shared Grok pool.
    @Published private(set) var botRing: BotRingReading?

    // Diagnostics (times and short status words only).
    @Published private(set) var grokLastSuccess: Date?
    @Published private(set) var grokLastError: (message: String, at: Date)?
    @Published private(set) var botLastSuccess: Date?
    @Published private(set) var botLastError: (message: String, at: Date)?
    @Published private(set) var nextRetry: Date?

    private let client = BillingClient(appVersion: AppInfo.version)
    /// The pool end last seen as shared with Grok Bot (survives relaunches, so the ring doesn't flash the
    /// whole pool before the first Grok fetch).
    private let defaults: UserDefaults?
    static let sharedEndKey = "pool.sharedWithGrokBotEnd"
    private var knownSharedEnd: Date?
    private let notifier: UsageNotifier
    private let history: HistoryStore?
    private var settings: () -> GaugeSettings
    private var timer: Timer?
    private var botTimer: Timer?
    /// While setup is needed: notices `grok login` finishing or the CLI appearing, without a relaunch.
    private var setupTimer: Timer?
    private var loginStamp: Date?
    /// The login shell's PATH (read once, off the main thread), for finding `grok`.
    private var shellPATH: String?
    private var retryWork: DispatchWorkItem?
    private var failures = 0
    private var interval: TimeInterval = AppInfo.refreshInterval
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool?
    /// After wake or a network change, failures are retried quietly instead of flashing an error.
    private var graceUntil: Date?
    static let graceAfterWake: TimeInterval = 45
    static let delayAfterWake: TimeInterval = 8
    static let delayAfterNetworkChange: TimeInterval = 4

    init(notifier: UsageNotifier, history: HistoryStore? = nil, defaults: UserDefaults? = nil,
         settings: @escaping () -> GaugeSettings = { GaugeSettings() }) {
        self.notifier = notifier
        self.history = history
        self.defaults = defaults
        self.settings = settings
        if let t = defaults?.object(forKey: Self.sharedEndKey) as? Double { knownSharedEnd = Date(timeIntervalSince1970: t) }
    }

    var hasGrokBot: Bool { botProblem != .notInstalled }

    /// Grok Bot is on the shared SuperGrok pool (its ring shows its share of the Total ring).
    var botShared: Bool { botRing?.isShared ?? false }

    /// Cursor's share of the Grok pool, when the billing reply lists it.
    var cursorShare: ProductShare? { snapshot.flatMap(PoolSharing.cursorShare(in:)) }

    /// The pool split into Grok, Grok Bot and Cursor (the Total ring and its three slices). One function feeds
    /// the rings, the menu bar tooltip, Diagnostics and the preview/tour renders.
    var poolBreakdown: PoolBreakdown? { snapshot.map { PoolBreakdown.make(pool: $0, bot: botRing) } }

    /// Used by `--render-preview` to draw the popover with a fixed snapshot.
    func showPreview(_ snapshot: UsageSnapshot?, problem: UsageProblem? = nil, bot: GrokBotSnapshot?, botProblem: BotProblem?) {
        self.snapshot = snapshot
        self.problem = problem
        lastAttempt = snapshot?.fetchedAt ?? Date()
        grokLastSuccess = snapshot?.fetchedAt
        botSnapshot = bot
        botLastSuccess = bot?.readAt
        self.botProblem = botProblem
        botRing = bot.map { BotRingReading.make(bot: $0, pool: snapshot, knownSharedEnd: nil) }
    }

    func start() {
        refresh()
        schedule(interval: settings().refreshInterval.seconds)
        // Grok Bot's number is a local file read (no network), so check it more often.
        botTimer = Timer.scheduledTimer(withTimeInterval: AppInfo.botRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBot() }
        }
        botTimer?.tolerance = 15
        loginStamp = GrokCLISetup.loginStamp()
        Task.detached(priority: .utility) {
            let path = GrokCLISetup.loginShellPATH()
            await MainActor.run { [weak self] in
                self?.shellPATH = path
                if self?.problem == .cliNotInstalled, GrokCLISetup.findCLI(shellPATH: path) != nil { self?.refresh() }
            }
        }
        setupTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchSetup() }
        }
        setupTimer?.tolerance = 1

        let ws = NSWorkspace.shared.notificationCenter
        sleepObserver = ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retryWork?.cancel() }
        }
        wakeObserver = ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.handlePath(satisfied: ok) }
        }
        monitor.start(queue: DispatchQueue(label: "GrokGauge.path"))
        pathMonitor = monitor
    }

    /// Re-arms the periodic timer when the interval setting changes.
    func schedule(interval newInterval: TimeInterval) {
        guard timer == nil || newInterval != interval else { return }
        interval = newInterval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: newInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = min(60, newInterval / 10)
    }

    private func handleWake() {
        graceUntil = Date().addingTimeInterval(Self.graceAfterWake)
        retryWork?.cancel()
        scheduleRetry(after: Self.delayAfterWake, resetFailures: true)
    }

    private func handlePath(satisfied: Bool) {
        let previous = lastPathSatisfied
        lastPathSatisfied = satisfied
        guard let previous, satisfied else { return }   // ignore the initial report and going offline
        // Back online (or switched networks): let DNS/VPN settle, then refresh quietly.
        graceUntil = Date().addingTimeInterval(Self.graceAfterWake)
        if !previous || problem?.isTransient == true {
            scheduleRetry(after: Self.delayAfterNetworkChange, resetFailures: true)
        }
    }

    private var inGrace: Bool { graceUntil.map { Date() < $0 } ?? false }

    /// Refresh if the data is older than `age` seconds (used when the popover opens).
    func refreshIfStale(olderThan age: TimeInterval = 60) {
        refreshBot()
        // Setup in progress: check again every time the dropdown opens.
        if problem?.needsLogin == true { return refresh() }
        guard let last = lastAttempt else { return refresh() }
        if Date().timeIntervalSince(last) > age { refresh() }
    }

    /// Re-reads Grok Bot's own cached weekly usage. Read-only, no network.
    func refreshBot() {
        do {
            let s = try GrokBotUsageReader.read()
            botSnapshot = s
            botProblem = nil
            botLastSuccess = s.readAt
        } catch let e as GrokBotUsageError {
            botSnapshot = nil
            botProblem = BotProblem(e)
            if e != .notInstalled { botLastError = (BotProblem(e).tooltip, Date()) }
        } catch {
            botSnapshot = nil
            botProblem = .unrecognized
            botLastError = (BotProblem.unrecognized.tooltip, Date())
        }
        updateBotRing()
    }

    /// Decides what the Grok Bot ring shows (own allowance or share of the shared pool), then records it in
    /// the history and checks alerts against that same number, so one pool never alerts twice.
    private func updateBotRing() {
        guard let bot = botSnapshot else {
            botRing = nil
            return
        }
        let ring = BotRingReading.make(bot: bot, pool: snapshot, knownSharedEnd: knownSharedEnd,
                                       poolLoading: snapshot == nil && problem == nil)
        if ring != botRing { botRing = ring }
        if ring.isShared, ring.percent != nil, let end = ring.nextReset, end != knownSharedEnd {
            knownSharedEnd = end
            defaults?.set(end.timeIntervalSince1970, forKey: Self.sharedEndKey)
        }
        guard let p = ring.percent, let rounded = ring.roundedPercent else { return }
        history?.record(.grokBot, percent: p, at: ring.readAt, shared: ring.isShared)
        notifier.evaluateBot(rounded: rounded, shared: ring.isShared, periodKey: ring.periodKey, reset: ring.nextReset,
                             thresholds: settings().effectiveNotificationThresholds)
    }

    func refresh() {
        refreshBot()
        guard !isRefreshing else { return }
        isRefreshing = true
        lastAttempt = Date()
        retryWork?.cancel()
        Task {
            do {
                let s = try await client.fetch()
                snapshot = s
                problem = nil
                failures = 0
                nextRetry = nil
                grokLastSuccess = s.fetchedAt
                history?.record(.grok, percent: s.percent, at: s.fetchedAt)
                if let c = PoolSharing.cursorShare(in: s) { history?.record(.cursor, percent: c.percent, at: s.fetchedAt) }
                notifier.evaluate(s, thresholds: settings().effectiveNotificationThresholds)
                updateBotRing()
            } catch {
                var p = UsageProblem(error)
                if p == .signedOut, GrokCLISetup.findCLI(shellPATH: shellPATH) == nil { p = .cliNotInstalled }
                handleFailure(p)
                updateBotRing()
            }
            isRefreshing = false
        }
    }

    /// Where Grok setup stands right now (cheap local checks; no network, never reads the token aloud).
    func cliState() -> GrokCLIState {
        GrokCLISetup.state(cliPath: GrokCLISetup.findCLI(shellPATH: shellPATH),
                           hasUsableLogin: GrokCLISetup.hasUsableLogin())
    }

    /// The Grok CLI found on this Mac (path, how it was installed, version), for Diagnostics.
    func cli() -> GrokCLI? {
        GrokCLISetup.locate(shellPATH: shellPATH)
    }

    /// Every few seconds while setup is needed: refresh as soon as `auth.json` appears or changes,
    /// and move from "not installed" to "sign in" once the CLI shows up.
    private func watchSetup() {
        guard let p = problem, p.needsLogin, !isRefreshing else { return }
        let stamp = GrokCLISetup.loginStamp()
        if stamp != loginStamp {
            loginStamp = stamp
            if stamp != nil { return refresh() }
        }
        if p == .cliNotInstalled, GrokCLISetup.findCLI(shellPATH: shellPATH) != nil {
            problem = .signedOut
        }
    }

    private func handleFailure(_ p: UsageProblem) {
        grokLastError = (p.diagnosticsMessage, Date())
        if p.isTransient {
            failures += 1
            let delay = Backoff.delay(attempt: failures)
            // Right after wake / a network change, retry quietly instead of flashing "You're offline".
            if inGrace && failures <= 4 {
                scheduleRetry(after: min(delay, 15))
                return
            }
            if delay < interval { scheduleRetry(after: delay) }
        } else {
            failures = 0
            nextRetry = nil
        }
        problem = p
        // A rejected or missing login, or a reply we can't read, means the old number can't be trusted.
        if p.needsLogin || p == .changedShape { snapshot = nil }
    }

    private func scheduleRetry(after delay: TimeInterval, resetFailures: Bool = false) {
        if resetFailures { failures = 0 }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        retryWork = work
        nextRetry = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Expiry time of the Grok login (read from auth.json; the token itself is never exposed).
    func grokTokenExpiry() -> Date? {
        (try? AuthStore.readBest())?.expiresAt
    }
}
