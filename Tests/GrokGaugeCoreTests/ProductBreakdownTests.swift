import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct ProductBreakdownTests {
    func share(_ name: String, _ p: Double) -> ProductShare {
        ProductShare(key: "Grok" + name, name: name, symbol: UsageParser.symbol(forProduct: name), percent: p)
    }

    /// As the parser delivers them: canonical order, then extras.
    var products: [ProductShare] {
        [share("Chat", 20), share("Imagine", 10), share("Voice", 3.5), share("Build", 6.2), share("API", 2)]
    }

    func names(_ s: ProductBreakdownSettings, _ list: [ProductShare]? = nil) -> [String] {
        s.arrange(list ?? products).map(\.name)
    }

    @Test func defaultsShowAllInCanonicalOrder() {
        let s = ProductBreakdownSettings()
        #expect(s.order.map(\.id) == ["Chat", "Imagine", "Voice", "Build", "API"])
        #expect(s.order.allSatisfy { $0.visible })
        #expect(s.sort == .custom)
        #expect(names(s) == ["Chat", "Imagine", "Voice", "Build", "API"])
    }

    @Test func hiddenProductsAreFiltered() {
        var s = ProductBreakdownSettings()
        s.order[1].visible = false   // Imagine
        s.order[4].visible = false   // API
        #expect(names(s) == ["Chat", "Voice", "Build"])
        #expect(!s.isVisible("Imagine"))
        for i in s.order.indices { s.order[i].visible = false }
        #expect(s.arrange(products).isEmpty)
    }

    @Test func myOrderFollowsDragOrder() {
        let s = ProductBreakdownSettings(order: ["Build", "API", "Chat", "Voice", "Imagine"].map { ProductToggle($0) })
        #expect(names(s) == ["Build", "API", "Chat", "Voice", "Imagine"])
    }

    @Test func highestUsageFirst() {
        let s = ProductBreakdownSettings(sort: .usage)
        #expect(names(s) == ["Chat", "Imagine", "Build", "Voice", "API"])
    }

    @Test func alphabetical() {
        let s = ProductBreakdownSettings(sort: .alphabetical)
        #expect(names(s) == ["API", "Build", "Chat", "Imagine", "Voice"])
    }

    @Test func usageTiesFallBackToMyOrder() {
        let tied = [share("Chat", 5), share("Imagine", 0), share("Voice", 5), share("Build", 0), share("API", 0)]
        let s = ProductBreakdownSettings(order: ["API", "Voice", "Build", "Chat", "Imagine"].map { ProductToggle($0) }, sort: .usage)
        #expect(names(s, tied) == ["Voice", "Chat", "API", "Build", "Imagine"])
    }

    @Test func alphabeticalTiesFallBackToMyOrder() {
        // Two products with the same display name (case-insensitive): My order decides.
        let list = [share("Chat", 1), ProductShare(key: "chat2", name: "chat", symbol: "x", percent: 2)]
        let s = ProductBreakdownSettings(order: [ProductToggle("chat"), ProductToggle("Chat")], sort: .alphabetical)
        #expect(s.arrange(list).map(\.key) == ["chat2", "GrokChat"])
    }

    @Test func unknownProductsGoLastAndAreShown() {
        let list = products + [share("App Builder", 30), share("Music", 1)]
        let s = ProductBreakdownSettings()
        #expect(names(s, list) == ["Chat", "Imagine", "Voice", "Build", "API", "App Builder", "Music"])
        #expect(s.isVisible("App Builder"))
        // Highest usage first ranks them by usage like any other product.
        #expect(names(ProductBreakdownSettings(sort: .usage), list).first == "App Builder")
        // Settings lists them at the end, shown, so they can be hidden or moved.
        let listing = s.listing(including: list)
        #expect(listing.map(\.id).suffix(2) == ["App Builder", "Music"])
        #expect(listing.allSatisfy { $0.visible })
        // Once saved (here: hidden and moved first), the choice sticks.
        var saved = s
        saved.order = [ProductToggle("Music", visible: false)] + listing.filter { $0.id != "Music" }
        #expect(names(saved, list) == ["Chat", "Imagine", "Voice", "Build", "API", "App Builder"])
    }

    @Test func normalizesDuplicatesAndMissingCanonical() {
        let s = ProductBreakdownSettings(order: [ProductToggle("Voice", visible: false), ProductToggle("Voice"),
                                                 ProductToggle("Chat"), ProductToggle("")])
        // Missing ones go right after their nearest canonical predecessor that's present (Imagine after Chat,
        // Build after Voice), the same rule the dropdown sections use.
        #expect(s.order.map(\.id) == ["Voice", "Build", "API", "Chat", "Imagine"])
        #expect(!s.isVisible("Voice"))
    }

    @Test func resetRestoresDefaults() {
        var s = ProductBreakdownSettings(order: [ProductToggle("API", visible: false)], sort: .alphabetical)
        #expect(!s.isDefault)
        s.reset()
        #expect(s == .standard)
        var g = GaugeSettings()
        g.productBreakdown.sort = .usage
        g.resetLayout()
        #expect(g.productBreakdown == .standard)
    }

    // MARK: Settings file

    @Test func oldSettingsWithoutKeysDecodeToDefaults() throws {
        // A 0.9.1 settings.json: no productBreakdown key.
        let json = #"{"app":"GrokGauge","schema":1,"settings":{"ringStyle":"stacked","menuBarMode":"both","modifiedAt":"2026-10-08T12:00:00.000Z"}}"#
        let s = try SettingsSync.decode(Data(json.utf8))
        #expect(s.ringStyle == .stacked)
        #expect(s.productBreakdown == .standard)
        #expect(s.productBreakdown.sort == .custom)
    }

    @Test func roundTripsThroughSyncFile() throws {
        var g = GaugeSettings()
        g.productBreakdown = ProductBreakdownSettings(
            order: [ProductToggle("API"), ProductToggle("Chat", visible: false), ProductToggle("App Builder")] , sort: .usage)
        let back = try SettingsSync.decode(SettingsSync.encode(g))
        #expect(back.productBreakdown == g.productBreakdown)
        #expect(back.productBreakdown.order.map(\.id) == ["API", "Chat", "Imagine", "Voice", "Build", "App Builder"])
    }

    @Test func toleratesBadValues() throws {
        let json = #"{"app":"GrokGauge","schema":1,"settings":{"productBreakdown":{"order":[{"id":"Voice","visible":false},{"nope":1},{"id":"Chat"}],"sort":"byMood"},"modifiedAt":"2026-10-08T12:00:00.000Z"}}"#
        let s = try SettingsSync.decode(Data(json.utf8)).productBreakdown
        #expect(s.sort == .custom)
        #expect(s.order.first == ProductToggle("Voice", visible: false))
        // Missing ones go right after their nearest canonical predecessor that's present (Imagine after Chat,
        // Build after Voice), the same rule the dropdown sections use.
        #expect(s.order.map(\.id) == ["Voice", "Build", "API", "Chat", "Imagine"])
    }
}
