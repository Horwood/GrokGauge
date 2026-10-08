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

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var problem: UsageProblem?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastAttempt: Date?

    private let client = BillingClient(appVersion: AppInfo.version)
    private let notifier: UsageNotifier
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(notifier: UsageNotifier) {
        self.notifier = notifier
    }

    /// Used by `--render-preview` to draw the popover with a fixed snapshot.
    func showPreview(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        problem = nil
        lastAttempt = snapshot.fetchedAt
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: AppInfo.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 60
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
        guard let last = lastAttempt else { return refresh() }
        if Date().timeIntervalSince(last) > age { refresh() }
    }

    func refresh() {
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
