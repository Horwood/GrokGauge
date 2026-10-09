import Foundation

// MARK: - Settings model (synced between Macs; never contains tokens, usage, or history)

/// The sections of the dropdown, in their default order.
public enum DropdownSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case grokRing, grokBotRing, historyPace, resetDates, productBreakdown, credits, whatsNew, refreshRow, actions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .grokRing: return "Grok ring"
        case .grokBotRing: return "Grok Bot ring"
        case .historyPace: return "History & pace"
        case .resetDates: return "Reset dates"
        case .productBreakdown: return "Grok by product"
        case .credits: return "Extra Usage Credits"
        case .whatsNew: return "What's new from xAI"
        case .refreshRow: return "Updated & Refresh row"
        case .actions: return "Action buttons"
        }
    }

    public var symbol: String {
        switch self {
        case .grokRing: return "circle.circle"
        case .grokBotRing: return "sparkles"
        case .historyPace: return "chart.xyaxis.line"
        case .resetDates: return "calendar.badge.clock"
        case .productBreakdown: return "chart.bar.fill"
        case .credits: return "creditcard"
        case .whatsNew: return "newspaper"
        case .refreshRow: return "arrow.clockwise"
        case .actions: return "square.grid.2x2"
        }
    }
}

public enum RingStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case sideBySide, stacked, combined
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .stacked: return "Stacked"
        case .combined: return "One combined ring (shows the higher)"
        }
    }
}

/// How the "Last 7 days" history is drawn. Applies to both the Grok and the Grok Bot graph.
public enum GraphStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// One bar per day (the peak reached that day). Default since 0.9.1.
    case bars
    /// The 0.9.0 sparkline: every recorded reading, joined by a line.
    case line
    /// The same line, with the area under it filled.
    case area
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bars: return "Bars"
        case .line: return "Line"
        case .area: return "Area"
        }
    }
    public var accessibilityDescription: String {
        switch self {
        case .bars: return "Bars, one bar per day"
        case .line: return "Line, every reading joined by a line"
        case .area: return "Area, the line with the area under it filled"
        }
    }
}

/// How often What's new checks the web sources (the Grok CLI pointer is checked every 2 hours).
public enum WhatsNewInterval: Int, Codable, CaseIterable, Sendable, Identifiable {
    case six = 6, twelve = 12, day = 24
    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) * 3600 }
    public var title: String { self == .day ? "Every day" : "Every \(rawValue) hours" }
}

/// "What's new from xAI" options. Synced with the other settings; the read/unread list is not.
public struct WhatsNewSettings: Codable, Equatable, Sendable {
    public var news: Bool
    public var releaseNotes: Bool
    public var grokCLI: Bool
    public var grokApps: Bool
    public var grokBotMac: Bool
    /// One summary notification per check with new items. Off by default.
    public var notify: Bool
    public var interval: WhatsNewInterval

    public static let cliInterval: TimeInterval = 2 * 3600
    public static let standard = WhatsNewSettings()

    public init(news: Bool = true, releaseNotes: Bool = true, grokCLI: Bool = true, grokApps: Bool = true,
                grokBotMac: Bool = true, notify: Bool = false, interval: WhatsNewInterval = .six) {
        self.news = news
        self.releaseNotes = releaseNotes
        self.grokCLI = grokCLI
        self.grokApps = grokApps
        self.grokBotMac = grokBotMac
        self.notify = notify
        self.interval = interval
    }

    public func isOn(_ s: NewsSource) -> Bool {
        switch s {
        case .news: return news
        case .releaseNotes: return releaseNotes
        case .grokCLI: return grokCLI
        case .grokApps: return grokApps
        case .grokBotMac: return grokBotMac
        }
    }

    public mutating func set(_ s: NewsSource, _ on: Bool) {
        switch s {
        case .news: news = on
        case .releaseNotes: releaseNotes = on
        case .grokCLI: grokCLI = on
        case .grokApps: grokApps = on
        case .grokBotMac: grokBotMac = on
        }
    }

    public var enabled: Set<NewsSource> { Set(NewsSource.allCases.filter(isOn)) }

    /// Check interval for one source.
    public func interval(for s: NewsSource) -> TimeInterval {
        switch s {
        case .grokCLI: return Self.cliInterval
        case .grokBotMac: return 15 * 60          // a local file read
        default: return interval.seconds
        }
    }

    enum CodingKeys: String, CodingKey { case news, releaseNotes, grokCLI, grokApps, grokBotMac, notify, interval }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WhatsNewSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ f: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? f }
        self.init(news: v(.news, d.news), releaseNotes: v(.releaseNotes, d.releaseNotes), grokCLI: v(.grokCLI, d.grokCLI),
                  grokApps: v(.grokApps, d.grokApps), grokBotMac: v(.grokBotMac, d.grokBotMac),
                  notify: v(.notify, d.notify), interval: v(.interval, d.interval))
    }
}

