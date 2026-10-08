import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct SettingsModelTests {
    @Test func defaultsMatchSpec() {
        let s = GaugeSettings()
        #expect(s.sections.map(\.id) == DropdownSection.allCases)
        #expect(s.sections.allSatisfy { $0.visible })
        #expect(s.actions.map(\.id) == [.openGrok, .openGrokBot, .openX])
        #expect(s.actions.allSatisfy { $0.visible })      // Open X shown by default
        #expect(s.ringStyle == .sideBySide)
        #expect(s.menuBarMode == .highest)
        #expect(!s.showDaysToReset && !s.hideLogo)
        #expect(s.thresholds == LevelThresholds(warningAbove: 80, criticalAbove: 90))
        #expect(s.colors == .system)
        #expect(s.notificationsLinked)
        #expect(s.refreshInterval == .fifteen)
        #expect(s.checkForUpdates)
        #expect(s.hotKey.display == "⌃⌥G")
        #expect(s.hotKey.carbonModifiers == 0x1000 | 0x800)
    }

    @Test func migratesFrom03() {
        #expect(GaugeSettings.migratingFrom03(menuBarStyle: nil) == GaugeSettings())
        #expect(GaugeSettings.migratingFrom03(menuBarStyle: "both").menuBarMode == .both)
        #expect(GaugeSettings.migratingFrom03(menuBarStyle: "highest").menuBarMode == .highest)
        #expect(GaugeSettings.migratingFrom03(menuBarStyle: "garbage").menuBarMode == .highest)
        // 0.3 colors were system green/orange/red at 80/90: the defaults keep that exactly.
        let m = GaugeSettings.migratingFrom03(menuBarStyle: "both")
        #expect(m.thresholds.level(forRoundedPercent: 80) == UsageLevel.forPercent(80))
        #expect(m.thresholds.level(forRoundedPercent: 81) == UsageLevel.forPercent(81))
        #expect(m.thresholds.level(forRoundedPercent: 91) == UsageLevel.forPercent(91))
    }

    @Test func roundTripsThroughJSON() throws {
        var s = GaugeSettings()
        s.ringStyle = .stacked
        s.sections.swapAt(0, 3)
        s.sections[1].visible = false
        s.actions.reverse()
        s.colors = .colorblindFriendly
        s.thresholds.setWarning(60)
        s.notificationsLinked = false
        s.hotKey = HotKey(keyCode: 15, command: true, shift: true)
        s.modifiedAt = Date(timeIntervalSince1970: 1_791_430_000.123)
        let back = try SettingsSync.decode(SettingsSync.encode(s))
        #expect(back.sameContent(as: s))
        #expect(abs(back.modifiedAt.timeIntervalSince(s.modifiedAt)) < 0.002)
    }

    @Test func toleratesPartialAndFutureFiles() throws {
        // Older file without most keys, a section id from a future version, and a crossed threshold pair.
        let json = """
        {"app":"GrokGauge","schema":1,"settings":{
          "menuBarMode":"both",
          "sections":[{"id":"credits","visible":false},{"id":"weatherWidget"},{"id":"grokRing"},{"id":"credits"}],
          "thresholds":{"warningAbove":95,"criticalAbove":20},
          "colors":{"warning":"#E69F00"},
          "modifiedAt":"2026-10-08T03:00:00.000Z"}}
        """
        let s = try SettingsSync.decode(Data(json.utf8))
        #expect(s.menuBarMode == .both)
        #expect(s.sections.first?.id == .credits && s.sections.first?.visible == false)
        #expect(s.sections.count == DropdownSection.allCases.count)
        #expect(Set(s.sections.map(\.id)) == Set(DropdownSection.allCases))
        #expect(s.thresholds.warningAbove < s.thresholds.criticalAbove)
        #expect(s.colors.warning == RGBAColor(hex: "#E69F00"))
        #expect(s.colors.normal == nil)
        #expect(s.ringStyle == .sideBySide)
        #expect(s.refreshInterval == .fifteen)
    }

    @Test func sameContentIgnoresTimestamp() {
        var a = GaugeSettings(), b = GaugeSettings()
        a.modifiedAt = Date()
        #expect(a.sameContent(as: b))
        b.hideLogo = true
        #expect(!a.sameContent(as: b))
    }

    @Test func notificationThresholdsFollowColorsUntilUnlinked() {
        var s = GaugeSettings()
        s.thresholds.setWarning(70)
        #expect(s.effectiveNotificationThresholds.warningAbove == 70)
        s.notificationsLinked = false
        s.notificationThresholds.setCritical(95)
        #expect(s.effectiveNotificationThresholds == LevelThresholds(warningAbove: 80, criticalAbove: 95))
    }

    @Test func hotKeyDisplay() {
        #expect(HotKey(keyCode: 0, command: true, shift: true).display == "⇧⌘A")
        #expect(!HotKey(keyCode: 0, shift: true).isValid)
        #expect(HotKey(keyCode: 122, option: true).display == "⌥F1")
    }
}

