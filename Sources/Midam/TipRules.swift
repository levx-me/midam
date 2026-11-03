import Foundation

// The header's fast tooltips, the rules that need no window. Checked by tools/TipTest.
enum TipRules {
    /// Hover this long before the first tooltip shows.
    static let delay = 0.4
    /// After one hides, the next shows at once for this long ("tooltip mode", as native).
    static let warm = 0.5
    /// Space kept to the window's edges.
    static let margin = 8.0

    /// How long to wait before showing a tooltip on entering a control at `now`: none while one
    /// shows or just after one hid, else `delay`.
    static func wait(now: Double, showing: Bool, lastHidden: Double?) -> Double {
        if showing { return 0 }
        if let lastHidden, now - lastHidden <= warm { return 0 }
        return delay
    }

    /// The tooltip's left edge: centred under its control, kept inside the window.
    static func x(mid: Double, width: Double, container: Double) -> Double {
        max(margin, min(mid - width / 2, container - margin - width))
    }

    /// Its top: just below the control; above it when there is no room below.
    static func y(top: Double, bottom: Double, height: Double, container: Double) -> Double {
        bottom + 6 + height + margin <= container ? bottom + 6 : top - 6 - height
    }
}