public enum ActionButtonKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openGrok, openGrokBot, openX
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openGrok: return "Open Grok"
        case .openGrokBot: return "Open Grok Bot"
        case .openX: return "Open X"
        }
    }
    public var symbol: String {
        switch self {
        case .openGrok: return "safari"
        case .openGrokBot: return "sparkles"
        case .openX: return "xmark"
        }
    }
}

/// One entry in a user-orderable list with a show/hide switch.
public struct OrderedToggle<ID: Hashable & Codable & Sendable & CaseIterable>: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: ID
    public var visible: Bool
    public init(_ id: ID, visible: Bool = true) {
        self.id = id
        self.visible = visible
    }
}

public typealias SectionItem = OrderedToggle<DropdownSection>
public typealias ActionItem = OrderedToggle<ActionButtonKind>

public enum MenuBarMode: String, Codable, CaseIterable, Sendable, Identifiable {
    // `highest` and `both` keep their 0.3 raw values so old preferences migrate as-is.
    case highest, both, grokOnly, grokBotOnly, logoOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .highest: return "Higher percent"
        case .both: return "Both percents (G · B)"
        case .grokOnly: return "Grok only"
        case .grokBotOnly: return "Grok Bot only"
        case .logoOnly: return "Logo only, tinted by status"
        }
    }
}

public enum RefreshInterval: Int, Codable, CaseIterable, Sendable, Identifiable {
    case five = 5, fifteen = 15, thirty = 30, sixty = 60
    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    public var title: String { rawValue == 60 ? "1 hour" : "\(rawValue) minutes" }
}

