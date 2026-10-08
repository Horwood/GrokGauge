import AppKit
import GrokGaugeCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var loginItem: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 12) {
                    RingsRow(store: store)
                    ResetCard(grokEnd: store.snapshot?.periodEnd,
                              botEnd: store.botSnapshot?.nextReset,
                              labelLines: store.hasGrokBot,
                              now: context.date)
                }
            }

            if let snapshot = store.snapshot {
                ProductBreakdown(products: snapshot.products)
                CreditsCard(snapshot: snapshot)
                if let problem = store.problem {
                    InlineWarning(problem: problem)
                }
            } else if let problem = store.problem {
                ProblemCard(problem: problem) { store.refresh() }
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
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
        }
    }

    private var planLabel: String {
        guard let s = store.snapshot else { return "SuperGrok" }
        return "SuperGrok · \(s.period.label)"
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Group {
                    if store.isRefreshing {
                        Text("Updating…")
                    } else if let at = store.snapshot?.fetchedAt {
                        Text("Updated \(at.formatted(date: .omitted, time: .shortened))")
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
            }

            Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) })) {
                Text("Launch at login").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if store.hasGrokBot {
                Toggle(isOn: Binding(get: { store.menuBarStyle == .both },
                                     set: { store.menuBarStyle = $0 ? .both : .highest })) {
                    Text("Show both percentages in menu bar").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            if let err = loginItem.lastError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                ActionButton(title: "Open Grok", systemImage: "safari") { Launcher.openGrok() }
                ActionButton(title: "Open Grok Bot", systemImage: "sparkles") { Launcher.openGrokBot() }
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

// MARK: - Gauge

private struct RingsRow: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 0) {
            grokRing.frame(maxWidth: .infinity)
            if store.hasGrokBot {
                botRing.frame(maxWidth: .infinity)
            }
        }
    }

    private var grokRing: some View {
        let s = store.snapshot
        let caption: String?
        if s != nil {
            caption = s?.period == .weekly ? "SuperGrok weekly" : s?.period.label
        } else if let p = store.problem {
            caption = p.needsLogin ? "Run `grok login`" : "Can't reach Grok"
        } else {
            caption = nil
        }
        return SourceRing(title: "Grok",
                          percent: s?.percent,
                          isLoading: s == nil && store.problem == nil,
                          caption: caption)
    }

    private var botRing: some View {
        let b = store.botSnapshot
        let problem = store.botProblem
        return SourceRing(title: "Grok Bot",
                          percent: b?.percent,
                          isLoading: false,
                          caption: b.map { "as of \($0.readAt.formatted(date: .omitted, time: .shortened))" } ?? problem?.caption,
                          action: problem?.opensGrokBot == true ? { Launcher.openGrokBot() } : nil)
    }
}

/// One labeled ring. `percent == nil` draws a neutral, empty ring.
private struct SourceRing: View {
    let title: String
    let percent: Double?
    let isLoading: Bool
    let caption: String?
    var action: (() -> Void)? = nil

    private var rounded: Int? { percent.map { Int(max(0, $0).rounded()) } }
    private var color: Color { rounded.map { UsageLevel.forPercent($0).color } ?? .gray }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RingGauge(fraction: (percent ?? 0) / 100, color: color, lineWidth: 11)
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 0) {
                        Text(rounded.map { "\($0)%" } ?? "—")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(rounded == nil ? Color.secondary : color)
                            .contentTransition(.numericText())
                        Text("used")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .opacity(rounded == nil ? 0 : 1)
                    }
                }
            }
            .frame(width: 104, height: 104)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rounded.map { "\(title): \($0) percent used" } ?? "\(title): no reading")

            Text(title)
                .font(.system(.callout, design: .rounded).weight(.semibold))
            Group {
                if let action, let caption {
                    Button(caption, action: action)
                        .buttonStyle(.link)
                } else if let caption {
                    Text(.init(caption)).foregroundStyle(.secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

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
        .accessibilityElement(children: .combine)
    }
}

struct RingGauge: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 13

    var body: some View {
        let f = min(1, max(0, fraction))
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: lineWidth)
            if f > 0 {
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.6), color],
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360 * f)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.35), radius: 4)
            }
        }
        .padding(lineWidth / 2)
        .animation(.spring(duration: 0.6), value: f)
    }
}

// MARK: - Cards

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            )
    }
}

extension View {
    fileprivate func card() -> some View { modifier(CardBackground()) }
}

private struct ProductBreakdown: View {
    let products: [ProductShare]

    var body: some View {
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
                                .fill(Color.accentColor.gradient)
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
            }
        }
        .card()
    }
}

private struct ProblemCard: View {
    let problem: UsageProblem
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: problem.needsLogin ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
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

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    // Standard bordered buttons pick up the system material automatically
    // (Liquid Glass on macOS 26+, classic bezel on 14–15).
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}
