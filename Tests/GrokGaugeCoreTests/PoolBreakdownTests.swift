import Foundation
import Testing
@testable import GrokGaugeCore

/// The Total ring is the whole pool; the Grok, Grok Bot and Cursor rings are slices that add up to it.
@Suite struct PoolBreakdownTests {
    let now = Date(timeIntervalSince1970: 1_792_442_000)   // Oct 19 2026
    var end: Date { Date(timeIntervalSince1970: 1_792_655_700) }

    func pool(_ percent: Double, products: [(String, Double)]) -> UsageSnapshot {
        UsageSnapshot(percent: percent, percentInferred: false, period: .weekly,
                      periodStart: end.addingTimeInterval(-7 * 86_400), periodEnd: end,
                      products: products.map { ProductShare(key: $0.0, name: UsageParser.displayName(for: $0.0), symbol: "x", percent: $0.1) },
                      prepaidBalanceCents: 0, onDemandUsedCents: 0, onDemandCapCents: 0, fetchedAt: now)
    }

    func bot(_ percent: Double) -> GrokBotSnapshot {
        GrokBotSnapshot(percent: percent, nextReset: end, readAt: now, expiresAt: nil)
    }

    /// Steven's Oct 21 reading: 96% total, Grok Bot 70%, Cursor 18%, so regular Grok is 8%.
    let oct21: [(String, Double)] = [("GrokBot", 70.2), ("Cursor", 17.9), ("GrokChat", 6.1), ("GrokImagine", 1.4), ("Api", 0.3)]

    @Test func grokIsTotalMinusTheOtherSlices() {
        let p = pool(95.9, products: oct21)
        let ring = BotRingReading.make(bot: bot(95.9), pool: p, knownSharedEnd: nil)
        #expect(ring.isShared)
        let b = PoolBreakdown.make(pool: p, bot: ring)
        #expect(b.total == 95.9)
        #expect(b.grokBot == 70.2)
        #expect(b.cursor == 17.9)
        #expect(abs((b.grok ?? -1) - 7.8) < 0.0001)
        #expect(b.roundedGrok == 8)
        #expect(b.equation == "Grok 8% + Grok Bot 70% + Cursor 18% = Total 96%")
    }

    @Test func roundedSlicesAlwaysAddUpToTheRoundedTotal() {
        for (t, g, c) in [(42.4, 27.4, 1.4), (50.5, 20.5, 10.5), (99.6, 49.6, 49.6), (3.0, 0.4, 0.4)] {
            let p = pool(t, products: [("GrokBot", g), ("Cursor", c), ("GrokChat", max(0, t - g - c))])
            let b = PoolBreakdown.make(pool: p, bot: BotRingReading.make(bot: bot(t), pool: p, knownSharedEnd: nil))
            let sum = (b.roundedGrok ?? -100) + PoolBreakdown.whole(b.grokBot ?? -100) + PoolBreakdown.whole(b.cursor)
            #expect(sum == PoolBreakdown.whole(t) || b.roundedGrok == 0)
        }
    }

    @Test func clampsAtZeroWhenSharesExceedTheTotal() {
        // Product rows can run a little ahead of the total between xAI's updates.
        let p = pool(20, products: [("GrokBot", 15), ("Cursor", 7)])
        let b = PoolBreakdown.make(pool: p, bot: BotRingReading.make(bot: bot(20), pool: p, knownSharedEnd: nil))
        #expect(b.grok == 0)
        #expect(b.roundedGrok == 0)
    }

    @Test func clampsAtOneHundred() {
        let b = PoolBreakdown.make(pool: pool(130, products: [("GrokChat", 130)]), bot: nil)
        #expect(b.grok == 100)
        #expect(b.roundedGrok == 100)
    }

    @Test func missingRowsMeanNoneUsed() {
        // No Grok Bot or Cursor rows: everything is regular Grok.
        let b = PoolBreakdown.make(pool: pool(12, products: [("GrokChat", 12)]), bot: nil)
        #expect(b.grokBot == 0 && b.cursor == 0 && b.grok == 12 && b.roundedGrok == 12)
    }

