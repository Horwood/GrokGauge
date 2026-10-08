import AppKit
import GrokGaugeCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var updates: UpdateMonitor
    var openPreferences: () -> Void = {}

    private var settings: GaugeSettings { settingsStore.settings }

    /// One renderable piece of the dropdown, after applying order, visibility and ring style.
    private enum Block: Hashable {
        case rings([DropdownSection])   // side by side, or one combined ring
        case stackedRing(DropdownSection)
        case section(DropdownSection)
        case problem
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var ringsDone = false
        let bot = store.hasGrokBot
        let visibleRings = [DropdownSection.grokRing, .grokBotRing].filter {
            settings.isVisible($0) && ($0 == .grokRing || bot)
        }
        for item in settings.sections where item.visible {
            switch item.id {
            case .grokRing, .grokBotRing:
                guard visibleRings.contains(item.id) else { continue }
                if settings.ringStyle == .stacked {
                    out.append(.stackedRing(item.id))
                    if !out.contains(.problem) { out.append(.problem) }
                } else if !ringsDone {
                    out.append(.rings(visibleRings))
                    out.append(.problem)
                    ringsDone = true
                }
            case .productBreakdown, .credits:
                if store.snapshot != nil { out.append(.section(item.id)) }
            case .historyPace:
                // Hidden when both graphs are switched off (or only Grok Bot's is on and it isn't installed).
                if settings.showGrokHistory || (settings.showGrokBotHistory && bot) { out.append(.section(item.id)) }
            default:
                out.append(.section(item.id))
            }
        }
        if !out.contains(.problem) { out.insert(.problem, at: 0) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks, id: \.self) { block in
                        blockView(block, now: context.date)
                    }
                }
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .environment(\.palette, Palette(settings))
    }

    @ViewBuilder
    private func blockView(_ block: Block, now: Date) -> some View {
        switch block {
        case .rings(let rings):
            RingsRow(store: store, rings: rings, combined: settings.ringStyle == .combined && rings.count == 2)
        case .stackedRing(let section):
            StackedRing(store: store, section: section, now: now)
        case .problem:
            if store.snapshot != nil, let problem = store.problem {
                InlineWarning(problem: problem)
            } else if let problem = store.problem {
                ProblemCard(problem: problem) { store.refresh() }
            }
        case .section(let section):
            sectionView(section, now: now)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DropdownSection, now: Date) -> some View {
        switch section {
        case .historyPace:
            HistoryPaceCard(store: store, history: history.history, settings: settings, now: now)
        case .resetDates:
            ResetCard(grokEnd: store.snapshot?.periodEnd,
                      botEnd: store.hasGrokBot ? store.botSnapshot?.nextReset : nil,
                      labelLines: store.hasGrokBot,
                      now: now)
        case .productBreakdown:
            if let s = store.snapshot { ProductBreakdown(products: s.products, level: s.roundedPercent) }
        case .credits:
            if let s = store.snapshot { CreditsCard(snapshot: s) }
        case .refreshRow:
            RefreshRow(store: store, now: now)
        case .actions:
            ActionsRow(actions: settings.actions.filter(\.visible).map(\.id)
                .filter { $0 != .openGrokBot || store.hasGrokBot })
        case .grokRing, .grokBotRing:
            EmptyView()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            GrokMarkView(size: 18)
                .foregroundStyle(.primary)
            Text("GrokGauge")
                .font(.system(.headline, design: .rounded))
            Spacer()
            Text(planLabel)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
            Button(action: openPreferences) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
    }

    private var planLabel: String {
        guard let s = store.snapshot else { return "SuperGrok" }
        return "SuperGrok · \(s.period.label)"
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let release = updates.available {
                UpdateBanner(release: release)
            }
            HStack {
                Text("v\(AppInfo.version) · unofficial")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit GrokGauge") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
        }
    }
}

// MARK: - Rings

private struct RingsRow: View {
    @ObservedObject var store: UsageStore
    let rings: [DropdownSection]
    let combined: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        if combined {
            combinedRing.frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                ForEach(rings, id: \.self) { r in
                    RingContent.make(r, store: store).ringView(size: 104).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var combinedRing: some View {
        let g = RingContent.make(.grokRing, store: store)
        let b = RingContent.make(.grokBotRing, store: store)
        let botHigher = (b.percent ?? -1) > (g.percent ?? -1)
        var top = botHigher ? b : g
        let parts = [g, b].map { c in "\(c.title) \(c.rounded.map { "\($0)%" } ?? "—")" }
        top.title = botHigher ? "Grok Bot (higher)" : (b.percent == nil ? "Grok" : "Grok (higher)")
        top.caption = parts.joined(separator: " · ")
        top.captionAction = nil
        return top.ringView(size: 116)
    }
}

/// Everything needed to draw one source's ring.
private struct RingContent {
    var title: String
    var percent: Double?
    var isLoading: Bool
    var caption: String?
    var captionHelp: String?
    var captionAction: (() -> Void)?
    var detail: String?

    var rounded: Int? { percent.map { Int(max(0, $0).rounded()) } }

    @MainActor
    static func make(_ section: DropdownSection, store: UsageStore) -> RingContent {
        if section == .grokBotRing {
            let b = store.botSnapshot
            let problem = store.botProblem
            return RingContent(
                title: "Grok Bot", percent: b?.percent, isLoading: false,
                // Date included when the reading isn't from today ("as of Oct 7, 5:38 PM").
                caption: b.map { "as of \(UsageFormat.readingTime($0.readAt))" } ?? problem?.caption,
                captionHelp: problem?.tooltip
                    ?? b.map { "Grok Bot's last reading: \(UsageFormat.resetDate($0.readAt)). Open Grok Bot to update it." },
                captionAction: problem?.opensGrokBot == true ? { Launcher.openGrokBot() } : nil,
                detail: b?.timeUntilReset().map { "Resets in \(UsageFormat.countdown($0))" })
        }
        let s = store.snapshot
        var caption: String?
        var help: String?
        if let s {
            if s.percentInferred {
                caption = "Inferred (none reported)"
                help = "Grok's reply had no usage percentage. With an otherwise normal reply that means nothing used yet, so GrokGauge shows 0%."
            } else {
                caption = s.period == .weekly ? "SuperGrok weekly" : s.period.label
            }
        } else if let p = store.problem {
            caption = p.ringCaption
            help = p.title
        }
        return RingContent(title: "Grok", percent: s?.percent, isLoading: s == nil && store.problem == nil,
                           caption: caption, captionHelp: help, captionAction: nil,
                           detail: s?.timeUntilReset().map { "Resets in \(UsageFormat.countdown($0))" })
    }

    func ringView(size: CGFloat) -> some View { SourceRing(content: self, size: size) }
}

/// One labeled ring. `percent == nil` draws a neutral, empty ring.
private struct SourceRing: View {
    let content: RingContent
    let size: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            RingDial(percent: content.percent, isLoading: content.isLoading, title: content.title,
                     size: size, lineWidth: size > 100 ? 11 : 9, fontSize: size * 0.25)
            Text(content.title)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .accessibilityHidden(true)
            RingCaption(content: content)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct RingCaption: View {
    let content: RingContent
    var body: some View {
        Group {
            if let action = content.captionAction, let caption = content.caption {
                Button(caption, action: action)
                    .buttonStyle(.link)
            } else if let caption = content.caption {
                Text(.init(caption)).foregroundStyle(.secondary)
            } else {
                Text(" ")
            }
        }
        .help(content.captionHelp ?? "")
    }
}

/// The dial itself with the percent in the middle.
private struct RingDial: View {
    let percent: Double?
    let isLoading: Bool
    let title: String
    let size: CGFloat
    let lineWidth: CGFloat
    let fontSize: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rounded = percent.map { Int(max(0, $0).rounded()) }
        let color = palette.color(forRounded: rounded)
        ZStack {
            RingGauge(fraction: (percent ?? 0) / 100, color: color, lineWidth: lineWidth)
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 0) {
                    Text(rounded.map { "\($0)%" } ?? "—")
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(rounded == nil ? Color.secondary : color)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    if size > 80 {
                        Text("used")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .opacity(rounded == nil ? 0 : 1)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(rounded.map { "\($0) percent used, \(palette.level($0).spoken)" } ?? (isLoading ? "loading" : "no reading"))
    }
}

/// Stacked style: a compact ring with its details beside it.
private struct StackedRing: View {
    @ObservedObject var store: UsageStore
    let section: DropdownSection
    let now: Date

    var body: some View {
        let c = RingContent.make(section, store: store)
        HStack(spacing: 14) {
            RingDial(percent: c.percent, isLoading: c.isLoading, title: c.title, size: 64, lineWidth: 8, fontSize: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                RingCaption(content: c)
                    .font(.caption)
                    .lineLimit(1)
                if let d = c.detail {
                    Text(d).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

struct RingGauge: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let f = min(1, max(0, fraction))
        let high = contrast == .increased
        ZStack {
            Circle()
                .stroke(high ? Color.secondary.opacity(0.45) : color.opacity(0.16), lineWidth: lineWidth)
            if f > 0 {
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(
                        high ? AnyShapeStyle(color) : AnyShapeStyle(
                            AngularGradient(colors: [color.opacity(0.6), color],
                                            center: .center,
                                            startAngle: .degrees(0),
                                            endAngle: .degrees(360 * f))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: high ? .clear : color.opacity(0.35), radius: 4)
            }
        }
        .padding(lineWidth / 2)
        .animation(reduceMotion ? nil : .spring(duration: 0.6), value: f)
    }
}

// MARK: - History & pace

private struct HistoryPaceCard: View {
    @ObservedObject var store: UsageStore
    let history: UsageHistory
    let settings: GaugeSettings
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LAST 7 DAYS & PACE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if settings.showGrokHistory {
                SourceTrend(name: "Grok", history: history, source: .grok, current: store.snapshot?.percent,
                            knownResets: grokResets, pace: grokPace, style: settings.graphStyle, now: now)
            }
            if settings.showGrokBotHistory && store.hasGrokBot {
                SourceTrend(name: "Grok Bot", history: history, source: .grokBot, current: store.botSnapshot?.percent,
                            knownResets: botResets, pace: botPace, style: settings.graphStyle, now: now)
            }
        }
        .card()
    }

    private var grokResets: [Date] {
        guard let s = store.snapshot, let end = s.periodEnd else { return [] }
        return [s.periodStart ?? Pace.weeklyStart(forReset: end)]
    }

    private var botResets: [Date] {
        guard let end = store.botSnapshot?.nextReset else { return [] }
        return [Pace.weeklyStart(forReset: end)]
    }

    private var grokPace: PaceStatus? {
        guard let s = store.snapshot, let end = s.periodEnd else { return nil }
        return Pace.project(percent: s.percent, periodStart: s.periodStart ?? Pace.weeklyStart(forReset: end),
                            periodEnd: end, now: now)
    }

    private var botPace: PaceStatus? {
        guard let b = store.botSnapshot, let end = b.nextReset else { return nil }
        return Pace.project(percent: b.percent, periodStart: Pace.weeklyStart(forReset: end), periodEnd: end, now: now)
    }
}

private struct SourceTrend: View {
    let name: String
    let history: UsageHistory
    let source: HistorySource
    let current: Double?
    let knownResets: [Date]
    let pace: PaceStatus?
    let style: GraphStyle
    let now: Date
    @Environment(\.palette) private var palette

    var body: some View {
        let rounded = current.map { Int(max(0, $0).rounded()) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                Text(pace.map { Pace.describe($0) } ?? "Pace: no reading")
                    .font(.caption2)
                    .foregroundStyle(paceColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .accessibilityElement(children: .combine)
            switch style {
            case .bars:
                let days = history.daily(source, now: now, current: current, knownResets: knownResets)
                if days.contains(where: { $0.peak != nil }) {
                    DailyBars(days: days, sourceName: name)
                        .frame(height: 54)
                } else {
                    collecting
                }
            case .line, .area:
                let samples = history.series(source, now: now)
                if samples.count >= 2 {
                    Sparkline(samples: samples, now: now, color: palette.color(forRounded: rounded),
                              thresholds: palette.thresholds, filled: style == .area)
                        .frame(height: 26)
                        .accessibilityElement()
                        .accessibilityLabel("\(name) usage, last 7 days")
                        .accessibilityValue(trendSummary(samples))
                } else {
                    collecting
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) history")
    }

    private var collecting: some View {
        Text("Collecting history… (the chart fills in over the week)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private var paceColor: Color {
        switch pace {
        case .runsOut?: return palette.color(.warning)
        case .exhausted?: return palette.color(.critical)
        default: return .secondary
        }
    }

    private func trendSummary(_ samples: [UsageSample]) -> String {
        guard let first = samples.first, let last = samples.last else { return "" }
        return "from \(Int(first.p.rounded())) to \(Int(last.p.rounded())) percent, \(samples.count) readings"
    }
}

/// One bar per day: the highest % reached that day, tinted with its level color.
/// Today's column is highlighted; a small mark above a bar means the weekly allowance reset that day.
struct DailyBars: View {
    let days: [DailyUsage]
    var sourceName: String = ""
    var labelHeight: CGFloat = 11
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 5
            let count = CGFloat(max(1, days.count))
            let colW = max(4, (geo.size.width - gap * (count - 1)) / count)
            let barH = max(8, geo.size.height - labelHeight - 2)
            ZStack(alignment: .topLeading) {
                ForEach([palette.thresholds.warningAbove, palette.thresholds.criticalAbove], id: \.self) { t in
                    Path { p in
                        let y = barH - barH * CGFloat(t) / 100
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        column(day, width: colW, barHeight: barH)
                    }
                }
            }
        }
    }

    private func column(_ day: DailyUsage, width: CGFloat, barHeight: CGFloat) -> some View {
        let color = day.roundedPeak.map { palette.color(forRounded: $0) } ?? Color.secondary
        let fraction = CGFloat(min(100, max(0, day.peak ?? 0)) / 100)
        let h = day.peak == nil ? 0 : max(2, barHeight * fraction)
        return VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                if day.peak == nil {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: min(width, 10), height: 1.5)
                } else {
                    UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5, style: .continuous)
                        .fill(color.opacity(day.isToday ? 1 : 0.72))
                        .frame(height: h)
                        .overlay(alignment: .top) {
                            if day.isToday {
                                UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5, style: .continuous)
                                    .stroke(color, lineWidth: 1)
                                    .frame(height: h)
                            }
                        }
                }
            }
            .frame(width: width, height: barHeight, alignment: .bottom)
            HStack(spacing: 1.5) {
                if day.reset {
                    // Subtle reset mark: the week started over on this day.
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 6.5, weight: .heavy))
                }
                Text(Self.weekday(day.day))
                    .font(.system(size: 8.5, weight: day.isToday ? .bold : .regular))
            }
            .foregroundStyle(day.isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: width, height: labelHeight)
            .overlay(alignment: .bottom) {
                // Today: a short underline under the weekday (a column background read as a 100% bar).
                if day.isToday {
                    Capsule().fill(color).frame(width: min(width * 0.5, 14), height: 1.5).offset(y: 2)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenDay(day))
        .accessibilityValue(Self.spokenValue(day))
        .help(Self.spokenDay(day) + ": " + Self.spokenValue(day))
    }

    static func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: d)
    }

    static func spokenDay(_ day: DailyUsage) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEE MMMM d")
        return day.isToday ? "Today, \(f.string(from: day.day))" : f.string(from: day.day)
    }

    static func spokenValue(_ day: DailyUsage) -> String {
        var out = day.roundedPeak.map { "Peak \($0) percent" } ?? "No reading"
        if day.reset { out += ", weekly reset" }
        return out
    }
}

struct Sparkline: View {
    let samples: [UsageSample]
    let now: Date
    let color: Color
    let thresholds: LevelThresholds
    /// Area style: fill under the line. Line style draws the line only.
    var filled = false
    var window: TimeInterval = 7 * 86_400

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let start = now.addingTimeInterval(-window)
            let pts = samples.map { s in
                CGPoint(x: w * CGFloat(min(1, max(0, s.t.timeIntervalSince(start) / window))),
                        y: h - h * CGFloat(min(100, max(0, s.p)) / 100))
            }
            ZStack {
                ForEach([thresholds.warningAbove, thresholds.criticalAbove], id: \.self) { t in
                    Path { p in
                        let y = h - h * CGFloat(t) / 100
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                if filled {
                    Path { p in
                        guard let first = pts.first else { return }
                        p.move(to: CGPoint(x: first.x, y: h))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.5), color.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(color).frame(width: 5, height: 5).position(last)
                }
            }
        }
    }
}

// MARK: - Reset dates

/// Days to reset plus the exact reset time. One line when both pools reset together,
/// otherwise one clearly labeled line per pool.
private struct ResetCard: View {
    let grokEnd: Date?
    let botEnd: Date?
    /// Label lines with the source name (true whenever Grok Bot is installed).
    let labelLines: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RESETS IN")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let g = grokEnd, let b = botEnd, abs(g.timeIntervalSince(b)) < 120 {
                ResetLine(label: nil, end: g, now: now)
            } else if grokEnd == nil && botEnd == nil {
                Text("—").font(.title3.bold()).foregroundStyle(.secondary)
            } else {
                if let g = grokEnd {
                    ResetLine(label: labelLines ? "Grok" : nil, end: g, now: now)
                }
                if grokEnd != nil && botEnd != nil {
                    Divider()
                }
                if let b = botEnd {
                    ResetLine(label: "Grok Bot", end: b, now: now)
                }
            }
        }
        .card()
    }
}