@Suite struct ThresholdSliderTests {
    @Test func handlesPushEachOther() {
        var t = LevelThresholds.standard
        t.setWarning(95)                 // pushes critical up
        #expect(t.warningAbove == 95 && t.criticalAbove == 96)
        t.setCritical(40)                // pushes warning down
        #expect(t.criticalAbove == 40 && t.warningAbove == 39)
    }

    @Test func staysInBoundsAndApart() {
        var t = LevelThresholds.standard
        t.setWarning(150)
        #expect(t.warningAbove == 98 && t.criticalAbove == 99)
        t.setCritical(-5)
        #expect(t.warningAbove == 1 && t.criticalAbove == 2)
        t.setWarning(1)
        t.setCritical(2)
        #expect(t.criticalAbove - t.warningAbove >= LevelThresholds.minimumGap)
        // Every move keeps the invariant.
        for v in stride(from: -10, through: 110, by: 7) {
            t.setWarning(v)
            #expect(t.warningAbove < t.criticalAbove)
            t.setCritical(110 - v)
            #expect(t.warningAbove < t.criticalAbove)
            #expect(t.warningAbove >= 1 && t.criticalAbove <= 99)
        }
    }

    @Test func invalidValuesAreRepaired() {
        let t = LevelThresholds(warningAbove: 90, criticalAbove: 90)
        #expect(t.warningAbove == 90 && t.criticalAbove == 91)
    }

    @Test func levels() {
        let t = LevelThresholds(warningAbove: 50, criticalAbove: 75)
        #expect(t.level(forRoundedPercent: 50) == .normal)
        #expect(t.level(forRoundedPercent: 51) == .warning)
        #expect(t.level(forRoundedPercent: 75) == .warning)
        #expect(t.level(forRoundedPercent: 76) == .critical)
    }
}

@Suite struct ColorTests {
    @Test func hexRoundTrip() {
        #expect(RGBAColor(hex: "#0072B2")?.hex == "#0072B2")
        #expect(RGBAColor(hex: "ff000080")?.hex == "#FF000080")
        #expect(RGBAColor(hex: "#12345") == nil)
    }

