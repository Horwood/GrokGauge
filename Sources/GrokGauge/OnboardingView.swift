import AppKit
import GrokGaugeCore
import SwiftUI

// MARK: - Window

/// The welcome tour window. Opens by itself once per Mac (first launch), and anytime from the gear menu's
/// "Show Welcome Tour…". The "seen" flag lives in this Mac's UserDefaults only, never the synced settings.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let defaults: UserDefaults
    private let makeView: (_ close: @escaping () -> Void) -> OnboardingView

    init(defaults: UserDefaults = .standard, makeView: @escaping (_ close: @escaping () -> Void) -> OnboardingView) {
        self.defaults = defaults
        self.makeView = makeView
    }

    func showIfNeeded() {
        let seen = defaults.object(forKey: OnboardingPolicy.seenRevisionKey) as? Int
        guard OnboardingPolicy.shouldShowAutomatically(seenRevision: seen) else { return }
        show()
    }

    func show() {
        // Marked as seen as soon as it opens: quitting mid-tour never brings it back on its own.
        OnboardingPolicy.markSeen(in: defaults)
        if window == nil {
            let host = NSHostingController(rootView: makeView { [weak self] in self?.close() })
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to GrokGauge"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // Same as the dropdown (0.9.4): a menu bar app has to become active *before* its window shows, or the
        // window isn't key and the first click or key press is lost.
        AppActivation.activateNow()
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

// MARK: - Tour

struct OnboardingView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    var cliState: () -> GrokCLIState
    var close: () -> Void
    @ViewState var step: OnboardingStep = .welcome
    /// Previews pass a fixed value so the shot doesn't depend on timing.
    @ViewState var cli: GrokCLIState? = nil

    static let size = CGSize(width: 500, height: 440)

    private var settings: GaugeSettings { settingsStore.settings }
    private var palette: Palette { Palette(settings) }

    var body: some View {
        VStack(spacing: 0) {
            page
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.palette, palette)
        .onAppear { if cli == nil { cli = cliState() } }
    }

    // MARK: Footer: Skip · dots · Back / Next

    private var footer: some View {
        HStack(spacing: 10) {
            if step.isLast {
                // Esc and Return still close the tour on the last card (it has its own Maybe later button).
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button(OnboardingCopy.laterButton, action: close)
                    .keyboardShortcut(.defaultAction)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            } else {
                Button("Skip", action: close)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the tour (Esc). Replay it anytime from the gear menu.")
                    .accessibilityLabel("Skip the tour")
                    .accessibilityHint("Closes the welcome tour. You can replay it from the gear menu.")
            }
            Spacer()
            dots
            Spacer()
            Button("Back") { go(step.previous) }
                .disabled(step.isFirst)
                .opacity(step.isFirst ? 0 : 1)
                .accessibilityHidden(step.isFirst)
            if let next = step.next {
                Button(next.isLast ? "Finish" : "Next") { go(next) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Goes to \(next.progressLabel.lowercased()): \(next.title)")
            }
        }
        .frame(height: 24)
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.progressLabel)
    }

    private func go(_ s: OnboardingStep?) {
        guard let s else { return }
        if s == .connect { cli = cliState() }
        step = s
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch step {
            case .welcome: welcome
            case .connect: connect
            case .rings: rings
            case .sharedPool: sharedPool
            case .menuBar: menuBar
            case .settingsSync: settingsSync
            case .historyPace: historyPace
            case .thanks: thanks
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(step.title), \(step.progressLabel.lowercased())")
    }

    private var header: some View {
        HStack(spacing: 12) {
            if step == .welcome, let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
            } else {
                Image(systemName: step.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(step == .thanks ? Color.pink : Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background((step == .thanks ? Color.pink : Color.accentColor).opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(step.progressLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func para(_ s: String) -> some View {
        Text(.init(s)).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ s: String, symbol: String = "info.circle") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(.init(s)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // 1. Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            para("GrokGauge shows how much of your weekly **SuperGrok** usage you've used, and Grok Bot's, as rings in the dropdown and a number in your menu bar. It refreshes on its own and can alert you before you run low.")
            para("This short tour takes about a minute. Press **Return** for the next card or **Esc** to skip.")
            note("**Unofficial.** GrokGauge is a free fan-made tool. It isn't affiliated with or endorsed by xAI. It reads usage data that can change without notice, so it could break. Use it at your own risk.",
                 symbol: "exclamationmark.shield")
        }
    }

    // 2. Connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: 12) {
            para("GrokGauge reads Grok usage with the **Grok CLI's** sign-in on this Mac. Your login is only read here. It's never written to sync files.")
            statusRow(cliRowState)
            if store.hasGrokBot {
                statusRow((true, "Grok Bot found", "Its ring shows up next to Grok's."))
            } else {
                statusRow((nil, "Grok Bot not found (optional)", "The Grok Bot ring appears once Grok Bot is set up on this Mac."))
            }
            switch cli ?? .signedIn {
            case .signedIn:
                EmptyView()
            case .signedOut:
                HStack {
                    Button("Copy “grok login”") { Launcher.copyLoginCommand() }
                    Button("Open Terminal") { Launcher.openTerminal() }
                    Spacer()
                    Button("Check Again") { recheck() }
                }
            case .notInstalled:
                HStack {
                    Button("Copy Install Command") { Launcher.copyInstallCommand() }
                    Button("Install in Terminal…") { Launcher.installCLIInTerminal() }
                    Spacer()
                    Button("Check Again") { recheck() }
                }
            }
        }
    }

    private var cliRowState: (Bool?, String, String) {
        switch cli ?? .signedIn {
        case .signedIn:
            return (true, "Signed in to Grok", "Found the Grok CLI's sign-in. You're all set.")
        case .signedOut:
            return (false, "Sign in to Grok", "The Grok CLI is installed. Run “grok login” in Terminal; GrokGauge notices when it finishes.")
        case .notInstalled:
            return (false, "Install the Grok CLI", "Install it with xAI's installer, then run “grok login”. The dropdown walks you through it too.")
        }
    }

    private func recheck() {
        cli = cliState()
        store.refreshIfStale(olderThan: 0)
    }

    /// ok: true = green check, false = orange warning, nil = neutral.
    private func statusRow(_ r: (ok: Bool?, title: String, detail: String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.ok == true ? "checkmark.circle.fill" : r.ok == false ? "exclamationmark.circle.fill" : "minus.circle")
                .font(.title3)
                .foregroundStyle(r.ok == true ? palette.color(.normal) : r.ok == false ? palette.color(.warning) : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.headline)
                Text(r.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.ok == true ? "Done" : r.ok == false ? "Needs attention" : "Optional"): \(r.title). \(r.detail)")
    }

    // 3. The rings

    private var rings: some View {
        VStack(alignment: .leading, spacing: 12) {
            para("**Grok** is your whole weekly pool across every product. **Grok Bot** is Grok Bot's usage (next card). The optional **Cursor** ring is Cursor's share of the pool.")
            HStack(spacing: 10) {
                ForEach(Array(OnboardingCopy.levelRanges(settings.thresholds).enumerated()), id: \.offset) { _, band in
                    HStack(spacing: 6) {
                        Circle().fill(palette.color(band.level)).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(OnboardingCopy.levelName(band.level)).font(.callout.weight(.semibold))
                            Text(band.range).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(OnboardingCopy.spokenRange(band.level, settings.thresholds))
                }
            }
            para(resetLine)
            note("Change the colors and where they switch in **Settings › Colors & Alerts**.", symbol: "paintpalette")
        }
    }

    private var resetLine: String {
        if let s = store.snapshot, let left = s.timeUntilReset(), let end = s.periodEnd {
            return "The pool resets every week. Yours resets in **\(UsageFormat.countdown(left))** (\(UsageFormat.resetDate(end)))."
        }
        return "The pool resets every week; the reset time is shown under the rings."
    }

    // 4. Shared pool

    private var sharedPool: some View {
        VStack(alignment: .leading, spacing: 12) {
            para("Grok Bot can draw from the same weekly pool as Grok. When GrokGauge sees that (the two readings match and reset together), the Grok Bot ring shows **Grok Bot's share of the Grok pool** instead of repeating the Grok number. It's captioned “share of Grok pool”.")
            para("Otherwise the Grok Bot ring shows Grok Bot's own weekly allowance.")
            note(sharedNow, symbol: "chart.pie")
        }
    }

    private var sharedNow: String {
        guard store.hasGrokBot else { return "Grok Bot isn't set up on this Mac, so you'll see the Grok ring only." }
        guard let r = store.botRing else { return "Right now: waiting for Grok Bot's first reading." }
        if r.isShared {
            return "Right now: Grok Bot is on the shared pool" + (r.roundedPercent.map { " and has used **\($0)%** of it." } ?? ".")
        }
        return "Right now: Grok Bot has its own weekly allowance."
    }

    // 5. Menu bar

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            para("The number next to the GrokGauge logo in your menu bar is colored like the rings. Click it to open the dropdown.")
            HStack {
                Spacer()
                menuBarSample
                Spacer()
            }
            para("Yours shows **\(MenuBarLayout.effectiveMode(settings.menuBarMode, hasGrokBot: store.hasGrokBot).title)**. You can also pick both percents (G · B), Grok only, Grok Bot only, or just the logo tinted by status, plus days until reset.")
            note("Change it in **Settings › Menu Bar**\(settings.hotKey.enabled ? ". Shortcut to open the dropdown: **\(settings.hotKey.display)**" : "").", symbol: "menubar.rectangle")
        }
    }

    private var menuBarSegments: [MenuBarSegment] {
        OnboardingCopy.menuBarExample(
            mode: settings.menuBarMode, grok: store.snapshot?.roundedPercent, bot: store.botRing?.roundedPercent,
            hasGrokBot: store.hasGrokBot, thresholds: settings.thresholds, showDays: settings.showDaysToReset,
            grokDays: store.snapshot?.timeUntilReset().map(UsageFormat.wholeDays),
            botDays: store.botRing?.timeUntilReset().map(UsageFormat.wholeDays))
    }

    private var menuBarSample: some View {
        let segs = menuBarSegments
        let text = segs.reduce(Text("")) { t, seg in
            t + Text(seg.text).foregroundColor(seg.level.map { palette.color($0) } ?? Color.white.opacity(0.6))
        }
        return HStack(spacing: 0) {
            Image(nsImage: GrokMarkImage.template(size: 16))
                .renderingMode(.template)
                .foregroundStyle(.white.opacity(0.92))
            text.font(.system(size: NSFont.systemFontSize, weight: .semibold).monospacedDigit())
            Text("      Mon 9:41 AM").font(.system(size: NSFont.systemFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar example: \(segs.map(\.text).joined().trimmingCharacters(in: .whitespaces))")
    }

    // 6. Settings & sync

    private var settingsSync: some View {
        VStack(alignment: .leading, spacing: 10) {
            para("Open **Settings** from the gear in the dropdown, or press ⌘, while it's open.")
            featureRow("paintpalette", "Colors & Alerts", "Move the warning and critical thresholds, pick colors (there's a colorblind-friendly set), and get alerts as you cross them.")
            featureRow("rectangle.3.group", "Layout", "Reorder or hide sections, pick a ring style, and turn on the optional Cursor ring.")
            featureRow("arrow.triangle.2.circlepath", "Sync", "Pick one folder your Macs already sync (Google Drive, iCloud Drive, Dropbox…). Your settings and 7-day usage history sync through it. Each has its own switch. Your Grok login is never copied.")
        }
    }

    private func featureRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.body).foregroundStyle(Color.accentColor).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // 7. History & pace

    private var historyPace: some View {
        VStack(alignment: .leading, spacing: 12) {
            para("The **Last 7 days & pace** section graphs each ring over the past week, with each weekly reset marked.")
            para("Under each graph, a pace line projects where you'll be at the reset. If you're on pace to run out early, it warns you, for example “At this pace you'll hit 100% by Fri 3 PM”.")
            note(paceNow, symbol: "speedometer")
        }
    }

    private var paceNow: String {
        guard let s = store.snapshot, let end = s.periodEnd else {
            return "Pick bars, lines or other graph styles in **Settings › Layout**."
        }
        let status = Pace.project(percent: s.percent, periodStart: s.periodStart ?? Pace.weeklyStart(forReset: end), periodEnd: end)
        return "Right now, Grok: **\(Pace.describe(status))**."
    }

    // 8. Thanks + tip

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 14) {
            para(OnboardingCopy.tipBody)
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(AppInfo.tipURL)
                    close()
                } label: {
                    Text(OnboardingCopy.tipButton).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Opens paypal.me/stevencombs in your browser")
                .accessibilityLabel(OnboardingCopy.tipButtonSpoken)
                .accessibilityHint("Opens PayPal in your browser and closes the tour")
                Button(OnboardingCopy.laterButton, action: close)
                    .controlSize(.large)
                    .accessibilityHint("Closes the tour. It won't ask again.")
            }
            Text(OnboardingCopy.tipFootnote).font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.red).accessibilityHidden(true)
                Text("Made by retroCombs. Watch on YouTube:").font(.callout).foregroundStyle(.secondary)
                Link(AppInfo.youTubeHandle, destination: AppInfo.youTubeURL).font(.callout)
                    .accessibilityLabel("retroCombs on YouTube, \(AppInfo.youTubeHandle)")
            }
        }
    }
}
