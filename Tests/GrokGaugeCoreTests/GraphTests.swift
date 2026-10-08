import Foundation
import Testing
@testable import GrokGaugeCore

/// Settings exactly as GrokGauge 0.9.0 saved them (no graph keys).
let settingsFrom090 = """
{"actions":[{"id":"openGrok","visible":true},{"id":"openGrokBot","visible":true},{"id":"openX","visible":true}],
 "checkForUpdates":true,"colors":{},"hideLogo":false,
 "hotKey":{"command":false,"control":true,"enabled":true,"keyCode":5,"option":true,"shift":false},
 "menuBarMode":"highest","modifiedAt":"2026-10-08T19:08:50.409Z",
 "notificationThresholds":{"criticalAbove":90,"warningAbove":80},"notificationsLinked":true,"refreshInterval":15,
 "ringStyle":"sideBySide",
 "sections":[{"id":"grokRing","visible":true},{"id":"grokBotRing","visible":true},{"id":"historyPace","visible":true},
   {"id":"resetDates","visible":true},{"id":"productBreakdown","visible":true},{"id":"credits","visible":false},
   {"id":"refreshRow","visible":true},{"id":"actions","visible":true}],
 "showDaysToReset":true,"thresholds":{"criticalAbove":80,"warningAbove":50}}
"""

func decodeSettings(_ json: String) throws -> GaugeSettings {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601WithFractionalSeconds
    return try d.decode(GaugeSettings.self, from: Data(json.utf8))
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let d = ISODate.parse(s) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: s)) }
            return d
        }
    }
}

@Suite struct GraphSettingsTests {
    @Test func defaultsAreBarsWithBothGraphs() {
        let s = GaugeSettings()
        #expect(s.graphStyle == .bars)
        #expect(s.showGrokHistory && s.showGrokBotHistory)
        #expect(s.showsHistorySection)
    }

    @Test func migratesSettingsSavedBy090() throws {
        let s = try decodeSettings(settingsFrom090)
        #expect(s.graphStyle == .bars)
        #expect(s.showGrokHistory && s.showGrokBotHistory)
        // Everything else the user chose survives.
        #expect(s.thresholds == LevelThresholds(warningAbove: 50, criticalAbove: 80))
        #expect(s.showDaysToReset)
        #expect(!s.isVisible(.credits))
        #expect(s.hotKey.keyCode == 5 && s.hotKey.control && s.hotKey.option)
    }

