import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct PopoverLayoutTests {
    @Test func maxHeightIsTheVisibleScreenMinusAMargin() {
        // 13" MacBook Air at "More Space" off: 832 pt screen, ~800 visible below the menu bar.
        #expect(PopoverLayout.maxContentHeight(visibleHeight: 800) == 800 - PopoverLayout.screenMargin)
        #expect(PopoverLayout.maxContentHeight(visibleHeight: 200) == 320)   // floor for tiny screens
    }

    @Test func middleUsesItsOwnHeightWhenItFits() {
        #expect(PopoverLayout.scrollHeight(content: 300, fixed: 400, maxHeight: 900) == 300)
        #expect(PopoverLayout.scrollHeight(content: 300, fixed: 400, maxHeight: nil) == 300)
        #expect(PopoverLayout.scrollHeight(content: 0, fixed: 400, maxHeight: 500) == 0)
    }

    @Test func middleIsCappedSoTheWholePopoverFitsTheScreen() {
        // Screenshot case: ~1000 pt of content on a ~770 pt screen.
        let maxH = PopoverLayout.maxContentHeight(visibleHeight: 775)
        let fixed = 260.0 + 150 + 24 + 32           // rings+header, buttons+footer, gaps, padding
        let h = PopoverLayout.scrollHeight(content: 620, fixed: fixed, maxHeight: maxH)
        #expect(h == maxH - fixed)
        #expect(fixed + h <= maxH)
    }

    @Test func middleNeverCollapsesBelowTheMinimum() {
        #expect(PopoverLayout.scrollHeight(content: 600, fixed: 700, maxHeight: 720) == PopoverLayout.minimumScroll)
        #expect(PopoverLayout.scrollHeight(content: 50, fixed: 700, maxHeight: 720) == 50)
    }

    @Test func partitionPinsOnlyLeadingAndTrailingRuns() {
        // rings, problem, history, whatsNew, refresh, actions
        let kinds = ["ring", "problem", "mid", "mid", "bottom", "bottom"]
        let r = PopoverLayout.partition(count: kinds.count,
                                        pinTop: { ["ring", "problem"].contains(kinds[$0]) },
                                        pinBottom: { kinds[$0] == "bottom" })
        #expect(r.top == 0..<2)
        #expect(r.middle == 2..<4)
        #expect(r.bottom == 4..<6)
    }

    @Test func partitionWithSectionsReorderedOrAllPinned() {
        // Buttons moved to the top: they scroll with the middle; a ring moved to the end isn't pinned.
        let kinds = ["bottom", "ring", "mid", "ring"]
        let r = PopoverLayout.partition(count: kinds.count, pinTop: { kinds[$0] == "ring" }, pinBottom: { kinds[$0] == "bottom" })
        #expect(r.top.isEmpty)
        #expect(r.middle == 0..<4)
        #expect(r.bottom.isEmpty)
        let all = PopoverLayout.partition(count: 3, pinTop: { _ in true }, pinBottom: { _ in true })
        #expect(all.top == 0..<3)
        #expect(all.middle.isEmpty)
        #expect(all.bottom == 3..<3)
    }

    @Test func whatsNewIsCompactByDefault() {
        var s = WhatsNewState()
        s.apply(.news, items: (0..<10).map { NewsItem(id: "n\($0)", source: .news, title: "n\($0)",
                                                      date: Date(timeIntervalSince1970: Double(1_000 + $0))) })
        #expect(WhatsNewSettings.compactItems == 3)
        #expect(s.latest(enabled: [.news], limit: WhatsNewSettings.compactItems).map { $0.id } == ["n9", "n8", "n7"])
        #expect(s.latest(enabled: [.news], limit: WhatsNewSettings.expandedItems).count == 8)
    }
}
