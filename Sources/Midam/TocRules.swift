import Foundation

// The table of contents' rules that need no window: decoding what render.js reports.
// Checked by tools/TocTest (Foundation only).

/// One entry of a document's outline, as render.js reports it: plain text, never HTML.
struct Heading: Identifiable, Equatable {
    let id: Int // position in the outline (heading ids from raw HTML may repeat)
    let level: Int
    let text: String
    let anchor: String

    /// An outline from render.js, checked: h1-h4, bounded text and ids, at most 500. Nil when
    /// it is not an outline.
    static func outline(_ value: Any?) -> [Heading]? {
        guard let list = value as? [[String: Any]] else { return nil }
        return list.prefix(500).enumerated().compactMap { i, d in
            guard let level = d["level"] as? Int, (1...4).contains(level),
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

/// One row of the find list, as render.js reports it: the line around the match, split at the
/// match, and the headings it sits under. Plain text, bounded.
struct FindMatch: Identifiable, Equatable {
    let id: Int // the match's position in the page, 0-based (midamFindGo takes it)
    let before: String
    let hit: String
    let after: String
    let path: [String]

    /// A find call's result, {index, count, matches?}: index is the current match (1-based, 0 for
    /// none), count every match on the page, matches the first ≤500 of them (absent after a step or
    /// a jump, which leave the list as it was). Nil when it is not one.
    static func result(_ value: Any?) -> (index: Int, count: Int, matches: [FindMatch]?)? {
        guard let d = value as? [String: Any], let index = d["index"] as? Int, let count = d["count"] as? Int,
              count >= 0, (0...count).contains(index) else { return nil }
        guard let list = d["matches"] as? [[String: Any]] else { return (index, count, nil) }
        let text = { (v: Any?, n: Int) in String((v as? String ?? "").prefix(n)) }
        let matches = list.prefix(500).enumerated().map { i, m in
            FindMatch(id: i, before: text(m["before"], 200), hit: text(m["hit"], 200), after: text(m["after"], 200),
                      path: ((m["path"] as? [Any]) ?? []).prefix(6).map { text($0, 200) }.filter { !$0.isEmpty })
        }
        return (index, count, matches)
    }
}
