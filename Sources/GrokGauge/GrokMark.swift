import AppKit
import SwiftUI

/// GrokGauge's own mark: an open ring with a diagonal slash leaving through the gap.
/// It is an original, simplified glyph that nods to Grok; it is not xAI's logo artwork.
enum GrokMarkGeometry {
    /// Stroke-based path in a y-down coordinate space (SwiftUI / flipped NSImage).
    static func path(in rect: CGRect) -> CGPath {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        let path = CGMutablePath()
        // Ring: 300° arc, gap centered on the upper-right diagonal.
        let r: CGFloat = 0.33
        var first = true
        for deg in stride(from: -15.0, through: 285.0, by: 2.5) {
            let a = deg * .pi / 180
            let pt = p(0.5 + r * CGFloat(cos(a)), 0.5 + r * CGFloat(sin(a)))
            if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
        }
        // Slash from inside the ring, out through the gap.
        path.move(to: p(0.30, 0.70))
        path.addLine(to: p(0.87, 0.13))
        return path
    }

    static let lineWidthRatio: CGFloat = 0.105
}

struct GrokMarkShape: Shape {
    func path(in rect: CGRect) -> Path { Path(GrokMarkGeometry.path(in: rect)) }
}

struct GrokMarkView: View {
    var size: CGFloat = 18
    var body: some View {
        GrokMarkShape()
            .stroke(style: StrokeStyle(lineWidth: size * GrokMarkGeometry.lineWidthRatio,
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum GrokMarkImage {
    /// Template image for the menu bar: adapts to light/dark/tinted menu bars automatically.
    static func template(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset = rect.insetBy(dx: size * 0.04, dy: size * 0.04)
            ctx.addPath(GrokMarkGeometry.path(in: inset))
            ctx.setLineWidth(size * GrokMarkGeometry.lineWidthRatio * 1.15)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GrokGauge"
        return image
    }
}
