import Foundation

// The table of contents' rules that need no window: decoding what render.js reports.
// Checked by tools/TocTest (Foundation only).

/// One entry of a document's outline, as render.js reports it: plain text, never HTML.
struct Heading: Identifiable, Equatable {
    let id: Int // position in the outline (heading ids from raw HTML may repeat)
    let level: Int
    let text: String
    let anchor: String

    /// An outline from render.js, checked: h1-h3, bounded text and ids, at most 500. Nil when
    /// it is not an outline.
    static func outline(_ value: Any?) -> [Heading]? {
        guard let list = value as? [[String: Any]] else { return nil }
        return list.prefix(500).enumerated().compactMap { i, d in
            guard let level = d["level"] as? Int, (1...3).contains(level),
                  let text = d["text"] as? String, !text.isEmpty,
                  let anchor = d["id"] as? String, !anchor.isEmpty, anchor.utf16.count <= 512
            else { return nil }
            return Heading(id: i, level: level, text: String(text.prefix(200)), anchor: anchor)
        }
    }

    /// A render's result, {outline, current}: nil when it is not one (a render a newer one
    /// overtook returns nothing).
    static func toc(_ value: Any?) -> (outline: [Heading], current: String?)? {
        guard let d = value as? [String: Any], let list = outline(d["outline"]) else { return nil }
        return (list, anchor(d["current"], in: list))
    }

    /// An id from the page, taken only if the outline holds it (at most 512 UTF-16 units); else nil.
    static func anchor(_ value: Any?, in outline: [Heading]) -> String? {
        guard let id = value as? String, id.utf16.count <= 512, outline.contains(where: { $0.anchor == id }) else { return nil }
        return id
    }
}

/// The panel's one-time hint on a tab's first showing: transient, never the user's toggle
/// (Store.tocOpen). Times are seconds since the hint began.
enum TocIntro {
    static let hold = 1.8, afterLeave = 0.6, cap = 6.0

    /// The panel shows while the user has it open or the hint runs, if there is an outline.
    static func shown(available: Bool, open: Bool, intro: Bool) -> Bool { available && (open || intro) }

    /// Whether a tab's first showing starts the hint: once per tab, and not while open anyway.
    static func starts(introduced: Bool, available: Bool, open: Bool) -> Bool { available && !introduced && !open }

    /// When the hint ends: after `hold`; with the pointer on the panel, `afterLeave` after it
    /// leaves (but not before `hold`); never after `cap`, so a lost exit event cannot keep it.
    static func end(hovered: Bool, leftAt: Double?) -> Double {
        if hovered { return cap }
        guard let leftAt else { return hold }
        return min(cap, max(hold, leftAt + afterLeave))
    }
}