    @Test func deltaE2000MatchesReferenceData() {
        // Sharma, Wu & Dalal (2005) test pairs.
        let pairs: [(ColorMath.Lab, ColorMath.Lab, Double)] = [
            (.init(l: 50, a: 2.6772, b: -79.7751), .init(l: 50, a: 0, b: -82.7485), 2.0425),
            (.init(l: 50, a: 2.5, b: 0), .init(l: 73, a: 25, b: -18), 27.1492),
            (.init(l: 60.2574, a: -34.0099, b: 36.2677), .init(l: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
        ]
        for (a, b, expected) in pairs {
            #expect(abs(ColorMath.deltaE2000(a, b) - expected) < 0.001)
        }
    }

    @Test func similarityWarnings() {
        #expect(LevelColors.system.similarPairs().isEmpty)
        #expect(LevelColors.colorblindFriendly.similarPairs().isEmpty)
        let close = LevelColors(normal: RGBAColor(hex: "#34C759"), warning: RGBAColor(hex: "#36C95C"),
                                critical: RGBAColor(hex: "#FF3B30"))
        let pairs = close.similarPairs()
        #expect(pairs.count == 1)
        #expect(pairs.first?.0 == .normal && pairs.first?.1 == .warning)
        let allSame = LevelColors(normal: RGBAColor(hex: "#FF0000"), warning: RGBAColor(hex: "#FE0101"),
                                  critical: RGBAColor(hex: "#FF0000"))
        #expect(allSame.similarPairs().count == 3)
        #expect(ColorMath.contrastRatio(RGBAColor(hex: "#000000")!, RGBAColor(hex: "#FFFFFF")!) > 20.9)
    }
}

@Suite struct SyncTests {
    func settings(_ t: TimeInterval, hideLogo: Bool = false) -> GaugeSettings {
        var s = GaugeSettings()
        s.hideLogo = hideLogo
        s.modifiedAt = Date(timeIntervalSince1970: t)
        return s
    }

    @Test func lastWriteWins() {
        let local = settings(1000)
        let newer = settings(2000, hideLogo: true)
        #expect(SettingsSync.resolve(local: local, remote: newer) == .adoptRemote(newer))
        #expect(SettingsSync.resolve(local: newer, remote: local) == .writeLocal)
        #expect(SettingsSync.resolve(local: local, remote: nil) == .writeLocal)
        #expect(SettingsSync.resolve(local: local, remote: settings(1000)) == .inSync)
        // Same timestamp but different content: keep (and publish) this Mac's copy.
        #expect(SettingsSync.resolve(local: local, remote: settings(1000, hideLogo: true)) == .writeLocal)
    }

    @Test func fileRoundTripIsAtomicAndPreferenceOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gg-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = SettingsSync.fileURL(inSyncFolder: dir)
        #expect(url.path.hasSuffix("GrokGauge/settings.json"))
        #expect(try SettingsSync.read(from: url) == nil)
        let s = settings(1_791_430_000.5, hideLogo: true)
        try SettingsSync.write(s, to: url)
        let back = try #require(try SettingsSync.read(from: url))
        #expect(back.sameContent(as: s))
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["token", "email", "auth.json", "creditusage", "samples"] {
            #expect(!text.lowercased().contains(forbidden))
        }
    }
}

@Suite struct PaceTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var end: Date { start.addingTimeInterval(7 * 86_400) }

    @Test func onTrack() {
        // 20% after 3.5 days -> 40% at reset.
        let s = Pace.project(percent: 20, periodStart: start, periodEnd: end, now: start.addingTimeInterval(3.5 * 86_400))
        guard case .onTrack(let p) = s else { Issue.record("expected onTrack, got \(s)"); return }
        #expect(abs(p - 40) < 0.001)
    }

    @Test func runsOutBeforeReset() {
        // 60% after 2 days -> 100% after 3.333 days.
        let now = start.addingTimeInterval(2 * 86_400)
        let s = Pace.project(percent: 60, periodStart: start, periodEnd: end, now: now)
        guard case .runsOut(let at) = s else { Issue.record("expected runsOut, got \(s)"); return }
        #expect(abs(at.timeIntervalSince(start) - (2 * 86_400 * 100 / 60)) < 1)
        #expect(Pace.describe(s).hasPrefix("At this pace you'll hit 100% by "))
    }

    @Test func edges() {
        #expect(Pace.project(percent: 5, periodStart: start, periodEnd: end, now: start.addingTimeInterval(600)) == .tooEarly)
        #expect(Pace.project(percent: 100, periodStart: start, periodEnd: end, now: start.addingTimeInterval(600)) == .exhausted)
        #expect(Pace.project(percent: 0, periodStart: start, periodEnd: end, now: start.addingTimeInterval(86_400)) == .onTrack(projected: 0))
        #expect(Pace.project(percent: 10, periodStart: end, periodEnd: start, now: start) == .tooEarly)
        #expect(Pace.weeklyStart(forReset: end) == start)
        #expect(Pace.describe(.onTrack(projected: 39.6)) == "On track (≈40% at reset)")
    }
}

