import Foundation
import GrokGaugeCore

/// Local 7-day usage samples for the sparklines. Lives in Application Support; never synced.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var history: UsageHistory
    private let url: URL?
    private var pendingSave: DispatchWorkItem?

    init(url: URL? = UsageHistory.defaultURL) {
        self.url = url
        var h = url.map { UsageHistory.load(from: $0) } ?? UsageHistory()
        h.prune()
        history = h
    }

    static func preview(_ h: UsageHistory) -> HistoryStore {
        let s = HistoryStore(url: nil)
        s.history = h
        return s
    }

    func record(_ source: HistorySource, percent: Double, at time: Date) {
        var h = history
        h.record(source, percent: percent, at: time)
        h.prune()
        guard h != history else { return }
        history = h
        scheduleSave()
    }

    private func scheduleSave() {
        guard let url else { return }
        pendingSave?.cancel()
        let snapshot = history
        let work = DispatchWorkItem { try? snapshot.save(to: url) }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Synthetic week for --render-preview --demo.
    static func demoHistory(grokNow: Double, botNow: Double, now: Date = Date()) -> UsageHistory {
        var h = UsageHistory()
        let start = now.addingTimeInterval(-7 * 86_400)
        for i in 0...56 {
            let t = start.addingTimeInterval(Double(i) * 3 * 3600)
            let f = Double(i) / 56
            // Grok: resets ~4.2 days ago, then climbs. Grok Bot: steady climb with a busy evening.
            let grokReset = now.addingTimeInterval(-4.2 * 86_400)
            let g: Double = t < grokReset
                ? 55 + 35 * (t.timeIntervalSince(start) / grokReset.timeIntervalSince(start))
                : grokNow * pow(t.timeIntervalSince(grokReset) / now.timeIntervalSince(grokReset), 0.9)
            // Usage only rises within a week, so the wobble never takes a value below the previous one
            // (a drop would read as a reset).
            let wobble = sin(Double(i) * 0.9) * 2.5
            let previousGrok = h.grok.last.flatMap { ($0.t < grokReset) == (t < grokReset) ? $0.p : nil } ?? 0
            h.record(.grok, percent: max(previousGrok, g + wobble * 0.4), at: t)
            h.record(.grokBot, percent: max(h.grokBot.last?.p ?? 0, botNow * pow(f, 1.15) + wobble), at: t)
        }
        h.record(.grok, percent: grokNow, at: now)
        h.record(.grokBot, percent: botNow, at: now)
        return h
    }
}
