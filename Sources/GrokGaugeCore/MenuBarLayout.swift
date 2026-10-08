import Foundation

/// Builds the menu bar title for every `MenuBarMode` (0.9+).
public enum MenuBarLayout {
    /// Mode actually used: modes that need Grok Bot fall back when it isn't installed.
    public static func effectiveMode(_ mode: MenuBarMode, hasGrokBot: Bool) -> MenuBarMode {
        guard !hasGrokBot else { return mode }
        switch mode {
        case .both, .grokBotOnly: return .grokOnly
        default: return mode
        }
    }

    /// `grok`/`bot` are rounded percents (nil = no current reading); `grokDays`/`botDays` are whole days to reset.
    /// Returns an empty list when there is nothing to show (callers then show a placeholder).
    public static func segments(grok: Int?, bot: Int?, grokDays: Int? = nil, botDays: Int? = nil,
                                mode: MenuBarMode, thresholds: LevelThresholds = .standard,
                                showDays: Bool = false) -> [MenuBarSegment] {
        func level(_ p: Int?) -> UsageLevel? { p.map(thresholds.level(forRoundedPercent:)) }
        var out: [MenuBarSegment] = []
        var days: Int?
        switch mode {
        case .highest:
            let pick: (Int, Int?)?
            switch (grok, bot) {
            case let (g?, b?): pick = b > g ? (b, botDays) : (g, grokDays)
            case let (g?, nil): pick = (g, grokDays)
            case let (nil, b?): pick = (b, botDays)
            default: pick = nil
            }
            guard let (p, d) = pick else { return [] }
            out = [MenuBarSegment(text: " \(p)%", level: level(p))]
            days = d
        case .both:
            if grok == nil && bot == nil { return [] }
            out = [
                MenuBarSegment(text: " G ", level: nil),
                MenuBarSegment(text: grok.map { "\($0)%" } ?? "–", level: level(grok)),
                MenuBarSegment(text: " · B ", level: nil),
                MenuBarSegment(text: bot.map { "\($0)%" } ?? "–", level: level(bot)),
            ]
            days = [grokDays, botDays].compactMap { $0 }.min()
        case .grokOnly:
            guard let g = grok else { return [] }
            out = [MenuBarSegment(text: " \(g)%", level: level(g))]
            days = grokDays
        case .grokBotOnly:
            guard let b = bot else { return [] }
            out = [MenuBarSegment(text: " \(b)%", level: level(b))]
            days = botDays
        case .logoOnly:
            guard showDays, let d = [grokDays, botDays].compactMap({ $0 }).min() else { return [] }
            return [MenuBarSegment(text: " \(d)d", level: nil)]
        }
        if showDays, let d = days {
            out.append(MenuBarSegment(text: " · \(d)d", level: nil))
        }
        return out
    }

    /// Status used to tint the logo in "logo only" mode: the worse of the two sources.
    public static func logoLevel(grok: Int?, bot: Int?, thresholds: LevelThresholds = .standard) -> UsageLevel? {
        let levels = [grok, bot].compactMap { $0 }.map(thresholds.level(forRoundedPercent:))
        if levels.contains(.critical) { return .critical }
        if levels.contains(.warning) { return .warning }
        return levels.isEmpty ? nil : .normal
    }
}