    @Test func roundTripsAndToleratesUnknownStyles() throws {
        var s = GaugeSettings()
        s.graphStyle = .area
        s.showGrokBotHistory = false
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(GaugeSettings.self, from: data)
        #expect(back.graphStyle == .area)
        #expect(back.showGrokHistory && !back.showGrokBotHistory)
        #expect(back.sameContent(as: s))

        let future = settingsFrom090.replacingOccurrences(of: #""ringStyle":"sideBySide","#,
                                                          with: #""ringStyle":"sideBySide","graphStyle":"heatmap","showGrokHistory":"yes","#)
        let tolerant = try decodeSettings(future)
        #expect(tolerant.graphStyle == .bars)          // unknown value from a newer version: default
        #expect(tolerant.showGrokHistory)               // wrong type: default
    }

    @Test func hidingBothGraphsHidesTheSection() {
        var s = GaugeSettings()
        s.showGrokHistory = false
        #expect(s.showsHistorySection)
        s.showGrokBotHistory = false
        #expect(!s.showsHistorySection)
        s.showGrokHistory = true
        s.sections = s.sections.map { var i = $0; if i.id == .historyPace { i.visible = false }; return i }
        #expect(!s.showsHistorySection)                 // the section's own checkbox still works
    }

    @Test func resetLayoutRestoresGraphs() {
        var s = GaugeSettings()
        s.graphStyle = .line
        s.showGrokHistory = false
        s.showGrokBotHistory = false
        s.resetLayout()
        #expect(s.graphStyle == .bars && s.showGrokHistory && s.showGrokBotHistory)
    }

    @Test func everyStyleHasALabelForVoiceOver() {
        let titles = GraphStyle.allCases.map { $0.title }
        #expect(titles == ["Bars", "Line", "Area"])
        #expect(GraphStyle.allCases.allSatisfy { !$0.accessibilityDescription.isEmpty })
    }
}

@Suite struct DailyUsageTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        return c
    }
    /// Thu Oct 8 2026, 9:30 AM HST.
    let now = ISODate.parse("2026-10-08T19:30:00Z")!

    func at(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func onePeakPerDayEndingToday() {
        let samples = [UsageSample(t: at(1, 10), p: 5),           // outside the 7 days (Fri Oct 2..Thu Oct 8)
                       UsageSample(t: at(6, 9), p: 40), UsageSample(t: at(6, 20), p: 52),
                       UsageSample(t: at(7, 8), p: 55), UsageSample(t: at(7, 23), p: 61),
                       UsageSample(t: at(8, 7), p: 63)]
        let days = DailyUsage.aggregate(samples, days: 7, now: now, calendar: cal)
        #expect(days.count == 7)
        #expect(days.first?.day == at(2, 0))
        #expect(days.last?.day == at(8, 0))
        let peaks = days.map { $0.peak }
        let today = days.map { $0.isToday }
        #expect(peaks == [nil, nil, nil, nil, 52, 61, 63])
        #expect(today == [false, false, false, false, false, false, true])
        #expect(days.allSatisfy { !$0.reset })
    }

    @Test func resetDayShowsThePeakReachedThatDayAndIsMarked() {
        // Tue Oct 6: 92% in the morning, weekly reset at 10:57, then 3% by evening.
        let samples = [UsageSample(t: at(5, 18), p: 88), UsageSample(t: at(6, 9), p: 92),
                       UsageSample(t: at(6, 12), p: 1), UsageSample(t: at(6, 21), p: 3),
                       UsageSample(t: at(7, 12), p: 9)]
        let days = DailyUsage.aggregate(samples, days: 7, now: now, calendar: cal)
        let tue = days.first { $0.day == at(6, 0) }!
        #expect(tue.peak == 92)
        #expect(tue.reset)
        let resetDays = days.filter { $0.reset }.count
        #expect(resetDays == 1)
        #expect(days.first { $0.day == at(7, 0) }?.peak == 9)
    }

    @Test func knownResetIsMarkedEvenWithoutADrop() {
        let days = DailyUsage.aggregate([UsageSample(t: at(7, 9), p: 2)], days: 7, now: now,
                                        knownResets: [at(6, 10)], calendar: cal)
        #expect(days.first { $0.day == at(6, 0) }?.reset == true)
        #expect(days.first { $0.day == at(6, 0) }?.peak == nil)
    }

    @Test func smallWobbleIsNotAReset() {
        let samples = [UsageSample(t: at(7, 9), p: 20.4), UsageSample(t: at(7, 10), p: 19.9)]
        #expect(!DailyUsage.aggregate(samples, days: 7, now: now, calendar: cal).contains { $0.reset })
    }

    @Test func historyIncludesTheLiveReadingForToday() {
        var h = UsageHistory()
        h.record(.grok, percent: 10, at: at(8, 6))
        let days = h.daily(.grok, now: now, current: 14.2, calendar: cal)
        #expect(days.last?.peak == 14.2)
        #expect(days.last?.roundedPeak == 14)
        #expect(h.daily(.grokBot, now: now, calendar: cal).allSatisfy { $0.peak == nil })
    }
}

@Suite struct ReadingTimeTests {
    let locale = Locale(identifier: "en_US")
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        return c
    }

    @Test func todayShowsOnlyTheTime() {
        let now = ISODate.parse("2026-10-08T19:30:00Z")!          // Thu 9:30 AM HST
        let read = ISODate.parse("2026-10-08T19:10:25Z")!         // Thu 9:10 AM HST
        let s = UsageFormat.readingTime(read, now: now, calendar: cal, locale: locale)
        #expect(s.contains("9:10"))
        #expect(!s.contains("Oct"))
    }

    @Test func earlierDayShowsTheDate() {
        let now = ISODate.parse("2026-10-08T19:03:00Z")!          // Thu 9:03 AM HST
        let read = ISODate.parse("2026-10-08T03:38:00Z")!         // Wed Oct 7, 5:38 PM HST
        let s = UsageFormat.readingTime(read, now: now, calendar: cal, locale: locale)
        #expect(s.contains("Oct 7"))
        #expect(s.contains("5:38"))
    }

    @Test func staleOnlyAfterGrokBotsOwnExpiry() {
        // The 2026-10-08 case: read Wed 5:38 PM, Grok Bot's cache expires 24 h later.
        let read = ISODate.parse("2026-10-08T03:38:00Z")!
        let s = GrokBotSnapshot(percent: 14.15, nextReset: ISODate.parse("2026-10-14T17:35:42Z"),
                                readAt: read, expiresAt: read.addingTimeInterval(86_400))
        #expect(!s.isStale(now: ISODate.parse("2026-10-08T19:03:00Z")!))   // 15.5 h old: not stale yet
        #expect(s.isStale(now: read.addingTimeInterval(86_400)))
    }
}
