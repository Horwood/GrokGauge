import Foundation
import Testing
@testable import GrokGaugeCore

/// The pace warning should follow what the pool is doing now, not the average since Monday.
@Suite struct BurnTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var end: Date { start.addingTimeInterval(7 * 86_400) }

    func sample(_ hoursFromStart: Double, _ percent: Double, share: Bool? = nil) -> UsageSample {
        UsageSample(t: start.addingTimeInterval(hoursFromStart * 3600), p: percent, s: share)
    }

    @Test func aFinishedMondayDoesNotKeepWarning() {
        // 60% by Monday noon, then flat through Thursday.
        let now = start.addingTimeInterval(4 * 86_400)
        var h = UsageHistory()
        h.grok = [sample(6, 40), sample(12, 60), sample(4 * 24 - 20, 60), sample(4 * 24 - 4, 60)]
        let recent = Burn.recent(history: h, periodStart: start, now: now, current: 60)
        #expect(recent?.climbed == 0)
        let withHistory = Pace.project(percent: 60, periodStart: start, periodEnd: end, now: now, recent: recent)
        guard case .onTrack = withHistory else { Issue.record("flat week should be on track, got \(withHistory)"); return }
        // The old average still thinks Thursday is a crisis.
        guard case .runsOut = Pace.project(percent: 60, periodStart: start, periodEnd: end, now: now) else {
            Issue.record("week average should still run out"); return
        }
    }

    @Test func aLateBingeShowsUpTheSameDay() {
        // 12% all week, then 12 → 42 over Friday.
        let now = start.addingTimeInterval(4.5 * 86_400)
        var h = UsageHistory()
        h.grok = [sample(24, 10), sample(48, 12), sample(4.5 * 24 - 30, 12), sample(4.5 * 24 - 8, 18)]
        let recent = Burn.recent(history: h, periodStart: start, now: now, current: 42)
        #expect(recent != nil)
        #expect((recent?.climbed ?? 0) > 20)
        guard case .runsOut = Pace.project(percent: 42, periodStart: start, periodEnd: end, now: now, recent: recent) else {
            Issue.record("the binge should run out"); return
        }
        guard case .onTrack = Pace.project(percent: 42, periodStart: start, periodEnd: end, now: now) else {
            Issue.record("the week average should still be on track"); return
        }
    }

    @Test func aResetInsideTheWindowIsNotNegativeBurn() {
        let now = start.addingTimeInterval(5 * 86_400)
        var h = UsageHistory()
        h.grok = [
            sample(5 * 24 - 30, 88),
            sample(5 * 24 - 28, 6),
            sample(5 * 24 - 4, 10),
        ]
        let recent = Burn.recent(history: h, periodStart: start, now: now, current: 11)
        #expect(abs((recent?.climbed ?? -1) - 5) < 0.001)   // 6% → 11%, not 88% → 11%
        #expect((recent?.perSecond ?? -1) > 0)
    }

    @Test func twoCloseReadingsAreNotASlope() {
        let now = start.addingTimeInterval(2 * 86_400)
        var h = UsageHistory()
        h.grok = [sample(2 * 24 - 1, 20)]
        #expect(Burn.recent(history: h, periodStart: start, now: now, current: 22) == nil)
    }

    @Test func namesTheSliceThatDidMostOfIt() {
        let now = start.addingTimeInterval(3 * 86_400)
        var h = UsageHistory()
        h.grok = [sample(3 * 24 - 12, 20), sample(3 * 24, 50)]
        h.grokBot = [sample(3 * 24 - 12, 4, share: true), sample(3 * 24, 22, share: true)]
        h.cursor = [sample(3 * 24 - 12, 1), sample(3 * 24, 4)]
        let recent = Burn.recent(history: h, periodStart: start, now: now)
        #expect(recent?.leader == "Grok Bot")
        #expect(abs((recent?.grokBot ?? 0) - 18.0 / 30.0) < 0.001)
        #expect(recent?.grok != nil)
    }

    @Test func anOwnAllowanceIsNotASliceOfThePool() {
        let now = start.addingTimeInterval(3 * 86_400)
        var h = UsageHistory()
        h.grok = [sample(3 * 24 - 12, 20), sample(3 * 24, 50)]
        // Same numbers, but this is Grok Bot's own meter, not its share.
        h.grokBot = [sample(3 * 24 - 12, 4, share: false), sample(3 * 24, 22, share: false)]
        h.cursor = [sample(3 * 24 - 12, 1), sample(3 * 24, 4)]
        let recent = Burn.recent(history: h, periodStart: start, now: now)
        #expect(recent?.grokBot == nil)
        #expect(recent?.leader == nil)
    }

    @Test func aSliceThatOutrunsThePoolIsDropped() {
        let now = start.addingTimeInterval(3 * 86_400)
        var h = UsageHistory()
        h.grok = [sample(3 * 24 - 12, 40), sample(3 * 24, 50)]
        h.grokBot = [sample(3 * 24 - 12, 5, share: true), sample(3 * 24, 50, share: true)]
        #expect(Burn.recent(history: h, periodStart: start, now: now)?.grokBot == nil)
    }

    @Test func warningNamesTheLeader() {
        var status = PaceStatus.runsOut(at: start.addingTimeInterval(86_400))
        let w = Pace.warning(status, cause: "Grok Bot", now: start, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))
        #expect(w?.detail.contains("mostly Grok Bot") == true)
        #expect(w?.sentence.contains("mostly Grok Bot") == true)
        status = .onTrack(projected: 40)
        #expect(Pace.warning(status, cause: "Grok Bot") == nil)
    }
}
