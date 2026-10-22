import Foundation

/// Height rules for the dropdown, so it never grows past the screen: the header and rings stay pinned
/// at the top, the Updated/Refresh row, buttons and footer stay pinned at the bottom, and everything in
/// between scrolls when there isn't room.
public enum PopoverLayout {
    /// Room left for the popover's arrow and a little breathing space below the menu bar and above the Dock.
    public static let screenMargin: Double = 34
    /// The scrolling middle never shrinks below this (on very small screens the popover may still overflow).
    public static let minimumScroll: Double = 140

    /// Tallest the popover's content may be on a screen whose `visibleFrame` (below the menu bar,
    /// above the Dock) is `visibleHeight` points tall.
    public static func maxContentHeight(visibleHeight: Double, margin: Double = screenMargin) -> Double {
        max(320, visibleHeight - margin)
    }

    /// Height for the scrolling middle: all of it when it fits, otherwise what's left after the pinned parts.
    /// `fixed` is everything else (pinned top and bottom, spacing, padding). `maxHeight` nil means no limit.
    public static func scrollHeight(content: Double, fixed: Double, maxHeight: Double?) -> Double {
        guard content > 0 else { return 0 }
        guard let maxHeight else { return content }
        return min(content, max(minimumScroll, maxHeight - fixed))
    }

    /// Splits an ordered list of blocks into a pinned top run, a scrolling middle and a pinned bottom run.
    /// Only blocks at the very start (`pinTop`) or very end (`pinBottom`) are pinned.
    public static func partition(count: Int, pinTop: (Int) -> Bool, pinBottom: (Int) -> Bool)
        -> (top: Range<Int>, middle: Range<Int>, bottom: Range<Int>) {
        var t = 0
        while t < count && pinTop(t) { t += 1 }
        var b = count
        while b > t && pinBottom(b - 1) { b -= 1 }
        return (0..<t, t..<b, b..<count)
    }

    // MARK: Width and ring size (0.9.3: optional third ring; then a fourth, the Grok ring next to Total)

    /// The usual dropdown width (points).
    public static let standardWidth: Double = 320
    /// Wide enough for three full-size rings side by side.
    public static let wideWidth: Double = 392
    /// Wide enough for four slightly smaller rings side by side.
    public static let widerWidth: Double = 416
    public static let standardRing: Double = 104
    /// Three rings in the usual width, or four in the wider dropdown.
    public static let compactRing: Double = 84
    /// Four rings in the usual width.
    public static let smallRing: Double = 64

    /// Dropdown width for `ringCount` rings drawn side by side (or not).
    public static func width(ringCount: Int, sideBySide: Bool, sizing: RingSizing) -> Double {
        guard sideBySide && sizing == .keepSize else { return standardWidth }
        if ringCount >= 4 { return widerWidth }
        return ringCount >= 3 ? wideWidth : standardWidth
    }

    /// Ring diameter for `ringCount` rings side by side.
    public static func ringDiameter(ringCount: Int, sizing: RingSizing) -> Double {
        if ringCount >= 4 { return sizing == .fitWidth ? smallRing : compactRing }
        return ringCount >= 3 && sizing == .fitWidth ? compactRing : standardRing
    }
}