    @Test func unknownWhileGrokBotsShareIsPending() {
        // A week known to be shared, with no pool reading yet: Grok Bot's share is "–", so Grok is too.
        let pending = BotRingReading(mode: .shared, percent: nil, nextReset: end, readAt: now, own: bot(90))
        let b = PoolBreakdown.make(pool: pool(90, products: oct21), bot: pending)
        #expect(b.grokBot == nil)
        #expect(b.grok == nil && b.roundedGrok == nil)
        #expect(b.equation.hasPrefix("Grok – + Grok Bot –"))
    }

    @Test func unknownWhenTheReplyHasNoProductRows() {
        let b = PoolBreakdown.make(pool: pool(40, products: []), bot: nil)
        #expect(!b.productsReported)
        #expect(b.grok == nil && b.roundedGrok == nil)
        // An empty pool has nothing to split: 0%.
        let empty = PoolBreakdown.make(pool: pool(0, products: []), bot: nil)
        #expect(empty.productsReported && empty.grok == 0)
    }

    @Test func separateGrokBotAllowanceIsNotSubtracted() {
        // Grok Bot on its own allowance: its own 12% isn't part of the pool; only a listed Grok Bot row would be.
        let p = pool(33, products: [("GrokChat", 28), ("Cursor", 5)])
        let ring = BotRingReading.make(bot: GrokBotSnapshot(percent: 12, nextReset: end.addingTimeInterval(3 * 3600), readAt: now, expiresAt: nil),
                                       pool: p, knownSharedEnd: nil)
        #expect(!ring.isShared)
        let b = PoolBreakdown.make(pool: p, bot: ring)
        #expect(b.grokBot == 0 && b.grok == 28)
    }

    @Test func cursorIsSubtractedEvenWhenItsRingIsHidden() {
        // The split comes from the reply, not from which rings are shown.
        let p = pool(30, products: [("GrokBot", 10), ("Cursor", 5), ("GrokChat", 15)])
        let b = PoolBreakdown.make(pool: p, bot: nil)
        #expect(b.cursor == 5 && b.grok == 15)
    }

    @Test func newGrokRingLandsAfterTotalInOldSettings() throws {
        let old = """
        {"app":"GrokGauge","schema":1,"settings":{"sections":[{"id":"grokBotRing","visible":true},{"id":"grokRing","visible":false},{"id":"cursorRing","visible":true}],"modifiedAt":"2026-10-20T22:00:00.000Z"}}
        """
        let s = try SettingsSync.decode(Data(old.utf8))
        // The user's own order and choices are kept; the Grok ring follows Total, shown.
        #expect(Array(s.sections.map(\.id).prefix(4)) == [.grokBotRing, .grokRing, .regularGrokRing, .cursorRing])
        #expect(!s.isVisible(.grokRing) && s.isVisible(.regularGrokRing) && s.isVisible(.cursorRing))
        #expect(DropdownSection.grokRing.title == "Total ring" && DropdownSection.regularGrokRing.title == "Grok ring")
        #expect(DropdownSection.regularGrokRing.isRing && DropdownSection.regularGrokRing.visibleByDefault)
    }

    @Test func fourRingsFitOrWiden() {
        #expect(PopoverLayout.width(ringCount: 4, sideBySide: true, sizing: .keepSize) > PopoverLayout.width(ringCount: 3, sideBySide: true, sizing: .keepSize))
        #expect(PopoverLayout.width(ringCount: 4, sideBySide: true, sizing: .fitWidth) == 320)
        #expect(PopoverLayout.width(ringCount: 4, sideBySide: false, sizing: .keepSize) == 320)
        #expect(PopoverLayout.ringDiameter(ringCount: 4, sizing: .keepSize) < PopoverLayout.ringDiameter(ringCount: 3, sizing: .keepSize))
        #expect(PopoverLayout.ringDiameter(ringCount: 4, sizing: .fitWidth) < PopoverLayout.ringDiameter(ringCount: 4, sizing: .keepSize))
        // Four rings plus a little padding each still fit across the dropdown's content width.
        for sizing in RingSizing.allCases {
            let content = PopoverLayout.width(ringCount: 4, sideBySide: true, sizing: sizing) - 32
            #expect(PopoverLayout.ringDiameter(ringCount: 4, sizing: sizing) + 6 <= content / 4)
        }
    }
}
