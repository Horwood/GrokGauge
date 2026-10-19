import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct SharedPoolTests {
    let now = Date(timeIntervalSince1970: 1_792_442_000)   // Oct 19 2026
    var end: Date { Date(timeIntervalSince1970: 1_792_655_700) }   // 2026-10-22T07:55Z

    func pool(_ percent: Double, end: Date? = nil, products: [(String, Double)] = [("GrokChat", 5), ("GrokImagine", 2), ("GrokBot", 21), ("Cursor", 5)]) -> UsageSnapshot {
        let e = end ?? self.end
        return UsageSnapshot(percent: percent, percentInferred: false, period: .weekly,
                             periodStart: e.addingTimeInterval(-7 * 86_400), periodEnd: e,
                             products: products.map { ProductShare(key: $0.0, name: UsageParser.displayName(for: $0.0), symbol: "x", percent: $0.1) },
                             prepaidBalanceCents: 0, onDemandUsedCents: 0, onDemandCapCents: 0, fetchedAt: now)
    }

    func bot(_ percent: Double, reset: Date?) -> GrokBotSnapshot {
        GrokBotSnapshot(percent: percent, nextReset: reset, readAt: now.addingTimeInterval(-60), expiresAt: nil)
    }

    @Test func detectsSharedPool() {
        // Oct 19 live data: Grok Bot reports 33.7% with the pool's reset minute; the pool is 33%.
        let r = BotRingReading.make(bot: bot(33.7, reset: end.addingTimeInterval(30)), pool: pool(33), knownSharedEnd: nil)
        #expect(r.isShared)
        #expect(r.percent == 21)
        #expect(r.roundedPercent == 21)
        #expect(r.nextReset == end)
        #expect(r.periodKey.hasPrefix("botshare-"))
        #expect(r.own.roundedPercent == 34)
    }

    @Test func separateWhenResetDiffers() {
        let r = BotRingReading.make(bot: bot(33.7, reset: end.addingTimeInterval(3 * 3600)), pool: pool(33), knownSharedEnd: nil)
        #expect(!r.isShared)
        #expect(r.percent == 33.7)
        #expect(r.periodKey.hasPrefix("bot-"))
    }

    @Test func separateWhenPercentsDiffer() {
        let r = BotRingReading.make(bot: bot(12, reset: end), pool: pool(33), knownSharedEnd: nil)
        #expect(!r.isShared)
        #expect(r.percent == 12)
    }

    @Test func stickyWithinAKnownSharedWeek() {
        // Readings a few minutes apart can drift; a week already known as shared stays shared.
        #expect(!PoolSharing.isShared(bot: bot(37, reset: end), pool: pool(33)))
        #expect(PoolSharing.isShared(bot: bot(37, reset: end), pool: pool(33), knownSharedEnd: end))
        #expect(!PoolSharing.isShared(bot: bot(60, reset: end), pool: pool(33), knownSharedEnd: end))
    }

    @Test func missingBotProductMeansZeroShare() {
        let r = BotRingReading.make(bot: bot(5, reset: end), pool: pool(5, products: [("GrokChat", 5)]), knownSharedEnd: nil)
        #expect(r.isShared && r.percent == 0)
    }

    @Test func waitsForShareWhilePoolLoads() {
        let loading = BotRingReading.make(bot: bot(33.7, reset: end), pool: nil, knownSharedEnd: end, poolLoading: true)
        #expect(loading.isShared && loading.percent == nil)
        // Grok not signed in: show Grok Bot's own reading rather than waiting forever.
        let failed = BotRingReading.make(bot: bot(33.7, reset: end), pool: nil, knownSharedEnd: end, poolLoading: false)
        #expect(!failed.isShared && failed.percent == 33.7)
    }

    @Test func cursorShare() {
        #expect(PoolSharing.cursorShare(in: pool(33))?.percent == 5)
        #expect(PoolSharing.cursorShare(in: pool(33, products: [("GrokChat", 5)])) == nil)
        #expect(PoolSharing.botShare(in: pool(33))?.name == "Grok Bot")
    }

    @Test func renamesBotProductRow() {
        let s = ProductBreakdownSettings(order: [ProductToggle("Chat"), ProductToggle("Bot", visible: false)])
        #expect(s.order.contains(ProductToggle("Grok Bot", visible: false)))
        #expect(!s.order.contains { $0.id == "Bot" })
    }

    @Test func ringWidthAndSize() {
        #expect(PopoverLayout.width(ringCount: 2, sideBySide: true, sizing: .keepSize) == 320)
        #expect(PopoverLayout.width(ringCount: 3, sideBySide: true, sizing: .keepSize) > 320)
        #expect(PopoverLayout.width(ringCount: 3, sideBySide: true, sizing: .fitWidth) == 320)
        #expect(PopoverLayout.width(ringCount: 3, sideBySide: false, sizing: .keepSize) == 320)
        #expect(PopoverLayout.ringDiameter(ringCount: 3, sizing: .fitWidth) < PopoverLayout.ringDiameter(ringCount: 3, sizing: .keepSize))
        #expect(PopoverLayout.ringDiameter(ringCount: 2, sizing: .fitWidth) == 104)
    }

    @Test func cursorRingSettingRoundTripsAndOldFilesKeepItOff() throws {
        var s = GaugeSettings()
        if let i = s.sections.firstIndex(where: { $0.id == .cursorRing }) { s.sections[i].visible = true }
        s.ringSizing = .fitWidth
        let back = try SettingsSync.decode(SettingsSync.encode(s))
        #expect(back.isVisible(.cursorRing) && back.ringSizing == .fitWidth)
        // A 0.9.2 file has no cursorRing entry: it's added, switched off.
        let old = """
        {"app":"GrokGauge","schema":1,"settings":{"sections":[{"id":"grokRing","visible":true},{"id":"grokBotRing","visible":true}],"modifiedAt":"2026-10-17T22:58:20.036Z"}}
        """
        let o = try SettingsSync.decode(Data(old.utf8))
        #expect(!o.isVisible(.cursorRing))
        #expect(o.sections.map(\.id).prefix(3) == [.grokRing, .grokBotRing, .cursorRing])
    }
}

