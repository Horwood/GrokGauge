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
            historyStore = HistoryStore.preview(HistoryStore.demoHistory(grokNow: sample.percent, botNow: sampleBot.percent))
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
        let suffix = demo ? "-demo" : ""
        var ok = true

        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            let view = PopoverView(store: store, settingsStore: settings, history: historyStore,
                                   updates: UpdateMonitor.preview(available: nil, lastChecked: nil))
            ok = renderView(view, scheme: scheme, background: true,
                            to: dir.appendingPathComponent("popover-\(name)\(suffix).png")) && ok
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
            let variants: [(String, GaugeSettings, UsageStore)] = [
                ("stacked-colorblind", stacked, store),
                ("combined-compact", combined, store),
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
                                       updates: UpdateMonitor.preview(available: nil, lastChecked: nil))
                ok = renderView(view, scheme: .dark, background: true,
                                to: dir.appendingPathComponent("popover-\(name)-dark-demo.png")) && ok
            }
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
            ? UpdateMonitor.preview(available: ReleaseInfo(tag: "v0.9.2", url: URL(string: "https://github.com/stevencombs/GrokGauge/releases/tag/v0.9.2")!),
                                    lastChecked: Date().addingTimeInterval(-3 * 3600))
            : UpdateMonitor.preview(available: nil, lastChecked: Date())
        let expiry = demo ? Date().addingTimeInterval(5.5 * 3600) : store.grokTokenExpiry()
        for tab in PrefsTab.allCases {
            let view = PreferencesView(settingsStore: prefsSettings, store: store, updates: updates,
                                       loginItem: LaunchAtLogin(), hotKeys: HotKeyCenter.shared,
                                       tab: tab, scrollable: false, tokenExpiry: { expiry })
            ok = renderView(view, scheme: .dark, background: true,
                            to: dir.appendingPathComponent("prefs-\(tab.rawValue)\(suffix).png")) && ok
        }

        let g = snapshot.roundedPercent
        let b = bot?.roundedPercent
        let gd = snapshot.timeUntilReset().map(UsageFormat.wholeDays)
        let bd = bot?.timeUntilReset().map(UsageFormat.wholeDays)
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
            products: [
                share("GrokChat", "Chat", "bubble.left.and.bubble.right.fill", 20.1),
                share("GrokImagine", "Imagine", "photo.on.rectangle.angled", 10.4),
                share("GrokVoice", "Voice", "waveform", 3.5),
                share("GrokBuild", "Build", "hammer.fill", 6.2),
                share("Api", "API", "curlybraces", 2.0),
            ],
            prepaidBalanceCents: 1_446, onDemandUsedCents: 0, onDemandCapCents: 0,
            fetchedAt: now)
    }

    static var sampleBot: GrokBotSnapshot {
        let now = Date()
        return GrokBotSnapshot(percent: 86.3, nextReset: now.addingTimeInterval(3.6 * 86_400),
                               readAt: now.addingTimeInterval(-6 * 60), expiresAt: now.addingTimeInterval(86_400),
                               planLabel: "SuperGrok Plus")
    }

    private static func renderView<V: View>(_ view: V, scheme: ColorScheme, background: Bool, to url: URL) -> Bool {
        let root = view
            .background(background ? (scheme == .dark ? Color(white: 0.15) : Color(white: 0.965)) : .clear)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.setFrameSize(host.fittingSize)

        // A real (but off-screen) window so AppKit-backed controls draw normally.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.setFrameSize(host.fittingSize)
        window.setContentSize(host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.display()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return write(rep, to: url)
    }

    struct MenuBarItem {
        let segments: [MenuBarSegment]
        let logoColor: NSColor?
    }

    private static func renderMenuBar(items: [MenuBarItem], palette: Palette, to url: URL) -> Bool {
        let scale: CGFloat = 2
        let height: CGFloat = 30
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let neutral = NSColor.white.withAlphaComponent(0.6)
        let titles: [NSAttributedString] = items.map { item in
            let t = NSMutableAttributedString()
            for seg in item.segments {
                t.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font, .foregroundColor: seg.level.map { palette.nsColor($0) } ?? neutral]))
            }
            return t
        }
        let glyph = GrokMarkImage.template(size: 18)
        let gap: CGFloat = 28
        let widths = titles.map { 18 + $0.size().width }
        let width = widths.reduce(0, +) + gap * CGFloat(max(0, titles.count - 1)) + 32 + 120

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
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
                tinted(items[i].logoColor ?? NSColor.white.withAlphaComponent(0.92))
                    .draw(in: NSRect(x: x, y: (height - 18) / 2, width: 18, height: 18))
                let size = title.size()
                title.draw(at: NSPoint(x: x + 18, y: (height - size.height) / 2))
                x += widths[i] + gap
            }
            // A neutral system-style clock so it reads as a menu bar.
            let clock = NSAttributedString(string: "Wed 3:57 PM", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
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
