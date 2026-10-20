import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct OnboardingTests {
    @Test func eightStepsInTheApprovedOrder() {
        #expect(OnboardingStep.allCases == [.welcome, .connect, .rings, .sharedPool, .menuBar, .settingsSync, .historyPace, .thanks])
        #expect(OnboardingStep.count == 8)
        #expect(OnboardingStep.welcome.isFirst && !OnboardingStep.welcome.isLast)
        #expect(OnboardingStep.thanks.isLast && OnboardingStep.thanks.next == nil)
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.rings.next == .sharedPool)
        #expect(OnboardingStep.rings.previous == .connect)
        #expect(OnboardingStep.menuBar.progressLabel == "Step 5 of 8")
    }

    @Test func walkingForwardVisitsEveryStepOnce() {
        var seen: [OnboardingStep] = []
        var s: OnboardingStep? = .welcome
        while let cur = s { seen.append(cur); s = cur.next }
        #expect(seen == OnboardingStep.allCases)
        var back: [OnboardingStep] = []
        s = .thanks
        while let cur = s { back.append(cur); s = cur.previous }
        #expect(back == OnboardingStep.allCases.reversed())
    }

    @Test func showsOnceThenNeverOnItsOwn() {
        #expect(OnboardingPolicy.shouldShowAutomatically(seenRevision: nil))
        #expect(!OnboardingPolicy.shouldShowAutomatically(seenRevision: OnboardingPolicy.currentRevision))
        #expect(!OnboardingPolicy.shouldShowAutomatically(seenRevision: 7, current: 2))
        // Only a deliberate tour revision brings it back once.
        #expect(OnboardingPolicy.shouldShowAutomatically(seenRevision: 1, current: 2))
    }

    @Test func markSeenStoresALocalFlagAndNeverGoesBackwards() throws {
        let name = "OnboardingTests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(d.object(forKey: OnboardingPolicy.seenRevisionKey) == nil)
        OnboardingPolicy.markSeen(in: d)
        #expect(d.integer(forKey: OnboardingPolicy.seenRevisionKey) == OnboardingPolicy.currentRevision)
        #expect(!OnboardingPolicy.shouldShowAutomatically(seenRevision: d.object(forKey: OnboardingPolicy.seenRevisionKey) as? Int))
        d.set(5, forKey: OnboardingPolicy.seenRevisionKey)
        OnboardingPolicy.markSeen(in: d, revision: 2)
        #expect(d.integer(forKey: OnboardingPolicy.seenRevisionKey) == 5)
    }

    @Test func seenFlagIsNotPartOfTheSyncedSettingsFile() throws {
        let data = try SettingsSync.encode(GaugeSettings())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("onboarding"))
    }

    @Test func tipCopyIsExactlyWhatWasApproved() {
        #expect(OnboardingCopy.tipTitle == "Enjoying GrokGauge?")
        #expect(OnboardingCopy.tipBody == "It's free, open source, and built in my spare time with plenty of AI tokens along the way. If it saves you a surprise or two, a small tip helps cover those costs and keeps the updates coming.")
        #expect(OnboardingCopy.tipButton == "🙏 Tip on PayPal")
        #expect(OnboardingCopy.laterButton == "Maybe later")
        #expect(OnboardingCopy.tipFootnote == "No pressure — GrokGauge stays free either way.")
        #expect(OnboardingStep.thanks.title == OnboardingCopy.tipTitle)
        for s in [OnboardingCopy.tipTitle, OnboardingCopy.tipBody, OnboardingCopy.tipButton, OnboardingCopy.tipFootnote] {
            #expect(!s.contains("@"))   // never an email address
        }
    }

    @Test func colorBandsFollowTheUsersThresholds() {
        let std = OnboardingCopy.levelRanges(.standard)
        #expect(std.map(\.level) == [.normal, .warning, .critical])
        #expect(std.map(\.range) == ["0–80%", "81–90%", "Above 90%"])
        var custom = LevelThresholds.standard
        custom.setWarning(60)
        custom.setCritical(75)
        #expect(OnboardingCopy.levelRanges(custom).map(\.range) == ["0–60%", "61–75%", "Above 75%"])
        #expect(OnboardingCopy.spokenRange(.warning, custom) == "Warning: 61 to 75 percent")
        #expect(OnboardingCopy.spokenRange(.critical, custom) == "Critical: above 75 percent")
    }

    @Test func menuBarExampleUsesTheCurrentModeAndRealNumbers() {
        let both = OnboardingCopy.menuBarExample(mode: .both, grok: 39, bot: 27, hasGrokBot: true, thresholds: .standard)
        #expect(both.map(\.text).joined().contains("39%"))
        #expect(both.map(\.text).joined().contains("27%"))
        // No reading yet: sample numbers, so the card never shows an empty menu bar.
        #expect(!OnboardingCopy.menuBarExample(mode: .highest, grok: nil, bot: nil, hasGrokBot: true, thresholds: .standard).isEmpty)
        // Grok Bot modes fall back to Grok when Grok Bot isn't installed.
        let noBot = OnboardingCopy.menuBarExample(mode: .grokBotOnly, grok: 50, bot: nil, hasGrokBot: false, thresholds: .standard)
        #expect(noBot.map(\.text).joined().contains("50%"))
        // The level colors use the user's thresholds.
        var t = LevelThresholds.standard
        t.setWarning(30)
        t.setCritical(45)
        let hot = OnboardingCopy.menuBarExample(mode: .grokOnly, grok: 50, bot: nil, hasGrokBot: false, thresholds: t)
        #expect(hot.compactMap(\.level).contains(.critical))
    }
}