private struct ResetLine: View {
    let label: String?
    let end: Date
    let now: Date

    var body: some View {
        let left = max(0, end.timeIntervalSince(now))
        let days = UsageFormat.wholeDays(left)
        HStack(alignment: .center, spacing: 8) {
            if let label {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .frame(width: 62, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(days)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(days == 1 ? "day" : "days")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(UsageFormat.countdown(left))
                    .font(.caption)
                    .monospacedDigit()
                Text(UsageFormat.resetDate(end))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label ?? "Usage") resets in \(UsageFormat.countdown(left))")
        .accessibilityValue(UsageFormat.resetDate(end))
    }
}

// MARK: - Cards

private struct CardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(contrast == .increased ? AnyShapeStyle(Color.primary.opacity(0.5))
                                                         : AnyShapeStyle(.separator.opacity(0.5)),
                                  lineWidth: contrast == .increased ? 1 : 0.5)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

private struct ProductBreakdown: View {
    let products: [ProductShare]
    /// The pool's rounded percent: bars take its level color.
    let level: Int
    @Environment(\.palette) private var palette

    var body: some View {
        let color = palette.color(forRounded: level)
        VStack(alignment: .leading, spacing: 8) {
            Text("GROK BY PRODUCT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(products) { p in
                HStack(spacing: 8) {
                    Image(systemName: p.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(p.name)
                        .font(.callout)
                        .frame(width: 64, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.fill.tertiary)
                            Capsule()
                                .fill(color.gradient)
                                .frame(width: max(p.percent > 0 ? 4 : 0, geo.size.width * min(1, p.percent / 100)))
                        }
                    }
                    .frame(height: 5)
                    Text(percentText(p.percent))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(p.percent > 0 ? .primary : .secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(p.name)")
                .accessibilityValue("\(percentText(p.percent)) of the Grok pool")
            }
        }
        .card()
    }

    private func percentText(_ v: Double) -> String {
        if v == 0 { return "0%" }
        if v < 1 { return "<1%" }
        return "\(Int(v.rounded()))%"
    }
}

private struct CreditsCard: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "creditcard.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Extra Usage Credits").font(.callout)
                Spacer()
                Text(UsageFormat.dollars(fromCents: snapshot.prepaidBalanceCents))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(snapshot.prepaidBalanceCents > 0 ? .primary : .secondary)
            }
            .accessibilityElement(children: .combine)
            if snapshot.onDemandCapCents > 0 || snapshot.onDemandUsedCents > 0 {
                HStack {
                    Text("On-demand")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                    Spacer()
                    Text("\(UsageFormat.dollars(fromCents: snapshot.onDemandUsedCents)) of \(UsageFormat.dollars(fromCents: snapshot.onDemandCapCents))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

private struct RefreshRow: View {
    @ObservedObject var store: UsageStore
    let now: Date

    var body: some View {
        HStack {
            Group {
                if store.isRefreshing {
                    Text("Updating…")
                } else if let at = store.snapshot?.fetchedAt {
                    Text("Updated \(at.formatted(date: .omitted, time: .shortened))")
                } else if let next = store.nextRetry, next > now {
                    Text("Retrying \(next.formatted(date: .omitted, time: .shortened))")
                } else if let at = store.lastAttempt {
                    Text("Tried \(at.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Spacer()

            Button {
                store.refresh()
            } label: {
                HStack(spacing: 4) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh now")
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
            .accessibilityLabel("Refresh now")
        }
    }
}

private struct ProblemCard: View {
    let problem: UsageProblem
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(problem.title).font(.headline)
            }
            Text(.init(problem.detail))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if problem.needsLogin {
                    Button("Copy “grok login”") { Launcher.copyLoginCommand() }
                    Button("Open Terminal") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
                        }
                    }
                }
                Spacer()
                Button("Retry", action: retry)
            }
            .controlSize(.small)
        }
        .card()
    }

    private var icon: String {
        if problem.needsLogin { return "person.crop.circle.badge.exclamationmark" }
        if problem == .changedShape { return "questionmark.diamond.fill" }
        return "exclamationmark.triangle.fill"
    }
}

private struct InlineWarning: View {
    let problem: UsageProblem
    var body: some View {
        Label {
            Text("\(problem.title). Showing the last good reading.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ActionsRow: View {
    let actions: [ActionButtonKind]

    var body: some View {
        if !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(actions, id: \.self) { a in
                    ActionButton(kind: a, compact: actions.count >= 3)
                }
            }
        }
    }
}

private struct ActionButton: View {
    let kind: ActionButtonKind
    let compact: Bool

    // Standard bordered buttons pick up the system material automatically
    // (Liquid Glass on macOS 26+, classic bezel on 14–15).
    var body: some View {
        Button(action: perform) {
            Group {
                if kind == .openX && compact {
                    Text("𝕏").font(.system(size: 15, weight: .bold))
                } else {
                    Label {
                        Text(compact ? shortTitle : kind.title)
                    } icon: {
                        if kind == .openX {
                            Text("𝕏").font(.system(size: 13, weight: .bold))
                        } else {
                            Image(systemName: kind.symbol)
                        }
                    }
                }
            }
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityLabel(kind.title)
        .help(kind.title)
    }

    private var shortTitle: String {
        switch kind {
        case .openGrok: return "Grok"
        case .openGrokBot: return "Grok Bot"
        case .openX: return "X"
        }
    }

    private func perform() {
        switch kind {
        case .openGrok: Launcher.openGrok()
        case .openGrokBot: Launcher.openGrokBot()
        case .openX: Launcher.openX()
        }
    }
}

private struct UpdateBanner: View {
    let release: ReleaseInfo
    @ViewState var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Update available: \(release.version)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Link("View release", destination: release.url)
                    .font(.caption)
            }
            HStack(spacing: 6) {
                Text(UpdateCheck.brewUpgradeCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    UpdateMonitor.copyBrewCommand()
                    copied = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Copy the brew upgrade command")
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
