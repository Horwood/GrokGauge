import AppKit
import GrokGaugeCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var loginItem: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let snapshot = store.snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    GaugeSection(snapshot: snapshot, now: context.date)
                }
                ProductBreakdown(products: snapshot.products)
                CreditsCard(snapshot: snapshot)
                if let problem = store.problem {
                    InlineWarning(problem: problem)
                }
            } else if let problem = store.problem {
                ProblemCard(problem: problem) { store.refresh() }
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Checking usage…").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 120)
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

private struct GaugeSection: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RingGauge(fraction: snapshot.percent / 100, color: snapshot.level.color)
                VStack(spacing: 0) {
                    Text("\(snapshot.roundedPercent)%")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(snapshot.level.color)
                        .contentTransition(.numericText())
                    Text("used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 118, height: 118)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(snapshot.roundedPercent) percent used")

            VStack(alignment: .leading, spacing: 4) {
                Text("RESETS IN")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let left = snapshot.timeUntilReset(now: now), let end = snapshot.periodEnd {
                    let days = UsageFormat.wholeDays(left)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(days)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(days == 1 ? "day" : "days")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(UsageFormat.countdown(left))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(UsageFormat.resetDate(end))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("—").font(.title.bold())
                }
            }
            Spacer(minLength: 0)
        }
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
            Text("BY PRODUCT")
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
