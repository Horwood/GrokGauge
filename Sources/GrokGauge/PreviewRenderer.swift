import AppKit
import GrokGaugeCore
import SwiftUI

/// Renders README images offscreen. Never prints or writes the token.
@MainActor
enum PreviewRenderer {
    static func render(to dir: URL, demo: Bool) async -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let snapshot: UsageSnapshot
        var bot: GrokBotSnapshot?
        var botProblem: BotProblem?
        if demo {
            snapshot = sample
            bot = sampleBot
        } else {
            do {
                snapshot = try await BillingClient(appVersion: AppInfo.version).fetch()
            } catch {
                FileHandle.standardError.write(Data("error: could not fetch usage (run --print-usage for details)\n".utf8))
                return 1
            }
            do { bot = try GrokBotUsageReader.read() } catch let e as GrokBotUsageError { botProblem = BotProblem(e) } catch { botProblem = .unrecognized }
        }
        let suffix = demo ? "-demo" : ""
        var ok = true
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            ok = renderPopover(snapshot, bot: bot, botProblem: botProblem, scheme: scheme,
                               to: dir.appendingPathComponent("popover-\(name)\(suffix).png")) && ok
        }
        let g = snapshot.roundedPercent
        let b = bot?.roundedPercent
        let titles: [[MenuBarSegment]] = demo
            ? [MenuBarTitle.segments(grok: g, bot: b, style: .highest),
               MenuBarTitle.segments(grok: g, bot: b, style: .both),
               MenuBarTitle.segments(grok: 95, bot: b, style: .highest)]
            : [MenuBarTitle.segments(grok: g, bot: b, style: .highest),
               MenuBarTitle.segments(grok: g, bot: b, style: .both)]
        ok = renderMenuBar(titles: titles, to: dir.appendingPathComponent("menubar\(suffix).png")) && ok
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

    private static func renderPopover(_ snapshot: UsageSnapshot, bot: GrokBotSnapshot?, botProblem: BotProblem?,
                                      scheme: ColorScheme, to url: URL) -> Bool {
        let store = UsageStore(notifier: UsageNotifier())
        store.showPreview(snapshot, bot: bot, botProblem: botProblem)
        let root = PopoverView(store: store, loginItem: LaunchAtLogin())
            .background(scheme == .dark ? Color(white: 0.15) : Color(white: 0.965))
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
        host.layoutSubtreeIfNeeded()
        host.display()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return write(rep, to: url)
    }

    private static func renderMenuBar(titles: [[MenuBarSegment]], to url: URL) -> Bool {
        let scale: CGFloat = 2
        let height: CGFloat = 30
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let neutral = NSColor.white.withAlphaComponent(0.6)
        let items: [NSAttributedString] = titles.map { segments in
            let t = NSMutableAttributedString()
            for seg in segments {
                t.append(NSAttributedString(string: seg.text, attributes: [
                    .font: font, .foregroundColor: seg.level?.nsColor ?? neutral]))
            }
            return t
        }
        let glyph = GrokMarkImage.template(size: 18)
        let gap: CGFloat = 28
        let widths = items.map { 18 + $0.size().width }
        let width = widths.reduce(0, +) + gap * CGFloat(max(0, items.count - 1)) + 32 + 120

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let tinted = NSImage(size: glyph.size, flipped: false) { r in
                glyph.draw(in: r)
                NSColor.white.withAlphaComponent(0.92).set()
                r.fill(using: .sourceAtop)
                return true
            }
            var x: CGFloat = 16
            for (i, title) in items.enumerated() {
                tinted.draw(in: NSRect(x: x, y: (height - 18) / 2, width: 18, height: 18))
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
