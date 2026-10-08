import AppKit
import GrokGaugeCore
import SwiftUI

extension RGBAColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    init?(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent),
                  blue: Double(c.blueComponent), alpha: 1)
    }
}

/// Level colors + boundaries currently in effect. `nil` colors mean the system color,
/// which adapts to light/dark mode and Increase Contrast on its own.
struct Palette: Equatable {
    var colors: LevelColors
    var thresholds: LevelThresholds

    static let standard = Palette(colors: .system, thresholds: .standard)

    init(colors: LevelColors, thresholds: LevelThresholds) {
        self.colors = colors
        self.thresholds = thresholds
    }

    init(_ s: GaugeSettings) {
        self.init(colors: s.colors, thresholds: s.thresholds)
    }

    func level(_ roundedPercent: Int) -> UsageLevel { thresholds.level(forRoundedPercent: roundedPercent) }

    func nsColor(_ level: UsageLevel) -> NSColor {
        if let c = colors.color(for: level) { return c.nsColor }
        switch level {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    func color(_ level: UsageLevel) -> Color { Color(nsColor: nsColor(level)) }

    func color(forRounded p: Int?) -> Color {
        guard let p else { return .gray }
        return color(level(p))
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.standard
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension UsageLevel {
    /// Spoken level name for VoiceOver.
    var spoken: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

/// `@State` is a compiler macro in recent SDKs, and the Command Line Tools don't ship SwiftUI's
/// macro plugin. Using the underlying property-wrapper type through an alias behaves the same
/// and builds with or without Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>
