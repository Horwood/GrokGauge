import AppKit
import GrokGaugeCore

/// Checks GitHub's "latest release" for stevencombs/GrokGauge once a day (if enabled).
/// Unauthenticated, sends nothing but a User-Agent. Never installs anything.
@MainActor
final class UpdateMonitor: ObservableObject {
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false

    private let defaults: UserDefaults
    private let persist: Bool
    private var timer: Timer?
    private var enabled = false
    static let lastCheckKey = "updates.lastCheck"
    static let interval: TimeInterval = 24 * 3600

    init(defaults: UserDefaults = .standard, persist: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        if persist { lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date }
    }

    static func preview(available: ReleaseInfo?, lastChecked: Date?) -> UpdateMonitor {
        let m = UpdateMonitor(persist: false)
        m.available = available
        m.lastChecked = lastChecked
        return m
    }

    func setEnabled(_ on: Bool) {
        guard persist else { return }
        enabled = on
        timer?.invalidate()
        timer = nil
        guard on else { available = nil; return }
        // Wake up hourly; only actually ask GitHub when the last check is a day old.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer?.tolerance = 600
        // Don't hit the network in the first seconds after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    func checkIfDue() {
        guard enabled else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.interval { return }
        checkNow()
    }

    func checkNow() {
        guard persist, !isChecking else { return }
        isChecking = true
        Task {
            do {
                let latest = try await UpdateCheck.fetchLatest(appVersion: AppInfo.version)
                if let latest, UpdateCheck.isNewer(latest.tag, than: AppInfo.version) {
                    available = latest
                } else {
                    available = nil
                }
                lastError = latest == nil ? "GitHub didn't return a release" : nil
            } catch {
                lastError = "Couldn't reach GitHub"
            }
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckKey)
            isChecking = false
        }
    }

    static func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateCheck.brewUpgradeCommand, forType: .string)
    }
}
