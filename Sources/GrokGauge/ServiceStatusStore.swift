import AppKit
import Combine
import GrokGaugeCore

/// Checks the xAI and Cursor public status pages: about every 5 minutes (backing off after failures) and when
/// the dropdown opens (at most every 30 s). Public pages only: no login, cookies, or anything about the user.
@MainActor
final class ServiceStatusStore: ObservableObject {
    struct SourceState: Equatable {
        /// The last successful reading.
        var report: ServiceStatusReport?
        /// The current failure, if the last check failed (the dot is gray then).
        var lastError: String?
        var lastErrorAt: Date?
        /// Set when the summary failed and the RSS fallback answered.
        var fallbackReason: String?
        var lastAttempt: Date?
        var failures = 0
        var lastURL: URL?

        /// What the dot shows: gray when the last check failed or nothing has been read yet.
        var health: ServiceHealth { lastError == nil ? (report?.health ?? .unknown) : .unknown }
    }

    @Published private(set) var states: [ServiceSource: SourceState] = [:]
    private var checking: Set<ServiceSource> = []
    private let fetcher: ServiceStatusFetcher?
    private let settings: () -> ServiceStatusSettings
    private let notify: ((ServiceStatusReport) -> Void)?
    private var timer: Timer?

    init(fetcher: ServiceStatusFetcher? = ServiceStatusFetcher(appVersion: AppInfo.version),
         settings: @escaping () -> ServiceStatusSettings = { .standard },
         notify: ((ServiceStatusReport) -> Void)? = nil) {
        self.fetcher = fetcher
        self.settings = settings
        self.notify = notify
    }

    /// Fixed states for --render-preview (never fetches).
    static func preview(_ states: [ServiceSource: SourceState]) -> ServiceStatusStore {
        let s = ServiceStatusStore(fetcher: nil)
        s.states = states
        return s
    }

    func state(_ s: ServiceSource) -> SourceState { states[s] ?? SourceState() }

    /// One live check of each source, for `--print-status` and real-data `--render-preview` (never starts the timer).
    static func fetchedOnce(_ sources: [ServiceSource] = ServiceSource.allCases,
                            fetcher: ServiceStatusFetcher = ServiceStatusFetcher(appVersion: AppInfo.version)) async -> ServiceStatusStore {
        var states: [ServiceSource: SourceState] = [:]
        for source in sources {
            let now = Date()
            var st = SourceState(lastAttempt: now)
            do {
                let r = try await fetcher.fetch(source, now: now)
                st.report = r.report
                st.fallbackReason = r.primaryError
                st.lastURL = r.report.via
            } catch {
                st.lastError = (error as? ServiceStatusError)?.message ?? error.localizedDescription
                st.lastErrorAt = now
                st.failures = 1
                st.lastURL = source.fallbackURL ?? source.summaryURL
            }
            states[source] = st
        }
        return preview(states)
    }

    /// Fixed sample readings for --render-preview --demo.
    static func demo(xai: ServiceStatusReport? = nil, cursor: ServiceStatusReport? = nil) -> ServiceStatusStore {
        let now = Date().addingTimeInterval(-60)
        func st(_ r: ServiceStatusReport) -> SourceState { SourceState(report: r, lastAttempt: now, lastURL: r.via) }
        return preview([
            .xai: st(xai ?? ServiceStatusReport(source: .xai, health: .normal, via: ServiceSource.xai.summaryURL, checkedAt: now)),
            .cursor: st(cursor ?? ServiceStatusReport(source: .cursor, health: .normal, via: ServiceSource.cursor.summaryURL, checkedAt: now)),
        ])
    }

    func start() {
        guard fetcher != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDue() }
        }
        timer?.tolerance = 15
    }

    /// Checks the enabled sources whose next check (5 min, or the backoff) has come.
    func checkDue(now: Date = Date()) {
        for s in settings().enabled where now >= ServiceStatusSchedule.nextCheck(lastAttempt: state(s).lastAttempt, failures: state(s).failures) {
            check(s)
        }
    }

    /// The dropdown opened: re-check anything older than 30 s.
    func refreshIfStale(now: Date = Date()) {
        for s in settings().enabled {
            let last = state(s).lastAttempt ?? .distantPast
            if now.timeIntervalSince(last) >= ServiceStatusSchedule.openThrottle { check(s) }
        }
    }

    func checkNow() { settings().enabled.forEach(check) }

    private func check(_ source: ServiceSource) {
        guard let fetcher, !checking.contains(source) else { return }
        checking.insert(source)
        var st = state(source)
        st.lastAttempt = Date()
        states[source] = st
        Task {
            var st = state(source)
            let previous = st.lastError == nil ? st.report?.health : nil
            do {
                let r = try await fetcher.fetch(source)
                st.report = r.report
                st.lastError = nil
                st.lastErrorAt = nil
                st.fallbackReason = r.primaryError
                st.failures = 0
                st.lastURL = r.report.via
                if settings().notify, ServiceStatusSchedule.shouldNotify(previous: previous, current: r.report.health) {
                    notify?(r.report)
                }
            } catch {
                st.lastError = (error as? ServiceStatusError)?.message ?? "Unexpected error"
                st.lastErrorAt = Date()
                st.failures += 1
                st.lastURL = source.fallbackURL ?? source.summaryURL
            }
            states[source] = st
            checking.remove(source)
        }
    }

    func open(_ source: ServiceSource) { NSWorkspace.shared.open(source.pageURL) }

    /// For the tooltip and VoiceOver: the full detail and when it was checked.
    func detail(_ source: ServiceSource) -> String {
        let st = state(source)
        var lines: [String] = []
        if let e = st.lastError {
            lines.append("\(source.title): couldn't check (\(e))")
            if let r = st.report { lines.append("Last known: \(r.summary) at \(Self.time(r.checkedAt))") }
        } else if let r = st.report {
            lines.append(r.line)
            if r.affected.count > 2 { lines.append("Affected: \(r.affected.joined(separator: ", "))") }
            if let d = r.pageDescription, r.health != .normal { lines.append(d) }
            if !r.incidents.isEmpty { lines.append("Incidents: \(r.incidents.prefix(3).joined(separator: "; "))") }
            lines.append("Checked \(Self.time(r.checkedAt))")
        } else {
            lines.append("\(source.title): checking…")
        }
        lines.append("Click to open \(source.pageURL.host ?? "")")
        return lines.joined(separator: "\n")
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// Diagnostics rows (no tokens or user data: these are public pages).
    func diagnostics() -> [SourceDiagnostics] {
        ServiceSource.allCases.map { s in
            let st = state(s)
            let on = settings().isOn(s)
            var status = !on ? "Off" : st.lastError != nil ? "Failed" : st.report?.summary ?? "Not checked yet"
            if on, st.lastError == nil, st.fallbackReason != nil { status += " (via RSS)" }
            return SourceDiagnostics(name: "\(s.title) status", status: status, lastSuccess: st.report?.checkedAt,
                                     lastError: st.lastError ?? st.fallbackReason.map { "Summary failed (\($0)); used RSS feed" },
                                     lastErrorAt: st.lastErrorAt ?? (st.fallbackReason != nil ? st.report?.checkedAt : nil))
        }
    }
}
