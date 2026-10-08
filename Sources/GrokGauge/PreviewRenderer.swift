import AppKit
import GrokGaugeCore
import SwiftUI

/// Renders README images offscreen. Never prints or writes the token.
@MainActor
enum PreviewRenderer {
    static func render(to dir: URL, demo: Bool) async -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let snapshot: UsageSnapshot
        if demo {
            snapshot = sample
        } else {
            do {
                snapshot = try await BillingClient(appVersion: AppInfo.version).fetch()
            } catch {
                FileHandle.standardError.write(Data("error: could not fetch usage (run --print-usage for details)\n".utf8))
                return 1
            }
        }
        let suffix = demo ? "-demo" : ""
        var ok = true
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            ok = renderPopover(snapshot, scheme: scheme,
                               to: dir.appendingPathComponent("popover-\(name)\(suffix).png")) && ok
        }
        ok = renderMenuBar(percents: demo ? [42, 86, 95] : [snapshot.roundedPercent],
                           to: dir.appendingPathComponent("menubar\(suffix).png")) && ok
        print(ok ? "wrote previews to \(dir.path)" : "some previews failed")
        return ok ? 0 : 1
    }

    static var sample: UsageSnapshot {
        let now = Date()
        func share(_ key: String, _ name: String, _ symbol: String, _ p: Double) -> ProductShare {
            ProductShare(key: key, name: name, symbol: symbol, percent: p)
        }
        return UsageSnapshot(
            percent: 86.4, percentInferred: false, period: .weekly,
            periodStart: now.addingTimeInterval(-4.2 * 86_400),
            periodEnd: now.addingTimeInterval(2.8 * 86_400),
            products: [
                share("GrokChat", "Chat", "bubble.left.and.bubble.right.fill", 41.0),
                share("GrokImagine", "Imagine", "photo.on.rectangle.angled", 22.5),
                share("GrokVoice", "Voice", "waveform", 6.9),
                share("GrokBuild", "Build", "hammer.fill", 14.0),
                share("Api", "API", "curlybraces", 2.0),
            ],
            prepaidBalanceCents: 1_446, onDemandUsedCents: 0, onDemandCapCents: 0,
            fetchedAt: now)
    }

    private static func renderPopover(_ snapshot: UsageSnapshot, scheme: ColorScheme, to url: URL) -> Bool {
        let store = UsageStore(notifier: UsageNotifier())
        store.showPreview(snapshot)
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

    private static func renderMenuBar(percents: [Int], to url: URL) -> Bool {
        let scale: CGFloat = 2
        let height: CGFloat = 30
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let items: [(NSImage, NSAttributedString)] = percents.map { p in
            let color = UsageLevel.forPercent(p).nsColor
            return (GrokMarkImage.template(size: 18),
                    NSAttributedString(string: " \(p)%", attributes: [.font: font, .foregroundColor: color]))
        }
        let gap: CGFloat = 28
        let widths = items.map { 18 + $0.1.size().width }
        let width = widths.reduce(0, +) + gap * CGFloat(items.count - 1) + 32 + 120

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            var x: CGFloat = 16
            for (i, (glyph, title)) in items.enumerated() {
                let tinted = NSImage(size: glyph.size, flipped: false) { r in
                    glyph.draw(in: r)
                    NSColor.white.withAlphaComponent(0.92).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: x, y: (height - 18) / 2, width: 18, height: 18))
                let size = title.size()
                title.draw(at: NSPoint(x: x + 18, y: (height - size.height) / 2))
                x += widths[i] + gap
            }
            // A few neutral system-style glyphs so it reads as a menu bar.
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
