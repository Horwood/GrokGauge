import AppKit
import Combine
import GrokGaugeCore

/// What went wrong on the most recent refresh, phrased for people.
enum UsageProblem: Equatable {
    case signedOut
    case expired
    case network(String)
    case server(Int)
    case badResponse

    var title: String {
        switch self {
        case .signedOut: return "Connect your Grok account"
        case .expired: return "Grok login expired"
        case .network(let m): return m
        case .server(let code): return "Grok returned an error (\(code))"
        case .badResponse: return "Unexpected response"
        }
    }

    var detail: String {
        switch self {
        case .signedOut: return "Run `grok login` in Terminal, then click Refresh."
        case .expired: return "GrokGauge couldn't renew it automatically. Run `grok login` to reconnect, then click Refresh."
        case .network: return "GrokGauge will retry automatically."
        case .server: return "GrokGauge will retry automatically."
        case .badResponse: return "xAI may have changed the unofficial usage endpoint."
        }
    }

    var needsLogin: Bool { self == .signedOut || self == .expired }

    init(_ error: Error) {
        switch error as? FetchError {
        case .auth(.notSignedIn)?, .auth(.unreadable)?: self = .signedOut
        case .auth(.expired)?, .auth(.refreshRejected)?, .unauthorized?: self = .expired
        case .auth(.refreshUnavailable)?: self = .network("Couldn't renew your Grok login")
        case .network(let m)?: self = .network(m)
        case .http(let code)?: self = .server(code)
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
    @Published var menuBarStyle: MenuBarStyle {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: Self.styleKey) }
    }
    private static let styleKey = "menuBar.style"

    private let client = BillingClient(appVersion: AppInfo.version)
    private let notifier: UsageNotifier
    private var timer: Timer?
    private var botTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(notifier: UsageNotifier) {
        self.notifier = notifier
        menuBarStyle = UserDefaults.standard.string(forKey: Self.styleKey).flatMap(MenuBarStyle.init(rawValue:)) ?? .highest
    }

    var hasGrokBot: Bool { botProblem != .notInstalled }

    /// Used by `--render-preview` to draw the popover with a fixed snapshot.
    func showPreview(_ snapshot: UsageSnapshot, bot: GrokBotSnapshot?, botProblem: BotProblem?) {
        self.snapshot = snapshot
        problem = nil
        lastAttempt = snapshot.fetchedAt
        botSnapshot = bot
        self.botProblem = botProblem
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: AppInfo.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 60
        // Grok Bot's number is a local file read (no network), so check it more often.
        botTimer = Timer.scheduledTimer(withTimeInterval: AppInfo.botRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBot() }
        }
        botTimer?.tolerance = 15
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the network a moment to come back after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// Refresh if the data is older than `age` seconds (used when the popover opens).
    func refreshIfStale(olderThan age: TimeInterval = 60) {
        refreshBot()
        guard let last = lastAttempt else { return refresh() }
        if Date().timeIntervalSince(last) > age { refresh() }
    }

    /// Re-reads Grok Bot's own cached weekly usage. Read-only, no network.
    func refreshBot() {
        do {
            let s = try GrokBotUsageReader.read()
            botSnapshot = s
            botProblem = nil
            notifier.evaluate(s)
        } catch let e as GrokBotUsageError {
            botSnapshot = nil
            botProblem = BotProblem(e)
        } catch {
            botSnapshot = nil
            botProblem = .unrecognized
        }
    }

    func refresh() {
        refreshBot()
        guard !isRefreshing else { return }
        isRefreshing = true
        lastAttempt = Date()
        Task {
            do {
                let s = try await client.fetch()
                snapshot = s
                problem = nil
                notifier.evaluate(s)
            } catch {
                let p = UsageProblem(error)
                problem = p
                // A rejected or missing login means the old numbers can't be trusted anymore.
                if p.needsLogin { snapshot = nil }
            }
            isRefreshing = false
        }
    }
}