/// Global shortcut that opens the dropdown. `keyCode` is a macOS virtual key code.
public struct HotKey: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var keyCode: UInt32
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool

    public init(enabled: Bool = true, keyCode: UInt32, control: Bool = false, option: Bool = false,
                command: Bool = false, shift: Bool = false) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    /// ⌃⌥G
    public static let standard = HotKey(keyCode: 5, control: true, option: true)

    /// A shortcut needs at least one of ⌃ ⌥ ⌘ so plain typing never triggers it.
    public var isValid: Bool { control || option || command }

    /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
    public var carbonModifiers: UInt32 {
        (command ? 0x100 : 0) | (shift ? 0x200 : 0) | (option ? 0x800 : 0) | (control ? 0x1000 : 0)
    }

    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + HotKey.keyName(keyCode)
    }

    public static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`", 36: "↩", 48: "⇥", 49: "Space",
            51: "⌫", 53: "⎋", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "Key \(code)"
    }
}

public struct GaugeSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    // Layout
    public var sections: [SectionItem]
    public var ringStyle: RingStyle
    public var actions: [ActionItem]
    /// History graphs (inside the "History & pace" section).
    public var graphStyle: GraphStyle
    public var showGrokHistory: Bool
    public var showGrokBotHistory: Bool
    public var whatsNew: WhatsNewSettings

    // Menu bar
    public var menuBarMode: MenuBarMode
    public var showDaysToReset: Bool
    public var hideLogo: Bool
    public var hotKey: HotKey

    // Colors & alerts
    public var thresholds: LevelThresholds
    public var colors: LevelColors
    public var notificationsLinked: Bool
    public var notificationThresholds: LevelThresholds
    public var refreshInterval: RefreshInterval

    // Updates
    public var checkForUpdates: Bool

    /// When these settings were last changed on any Mac (last write wins when syncing).
    public var modifiedAt: Date

    public init(sections: [SectionItem] = GaugeSettings.defaultSections,
                ringStyle: RingStyle = .sideBySide,
                actions: [ActionItem] = GaugeSettings.defaultActions,
                graphStyle: GraphStyle = .bars,
                showGrokHistory: Bool = true,
                showGrokBotHistory: Bool = true,
                whatsNew: WhatsNewSettings = .standard,
                menuBarMode: MenuBarMode = .highest,
                showDaysToReset: Bool = false,
                hideLogo: Bool = false,
                hotKey: HotKey = .standard,
                thresholds: LevelThresholds = .standard,
                colors: LevelColors = .system,
                notificationsLinked: Bool = true,
                notificationThresholds: LevelThresholds = .standard,
                refreshInterval: RefreshInterval = .fifteen,
                checkForUpdates: Bool = true,
                modifiedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.sections = Self.normalized(sections, defaults: Self.defaultSections)
        self.ringStyle = ringStyle
        self.actions = Self.normalized(actions, defaults: Self.defaultActions)
        self.graphStyle = graphStyle
        self.showGrokHistory = showGrokHistory
        self.showGrokBotHistory = showGrokBotHistory
        self.whatsNew = whatsNew
        self.menuBarMode = menuBarMode
        self.showDaysToReset = showDaysToReset
        self.hideLogo = hideLogo
        self.hotKey = hotKey
        self.thresholds = thresholds
        self.colors = colors
        self.notificationsLinked = notificationsLinked
        self.notificationThresholds = notificationThresholds
        self.refreshInterval = refreshInterval
        self.checkForUpdates = checkForUpdates
        self.modifiedAt = modifiedAt
    }

    public static let defaultSections: [SectionItem] = DropdownSection.allCases.map { SectionItem($0) }
    public static let defaultActions: [ActionItem] = ActionButtonKind.allCases.map { ActionItem($0) }
    public static let defaults = GaugeSettings()

    /// Thresholds that trigger notifications (the color levels unless unlinked).
    public var effectiveNotificationThresholds: LevelThresholds {
        notificationsLinked ? thresholds : notificationThresholds
    }

    public func isVisible(_ section: DropdownSection) -> Bool {
        sections.first { $0.id == section }?.visible ?? true
    }

    /// Whether the What's new section is drawn: its checkbox is on and at least one source is chosen.
    public var showsWhatsNewSection: Bool {
        isVisible(.whatsNew) && !whatsNew.enabled.isEmpty
    }

    /// Whether the history section is drawn: its own checkbox is on and at least one graph is chosen.
    public var showsHistorySection: Bool {
        isVisible(.historyPace) && (showGrokHistory || showGrokBotHistory)
    }

    /// Equality that ignores `modifiedAt` (used to detect real changes).
    public func sameContent(as other: GaugeSettings) -> Bool {
        var a = self, b = other
        a.modifiedAt = .distantPast
        b.modifiedAt = .distantPast
        return a == b
    }

    // MARK: Layout helpers

    public mutating func resetLayout() {
        sections = Self.defaultSections
        ringStyle = .sideBySide
        actions = Self.defaultActions
        graphStyle = .bars
        showGrokHistory = true
        showGrokBotHistory = true
    }

    /// Drops unknown/duplicate ids and appends anything missing at its default position.
    static func normalized<ID>(_ items: [OrderedToggle<ID>], defaults: [OrderedToggle<ID>]) -> [OrderedToggle<ID>] {
        var seen = Set<ID>()
        var out: [OrderedToggle<ID>] = []
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            out.append(item)
        }
        for (i, d) in defaults.enumerated() where !seen.contains(d.id) {
            // Insert after the closest preceding default that's present.
            let previous = defaults[..<i].reversed().first { p in out.contains { $0.id == p.id } }
            let at = previous.flatMap { p in out.firstIndex { $0.id == p.id } }.map { $0 + 1 } ?? 0
            out.insert(d, at: at)
            seen.insert(d.id)
        }
        return out
    }

    // MARK: Codable (tolerant: missing keys fall back to defaults, unknown values are ignored)

    enum CodingKeys: String, CodingKey {
        case sections, ringStyle, actions, graphStyle, showGrokHistory, showGrokBotHistory, whatsNew, menuBarMode, showDaysToReset, hideLogo, hotKey, thresholds,
             colors, notificationsLinked, notificationThresholds, refreshInterval, checkForUpdates, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GaugeSettings.defaults
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(
            sections: Self.lenientList(c, .sections) ?? d.sections,
            ringStyle: value(.ringStyle, d.ringStyle),
            actions: Self.lenientList(c, .actions) ?? d.actions,
            // Added in 0.9.1: settings saved by 0.9.0 lack these keys and get the defaults.
            graphStyle: value(.graphStyle, d.graphStyle),
            showGrokHistory: value(.showGrokHistory, d.showGrokHistory),
            showGrokBotHistory: value(.showGrokBotHistory, d.showGrokBotHistory),
            whatsNew: value(.whatsNew, d.whatsNew),
            menuBarMode: value(.menuBarMode, d.menuBarMode),
            showDaysToReset: value(.showDaysToReset, d.showDaysToReset),
            hideLogo: value(.hideLogo, d.hideLogo),
            hotKey: value(.hotKey, d.hotKey),
            thresholds: value(.thresholds, d.thresholds).validated(),
            colors: value(.colors, d.colors),
            notificationsLinked: value(.notificationsLinked, d.notificationsLinked),
            notificationThresholds: value(.notificationThresholds, d.notificationThresholds).validated(),
            refreshInterval: value(.refreshInterval, d.refreshInterval),
            checkForUpdates: value(.checkForUpdates, d.checkForUpdates),
            modifiedAt: value(.modifiedAt, d.modifiedAt))
    }

    /// Decodes a list entry by entry so one unknown id (from a newer version) doesn't drop the whole list.
    private static func lenientList<ID>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [OrderedToggle<ID>]? {
        guard let raw = try? c.decodeIfPresent([RawToggle].self, forKey: key) else { return nil }
        return raw.compactMap { r in
            // Case names equal raw values for these enums.
            guard let id = ID.allCases.first(where: { "\($0)" == r.id }) else { return nil }
            return OrderedToggle(id, visible: r.visible ?? true)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sections, forKey: .sections)
        try c.encode(ringStyle, forKey: .ringStyle)
        try c.encode(actions, forKey: .actions)
        try c.encode(graphStyle, forKey: .graphStyle)
        try c.encode(showGrokHistory, forKey: .showGrokHistory)
        try c.encode(showGrokBotHistory, forKey: .showGrokBotHistory)
        try c.encode(whatsNew, forKey: .whatsNew)
        try c.encode(menuBarMode, forKey: .menuBarMode)
        try c.encode(showDaysToReset, forKey: .showDaysToReset)
        try c.encode(hideLogo, forKey: .hideLogo)
        try c.encode(hotKey, forKey: .hotKey)
        try c.encode(thresholds, forKey: .thresholds)
        try c.encode(colors, forKey: .colors)
        try c.encode(notificationsLinked, forKey: .notificationsLinked)
        try c.encode(notificationThresholds, forKey: .notificationThresholds)
        try c.encode(refreshInterval, forKey: .refreshInterval)
        try c.encode(checkForUpdates, forKey: .checkForUpdates)
        try c.encode(modifiedAt, forKey: .modifiedAt)
    }

    // MARK: Migration

    /// Builds settings for a Mac upgrading from 0.3 or earlier, whose only preference was
    /// `menuBar.style` ("highest" or "both") in UserDefaults.
    public static func migratingFrom03(menuBarStyle: String?) -> GaugeSettings {
        var s = GaugeSettings()
        if let raw = menuBarStyle, let mode = MenuBarMode(rawValue: raw) { s.menuBarMode = mode }
        return s
    }
}

private struct RawToggle: Decodable {
    let id: String
    let visible: Bool?
}

// MARK: - Level thresholds (the two handles of the range slider)

/// `normal` up to and including `warningAbove`, `warning` up to and including `criticalAbove`,
/// `critical` above that. Both are whole percents.
public struct LevelThresholds: Codable, Equatable, Hashable, Sendable {
    public static let lowerBound = 1
    public static let upperBound = 99
    public static let minimumGap = 1
    public static let standard = LevelThresholds(warningAbove: 80, criticalAbove: 90)

    public private(set) var warningAbove: Int
    public private(set) var criticalAbove: Int

    public init(warningAbove: Int, criticalAbove: Int) {
        self.warningAbove = warningAbove
        self.criticalAbove = criticalAbove
        self = validated()
    }

    enum CodingKeys: String, CodingKey { case warningAbove, criticalAbove }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(warningAbove: try c.decode(Int.self, forKey: .warningAbove),
                  criticalAbove: try c.decode(Int.self, forKey: .criticalAbove))
    }

    /// Moves the lower handle. Pushing it into the upper handle moves the upper one along.
    public mutating func setWarning(_ value: Int) {
        let v = Self.clamp(value, Self.lowerBound, Self.upperBound - Self.minimumGap)
        warningAbove = v
        if criticalAbove < v + Self.minimumGap { criticalAbove = v + Self.minimumGap }
    }

    /// Moves the upper handle. Pushing it into the lower handle moves the lower one along.
    public mutating func setCritical(_ value: Int) {
        let v = Self.clamp(value, Self.lowerBound + Self.minimumGap, Self.upperBound)
        criticalAbove = v
        if warningAbove > v - Self.minimumGap { warningAbove = v - Self.minimumGap }
    }

    /// Repairs out-of-range or crossed values (e.g. from a hand-edited sync file).
    public func validated() -> LevelThresholds {
        var out = self
        let w = Self.clamp(warningAbove, Self.lowerBound, Self.upperBound - Self.minimumGap)
        out.warningAbove = w
        out.criticalAbove = Self.clamp(max(criticalAbove, w + Self.minimumGap),
                                       Self.lowerBound + Self.minimumGap, Self.upperBound)
        return out
    }

    public func level(forRoundedPercent p: Int) -> UsageLevel {
        if p > criticalAbove { return .critical }
        if p > warningAbove { return .warning }
        return .normal
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}

public extension WhatsNewSettings {
    /// Items shown in the dropdown before "Show more", and after.
    static let compactItems = 3
    static let expandedItems = 8
}