@Suite struct SharedHistoryTests {
    let now = Date(timeIntervalSince1970: 1_792_442_000)
    func t(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

    @Test func switchToShareIsNotAReset() {
        var h = UsageHistory()
        h.record(.grokBot, percent: 33, at: t(5))             // 0.9.2: whole pool, untagged
        h.record(.grokBot, percent: 34, at: t(3), shared: false)
        h.record(.grokBot, percent: 21, at: t(1), shared: true)
        h.record(.grokBot, percent: 22, at: t(0.1), shared: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let days = h.daily(.grokBot, now: now, calendar: cal)
        #expect(!days.contains { $0.reset })
    }

    @Test func oldFilesWithoutCursorStillDecode() throws {
        let json = #"{"schema":1,"grok":[{"t":1792440000,"p":30}],"grokBot":[{"t":1792440000,"p":31}]}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let h = try d.decode(UsageHistory.self, from: Data(json.utf8))
        #expect(h.grok.count == 1 && h.grokBot.count == 1 && h.cursor.isEmpty)
        let file = #"{"app":"GrokGauge","kind":"usageHistory","schema":1,"machineID":"a","machineName":"Air","updatedAt":1792440000,"grok":[],"grokBot":[{"t":1792440000,"p":31}]}"#
        let f = try HistorySync.decode(Data(file.utf8))
        #expect(f.cursor == nil && f.history.cursor.isEmpty)
    }

    @Test func cursorSamplesRoundTripThroughSyncFile() throws {
        var h = UsageHistory()
        h.record(.cursor, percent: 5, at: t(1))
        h.record(.grokBot, percent: 21, at: t(1), shared: true)
        let f = MachineHistoryFile(machineID: "a", machineName: "Air", updatedAt: now, history: h)
        let back = try HistorySync.decode(HistorySync.encode(f))
        #expect(back.history.cursor.map(\.p) == [5])
        #expect(back.history.grokBot.first?.s == true)
    }

    @Test func mergeDropsOldStyleSamplesAfterTheSwitch() {
        var newer = UsageHistory()
        newer.record(.grokBot, percent: 21, at: t(2), shared: true)
        newer.record(.grokBot, percent: 22, at: t(0.5), shared: true)
        var older = UsageHistory()    // a Mac still on 0.9.2: whole pool, untagged
        older.record(.grokBot, percent: 30, at: t(6))
        older.record(.grokBot, percent: 33, at: t(1))
        let m = HistorySync.merge(local: newer, others: [older], now: now)
        #expect(m.grokBot.map(\.p) == [30, 21, 22])
    }

    @Test func historyFolderCandidates() {
        let a = URL(fileURLWithPath: "/tmp/Drive/MacSyncing/xAI", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/Drive/MacSyncing", isDirectory: true)
        let both = HistorySyncFolder.candidates(chosen: nil, settingsSync: a, detected: b)
        #expect(both.map(\.url) == [a, b])
        #expect(both.first?.origin == .settingsSync)
        #expect(HistorySyncFolder.candidates(chosen: nil, settingsSync: b, detected: b).count == 1)
        #expect(HistorySyncFolder.candidates(chosen: a, settingsSync: b, detected: b).map(\.origin) == [.chosen])
        #expect(HistorySyncFolder.candidates(chosen: nil, settingsSync: nil, detected: nil).isEmpty)
    }
}