@Suite struct HistoryTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func pruneDropsOldAndFutureSamplesAndCaps() {
        var h = UsageHistory()
        h.record(.grok, percent: 1, at: now.addingTimeInterval(-9 * 86_400))
        h.record(.grok, percent: 2, at: now.addingTimeInterval(-7.5 * 86_400))
        h.record(.grok, percent: 3, at: now.addingTimeInterval(-3600))
        h.record(.grok, percent: 4, at: now.addingTimeInterval(86_400))
        h.record(.grokBot, percent: 9, at: now.addingTimeInterval(-60))
        h.prune(now: now)
        #expect(h.grok.map(\.p) == [2, 3])
        #expect(h.grokBot.map(\.p) == [9])
        #expect(h.series(.grok, now: now).map(\.p) == [3])     // 7-day window

        var big = UsageHistory()
        for i in 0..<(UsageHistory.maxSamplesPerSource + 50) {
            big.record(.grok, percent: Double(i % 100), at: now.addingTimeInterval(Double(-i) * 60))
        }
        big.prune(now: now)
        #expect(big.grok.count == UsageHistory.maxSamplesPerSource)
        #expect(big.grok.last?.t == now)                          // newest kept
    }

    @Test func recordSkipsRedundantAndKeepsOrder() {
        var h = UsageHistory()
        h.record(.grok, percent: 5, at: now)
        h.record(.grok, percent: 5, at: now.addingTimeInterval(60))         // same value, too soon
        h.record(.grok, percent: 6, at: now.addingTimeInterval(120))
        h.record(.grok, percent: 4, at: now.addingTimeInterval(-60))        // out of order
        h.record(.grok, percent: 6, at: now.addingTimeInterval(120))        // duplicate time
        h.record(.grok, percent: .nan, at: now.addingTimeInterval(500))
        #expect(h.grok.map(\.p) == [4, 5, 6])
        #expect(h.grok.map(\.t) == h.grok.map(\.t).sorted())
    }

    @Test func diskRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gg-hist-\(UUID().uuidString)/history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var h = UsageHistory()
        h.record(.grokBot, percent: 12, at: now)
        try h.save(to: url)
        #expect(UsageHistory.load(from: url) == h)
        #expect(UsageHistory.load(from: url.appendingPathExtension("missing")) == UsageHistory())
    }
}

@Suite struct UpdateTests {
    @Test func versionComparison() {
        #expect(UpdateCheck.isNewer("v0.9.1", than: "0.9.0"))
        #expect(UpdateCheck.isNewer("v0.10.0", than: "0.9.0"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateCheck.isNewer("v0.9.0", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("0.9", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("v0.8.5", than: "0.9.0"))
        #expect(UpdateCheck.isNewer("0.9.0", than: "0.9.0-beta.1"))
        #expect(!UpdateCheck.isNewer("0.9.0-beta.2", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("garbage", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("1.0.0", than: "dev"))
    }

    @Test func parsesLatestRelease() {
        let ok = #"{"tag_name":"v0.9.1","html_url":"https://github.com/stevencombs/GrokGauge/releases/tag/v0.9.1","name":"GrokGauge 0.9.1","draft":false,"prerelease":false}"#
        let r = UpdateCheck.parse(Data(ok.utf8))
        #expect(r?.version == "0.9.1")
        #expect(r?.url.host == "github.com")
        let pre = #"{"tag_name":"v1.0.0-rc1","html_url":"https://github.com/x/y","prerelease":true}"#
        #expect(UpdateCheck.parse(Data(pre.utf8)) == nil)
        let evil = #"{"tag_name":"v9","html_url":"http://evil.example/x"}"#
        #expect(UpdateCheck.parse(Data(evil.utf8)) == nil)
    }

    @Test func backoff() {
        #expect(Backoff.delay(attempt: 0) == 0)
        #expect(Backoff.delay(attempt: 1) == 30)
        #expect(Backoff.delay(attempt: 3) == 120)
        #expect(Backoff.delay(attempt: 50) == 900)
        #expect(Backoff.delay(attempt: 3, cap: 60) == 60)
    }
}
