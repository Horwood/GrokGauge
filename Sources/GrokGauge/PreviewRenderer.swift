import AppKit
import GrokGaugeCore
import SwiftUI

/// Renders README images offscreen (no Screen Recording permission needed).
/// Never prints or writes the token; previews use inert settings and never touch the sync folder.
@MainActor
enum PreviewRenderer {
    static func render(to dir: URL, demo: Bool) async -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let snapshot: UsageSnapshot
        var bot: GrokBotSnapshot?
        var botProblem: BotProblem?
        let historyStore: HistoryStore
        if demo {
            snapshot = sample
            bot = sampleBot
            // Grok Bot is on the shared pool in the demo (as for SuperGrok since mid-October 2026): its ring and
            // history are its share of the pool.
            let share = BotRingReading.make(bot: sampleBot, pool: sample, knownSharedEnd: nil).percent ?? 0
            historyStore = HistoryStore.preview(HistoryStore.demoHistory(grokNow: sample.percent, botNow: share, botShared: true))
        } else {
            do {
                snapshot = try await BillingClient(appVersion: AppInfo.version).fetch()
            } catch {
                FileHandle.standardError.write(Data("error: could not fetch usage (run --print-usage for details)\n".utf8))
                return 1
            }
            do { bot = try GrokBotUsageReader.read() } catch let e as GrokBotUsageError { botProblem = BotProblem(e) } catch { botProblem = .unrecognized }
            historyStore = HistoryStore.preview(UsageHistory.load())
        }
        let store = UsageStore(notifier: UsageNotifier())
        store.showPreview(snapshot, bot: bot, botProblem: botProblem)
        let settings = SettingsStore.preview()
        let whatsNew = demo ? WhatsNewStore.preview(WhatsNewStore.demoState()) : WhatsNewStore.savedPreview()
        let suffix = demo ? "-demo" : ""
        // Real runs read the live public status pages once; demo runs show both services normal.
        let status = demo ? ServiceStatusStore.demo() : await ServiceStatusStore.fetchedOnce()
        var ok = true

        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            let view = PopoverView(store: store, settingsStore: settings, history: historyStore,
                                   updates: UpdateMonitor.preview(available: nil, lastChecked: nil), whatsNew: whatsNew,
                                   sizing: PopoverSizing(), status: status)
            ok = renderView(view, scheme: scheme, background: true,
                            to: dir.appendingPathComponent("popover-\(name)\(suffix).png")) && ok
        }

        // All four rings (Total, Grok, Grok Bot and the optional Cursor ring): slightly smaller rings in a wider
        // dropdown, and rings shrunk to the usual width.
        for sizing in RingSizing.allCases {
            var four = GaugeSettings()
            four.sections = four.sections.map { item in
                var i = item
                if i.id == .cursorRing { i.visible = true }
                return i
            }
            four.ringSizing = sizing
            for scheme in [ColorScheme.dark, .light] {
                let view = PopoverView(store: store, settingsStore: SettingsStore.preview(four), history: historyStore,
                                       updates: UpdateMonitor.preview(available: nil, lastChecked: nil), whatsNew: whatsNew,
                                       sizing: PopoverSizing(), status: status)
                ok = renderView(view, scheme: scheme, background: true,
                                to: dir.appendingPathComponent("popover-four-rings-\(sizing.rawValue)-\(scheme == .dark ? "dark" : "light")\(suffix).png")) && ok
            }
        }

        if demo {
            // Layout variants and the "xAI changed something" state, for docs and review.
            var stacked = GaugeSettings()
            stacked.ringStyle = .stacked
            stacked.colors = .colorblindFriendly
            var combined = GaugeSettings()
            combined.ringStyle = .combined
            combined.sections = combined.sections.map { item in
                var i = item
                if [.productBreakdown, .credits].contains(i.id) { i.visible = false }
                return i
            }
            var news = GaugeSettings()
            news.sections = news.sections.map { item in
                var i = item
                if [.historyPace, .resetDates, .productBreakdown, .credits].contains(i.id) { i.visible = false }
                return i
            }
            let variants: [(String, GaugeSettings, UsageStore)] = [
                ("whatsnew", news, store),
                ("stacked-colorblind", stacked, store),
                ("combined-compact", combined, store),
                ("cli-setup", GaugeSettings(), {
                    let s = UsageStore(notifier: UsageNotifier())
                    s.showPreview(nil, problem: .cliNotInstalled, bot: bot, botProblem: botProblem)
                    return s
                }()),
                ("changed-shape", GaugeSettings(), {
                    let s = UsageStore(notifier: UsageNotifier())
                    s.showPreview(nil, problem: .changedShape, bot: bot, botProblem: botProblem)
                    return s
                }()),
            ]
            // The same dropdown in each history graph style.
            let styles: [(String, GaugeSettings, UsageStore)] = GraphStyle.allCases.map { style in
                var g = GaugeSettings()
                g.graphStyle = style
                return ("graph-\(style.rawValue)", g, store)
            }
            for (name, s, st) in variants + styles {
                let view = PopoverView(store: st, settingsStore: SettingsStore.preview(s), history: historyStore,
                                       updates: UpdateMonitor.preview(available: nil, lastChecked: nil), whatsNew: whatsNew,
                                   sizing: PopoverSizing(), status: status)
                ok = renderView(view, scheme: .dark, background: true,
                                to: dir.appendingPathComponent("popover-\(name)-dark-demo.png")) && ok
            }
        }

        if demo {
            // An 800 pt tall screen (a 13" MacBook Air at a larger text size): the middle scrolls,
            // the rings and the buttons/footer stay put.
            let visible = 800.0 - 25          // minus the menu bar
            let short = PopoverView(store: store, settingsStore: SettingsStore.preview(), history: historyStore,
                                    updates: UpdateMonitor.preview(available: nil, lastChecked: nil), whatsNew: whatsNew,
                                    sizing: PopoverSizing(maxHeight: CGFloat(PopoverLayout.maxContentHeight(visibleHeight: visible))), status: status)
            ok = renderView(short, scheme: .dark, background: true,
                            to: dir.appendingPathComponent("popover-short-screen-dark-demo.png")) && ok
        }

        // Preferences tabs (dark), with data that shows each control in a realistic state.
        let prefsSettings: SettingsStore
        if demo {
            prefsSettings = SettingsStore.preview(
                GaugeSettings(), syncFolder: URL(fileURLWithPath: NSHomeDirectory() + "/Google Drive/MacSyncing"),
                state: .synced(Date().addingTimeInterval(-90)))
        } else {
            prefsSettings = SettingsStore.preview()
        }
        let updates = demo
            ? UpdateMonitor.preview(available: nil, lastChecked: Date().addingTimeInterval(-3 * 3600))
            : UpdateMonitor.preview(available: nil, lastChecked: Date())
        let expiry = demo ? Date().addingTimeInterval(5.5 * 3600) : store.grokTokenExpiry()
        // History sync as it looks with three Macs (one Insync conflict copy merged, one partial file skipped).
        let prefsHistory: HistoryStore
        if demo {
            let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Google-Drive/Computers/Mac/MacSyncing", isDirectory: true)
            prefsHistory = HistoryStore.preview(historyStore.history, sync: HistoryStore.SyncStatus(
                enabled: true, folder: folder, origin: .detected,
                ownFile: HistorySync.fileURL(inSyncFolder: folder, machineID: "3f9c2a7d41b08e55"),
                machineCount: 3, machineNames: ["Air-M4", "MacBook Pro M2 Max", "Studio M2"],
                lastSync: Date().addingTimeInterval(-75), skipped: [HistorySyncSkip(fileName: "7be1d0c94a2f6e13.json", reason: "unreadable or partial JSON")],
                conflictCopies: ["3f9c2a7d41b08e55 (1).json"], lastError: nil))
        } else {
            prefsHistory = HistoryStore.preview(historyStore.history)
        }
        for tab in PrefsTab.allCases {
            let view = PreferencesView(settingsStore: prefsSettings, store: store, updates: updates,
                                       loginItem: LaunchAtLogin(), hotKeys: HotKeyCenter.shared, whatsNew: whatsNew,
                                       history: prefsHistory, status: status, tab: tab, scrollable: false, tokenExpiry: { expiry })
            ok = renderView(view, scheme: .dark, background: true,
                            to: dir.appendingPathComponent("prefs-\(tab.rawValue)\(suffix).png")) && ok
            if tab == .about || tab == .whatsNew {
                ok = renderView(view, scheme: .light, background: true,
                                to: dir.appendingPathComponent("prefs-\(tab.rawValue)-light\(suffix).png")) && ok
            }
        }

        if demo {
            // "Grok by product" with a custom setup: Highest usage first, Voice hidden, a reordered list.
            // Labeled "Example data" because the numbers are the demo sample, not a real account.
            var custom = GaugeSettings()
            custom.productBreakdown = ProductBreakdownSettings(
                order: [ProductToggle("Build"), ProductToggle("Chat"), ProductToggle("API"),
                        ProductToggle("Imagine"), ProductToggle("Voice", visible: false)],
                sort: .usage)
            let customStore = SettingsStore.preview(custom)
            let pop = PopoverView(store: store, settingsStore: customStore, history: historyStore,
                                  updates: UpdateMonitor.preview(available: nil, lastChecked: nil), whatsNew: whatsNew,
                                  sizing: PopoverSizing(), status: status)
            ok = renderView(exampleLabeled(pop), scheme: .dark, background: true,
                            to: dir.appendingPathComponent("popover-products-sorted-example.png")) && ok
            let prefs = PreferencesView(settingsStore: customStore, store: store, updates: updates,
                                        loginItem: LaunchAtLogin(), hotKeys: HotKeyCenter.shared, whatsNew: whatsNew,
                                        history: prefsHistory, status: status, tab: .layout, scrollable: false, tokenExpiry: { expiry })
            ok = renderView(exampleLabeled(prefs), scheme: .dark, background: true,
                            to: dir.appendingPathComponent("prefs-layout-products-example.png")) && ok
        }

        if demo {
            // The status row during an incident: labeled "Example data" because these readings are made up.
            let now = Date().addingTimeInterval(-60)
            let outage = ServiceStatusStore.demo(
                xai: ServiceStatusReport(source: .xai, health: .degraded, affected: ["Imagine"], incidents: ["Imagine generations slow"],
                                         via: ServiceSource.xai.summaryURL, checkedAt: now),
                cursor: ServiceStatusReport(source: .cursor, health: .outage, affected: ["Cloud Agents"], pageDescription: "Partial System Outage",
                                            incidents: ["Cloud Agents failing to start"], via: ServiceSource.cursor.summaryURL, checkedAt: now))
            let pop = PopoverView(store: store, settingsStore: SettingsStore.preview(), history: historyStore,
                                  updates: UpdateMonitor.preview(available: nil, lastChecked: nil), whatsNew: whatsNew,
                                  sizing: PopoverSizing(), status: outage)
            ok = renderView(exampleLabeled(pop), scheme: .dark, background: true,
                            to: dir.appendingPathComponent("popover-status-outage-example.png")) && ok
        }

        let g = snapshot.roundedPercent
        // B is the Grok Bot ring's number: its share of the pool when shared, never its whole-pool reading.
        let ring = bot.map { BotRingReading.make(bot: $0, pool: snapshot, knownSharedEnd: nil) }
        let b = MenuBarLayout.botPercent(ring)
        let gd = snapshot.timeUntilReset().map(UsageFormat.wholeDays)
        let bd = ring?.timeUntilReset().map(UsageFormat.wholeDays)
        let palette = Palette.standard
        func item(_ mode: MenuBarMode, days: Bool = false, grok: Int? = nil) -> MenuBarItem {
            let gg = grok ?? g
            let level = mode == .logoOnly ? MenuBarLayout.logoLevel(grok: gg, bot: b) : nil
            return MenuBarItem(segments: MenuBarLayout.segments(grok: gg, bot: b, grokDays: gd, botDays: bd, mode: mode, showDays: days),
                               logoColor: level.map(palette.nsColor))
        }
        let items: [MenuBarItem] = demo
            ? [item(.highest), item(.both), item(.highest, days: true), item(.logoOnly), item(.grokOnly, grok: 95)]
            : [item(.highest), item(.both)]
        ok = renderMenuBar(items: items, palette: palette, to: dir.appendingPathComponent("menubar\(suffix).png")) && ok
        ok = renderMenuBar(items: items, palette: palette, light: true,
                           to: dir.appendingPathComponent("menubar-light\(suffix).png")) && ok
        print(ok ? "wrote previews to \(dir.path)" : "some previews failed")
        return ok ? 0 : 1
    }

    static var sample: UsageSnapshot {
        let now = Date()
        func share(_ key: String, _ name: String, _ symbol: String, _ p: Double) -> ProductShare {
            ProductShare(key: key, name: name, symbol: symbol, percent: p)
        }
        return UsageSnapshot(
            percent: 42.2, percentInferred: false, period: .weekly,
            periodStart: now.addingTimeInterval(-4.2 * 86_400),
            periodEnd: now.addingTimeInterval(2.8 * 86_400),
            // Adds up to the 42.2% pool; Grok Bot's 27% share is what its ring and the menu bar's B show.
            products: [
                share("GrokBot", "Grok Bot", "sparkles", 27.0),
                share("GrokChat", "Chat", "bubble.left.and.bubble.right.fill", 7.4),
                share("GrokImagine", "Imagine", "photo.on.rectangle.angled", 3.1),
                share("GrokVoice", "Voice", "waveform", 1.0),
                share("GrokBuild", "Build", "hammer.fill", 2.2),
                share("Api", "API", "curlybraces", 0.4),
                share("Cursor", "Cursor", "square.grid.2x2.fill", 1.1),
            ],
            prepaidBalanceCents: 1_446, onDemandUsedCents: 0, onDemandCapCents: 0,
            fetchedAt: now)
    }

    static var sampleBot: GrokBotSnapshot {
        let now = Date()
        // On the shared pool: Grok Bot's own reading is the whole pool (same reset), so the ring shows its share.
        return GrokBotSnapshot(percent: 42.6, nextReset: now.addingTimeInterval(2.8 * 86_400),
                               readAt: now.addingTimeInterval(-6 * 60), expiresAt: now.addingTimeInterval(86_400),
                               planLabel: "SuperGrok Plus")
    }

    /// Adds an "Example data" caption above a preview.
    private static func exampleLabeled<V: View>(_ view: V) -> some View {
        VStack(spacing: 0) {
            Text("Example data")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
                .padding(.top, 8)
            view
        }
    }

    static func renderView<V: View>(_ view: V, scheme: ColorScheme, background: Bool, to url: URL) -> Bool {
        let root = view
            .background(background ? (scheme == .dark ? Color(white: 0.15) : Color(white: 0.965)) : .clear)
            .environment(\.colorScheme, scheme)
            // Draw controls as in the frontmost window (accent-colored default buttons and switches), not greyed out.
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.setFrameSize(host.fittingSize)

        // A real (but off-screen) window so AppKit-backed controls draw normally.
        let window = PreviewWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.setFrameSize(host.fittingSize)
        window.setContentSize(host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.display()

        // Always 2x pixels, so shots look the same from a Retina or a non-Retina Mac.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((host.bounds.width * scale).rounded()),
                                         pixelsHigh: Int((host.bounds.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return write(rep, to: url)
    }

    /// Off-screen window that reports itself as key and main, so AppKit-backed controls (buttons, switches)
    /// render in their active colors instead of the greyed inactive-window look.
    private final class PreviewWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    struct MenuBarItem {
        let segments: [MenuBarSegment]
        let logoColor: NSColor?
    }

    private static func renderMenuBar(items: [MenuBarItem], palette: Palette, light: Bool = false, to url: URL) -> Bool {
        let scale: CGFloat = 2
        let height: CGFloat = 30
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        // Uncolored text (days left, separators) at full label strength, like NSColor.labelColor in the real menu bar.
        let foreground = light ? NSColor.black.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.92)
        let titles: [NSAttributedString] = items.map { item in
            let t = NSMutableAttributedString()
            for seg in item.segments {
                t.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font, .foregroundColor: seg.level.map { palette.nsColor($0) } ?? foreground]))
            }
            return t
        }
        let glyph = GrokMarkImage.template(size: 18)
        let gap: CGFloat = 28
        let widths = titles.map { 18 + $0.size().width }
        let width = widths.reduce(0, +) + gap * CGFloat(max(0, titles.count - 1)) + 32 + 120

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(calibratedWhite: light ? 0.9 : 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            func tinted(_ color: NSColor) -> NSImage {
                NSImage(size: glyph.size, flipped: false) { r in
                    glyph.draw(in: r)
                    color.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
            }
            var x: CGFloat = 16
            for (i, title) in titles.enumerated() {
                tinted(items[i].logoColor ?? foreground)
                    .draw(in: NSRect(x: x, y: (height - 18) / 2, width: 18, height: 18))
                let size = title.size()
                title.draw(at: NSPoint(x: x + 18, y: (height - size.height) / 2))
                x += widths[i] + gap
            }
            // A neutral system-style clock so it reads as a menu bar.
            let clock = NSAttributedString(string: "Wed 3:57 PM", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: foreground])
            clock.draw(at: NSPoint(x: rect.maxX - clock.size().width - 14, y: (height - clock.size().height) / 2))
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: scale)]) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        return write(rep, to: url)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url) } catch { return false }
        return true
    }
}

/// Used only by --render-preview / --render-tour (never by the menu bar app): an application that reports itself
/// active without activating, so AppKit switches draw "on" in the accent color instead of the inactive grey.
final class PreviewApplication: NSApplication {
    override var isActive: Bool { true }
}
