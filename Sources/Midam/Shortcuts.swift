import SwiftUI

/// Every key the menus bind, named once: the menus use these, and the shortcuts help shows them,
/// so the two cannot drift. Keys handled outside the menus (⇧⌘[ ], ⌃⌘F, ⌘1-8) are listed as text.
/// Bare keys (Space, j k g G d u e f b, n N, m, /, x) are menu items too; Store.singleKeyBypass keeps
/// them out of text fields and other windows.
extension KeyboardShortcut {
    static let open = KeyboardShortcut("o")
    static let newAgent = KeyboardShortcut("n")
    static let clearScrollback = KeyboardShortcut("k") // in an agent's terminal tab, as in Terminal
    static let newTab = KeyboardShortcut("t") // into the sidebar's list, as a browser's new tab; ⇧⌘T is kept for reopening a closed tab
    static let closeTab = KeyboardShortcut("w")
    static let closeTabX = KeyboardShortcut("x", modifiers: []) // as in Vimium
    static let showInFinder = KeyboardShortcut("r", modifiers: [.command, .option])
    static let find = KeyboardShortcut("f")
    static let findSlash = KeyboardShortcut("/", modifiers: [])
    static let findNext = KeyboardShortcut("g")
    static let findPrevious = KeyboardShortcut("g", modifiers: [.command, .shift])
    static let switchView = KeyboardShortcut("/")
    static let tableOfContents = KeyboardShortcut("t", modifiers: [.command, .option])
    static let panel = KeyboardShortcut("i", modifiers: [.command, .option]) // the inspector's, as in Pages and Keynote
    static let shortcuts = KeyboardShortcut("'") // not ⌘?: macOS keeps that for Help search
    static let immersive = KeyboardShortcut("f", modifiers: [.command, .shift])
    static let reload = KeyboardShortcut("r")
    static let sidebar = KeyboardShortcut("s", modifiers: [.control, .command]) // macOS's own for sidebars
    static let sidebarSafari = KeyboardShortcut("l", modifiers: [.command, .shift]) // Safari's
    static let unreadOnly = KeyboardShortcut("u", modifiers: [.command, .option]) // the unread filter beside the sidebar button
    static let nextTab = KeyboardShortcut(.tab, modifiers: .control)
    static let previousTab = KeyboardShortcut(.tab, modifiers: [.control, .shift])
    static func tab(_ n: Int) -> KeyboardShortcut { KeyboardShortcut(KeyEquivalent(Character(String(n)))) } // 1…8
    static let lastTab = KeyboardShortcut("9")
    static let back = KeyboardShortcut("[")
    static let forward = KeyboardShortcut("]")
    static let top = KeyboardShortcut(.upArrow)
    static let bottom = KeyboardShortcut(.downArrow)
    static let pageDown = KeyboardShortcut(.space, modifiers: [])
    static let pageUp = KeyboardShortcut(.space, modifiers: .shift)
    static let lineDown = KeyboardShortcut("j", modifiers: [])
    static let lineUp = KeyboardShortcut("k", modifiers: [])
    static let vimTop = KeyboardShortcut("g", modifiers: [])
    static let vimBottom = KeyboardShortcut("g", modifiers: .shift)
    static let halfPageDown = KeyboardShortcut("d", modifiers: [])
    static let halfPageUp = KeyboardShortcut("u", modifiers: [])
    static let halfPageUpE = KeyboardShortcut("e", modifiers: [])
    static let vimPageDown = KeyboardShortcut("f", modifiers: [])
    static let vimPageUp = KeyboardShortcut("b", modifiers: [])
    static let nextChange = KeyboardShortcut("n", modifiers: []) // changes since last read, as Vim's next match
    static let previousChange = KeyboardShortcut("n", modifiers: .shift)
    static let addNote = KeyboardShortcut("m", modifiers: []) // a note on the selected passage (V6)
    static let sendReply = KeyboardShortcut(.return) // ⌘↩, as Mail's Send
    static let bigger = KeyboardShortcut("+")
    static let smaller = KeyboardShortcut("-")
    static let defaultSize = KeyboardShortcut("0")

    /// How the key reads in the help: ⌥⌘R, ⌃⇧Tab, Space; a single letter as typed (G for ⇧g).
    var glyph: String {
        let names: [Character: String] = ["\u{F700}": "↑", "\u{F701}": "↓", " ": "Space", "\t": "Tab", "-": "−", "\r": "↩"]
        let c = key.character, name = names[c] ?? String(c)
        if modifiers.isEmpty { return name }
        if modifiers == .shift, c.isLetter { return name.uppercased() }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (c.isLetter ? name.uppercased() : name)
    }
}

/// One line of the help: what it does, and its keys (alternatives side by side) or a gesture.
struct Shortcut {
    let action: LocalizedStringKey
    let keys: [String]
    var gesture: LocalizedStringKey?

    init(_ action: LocalizedStringKey, _ keys: KeyboardShortcut...) { self.action = action; self.keys = keys.map(\.glyph) }
    init(_ action: LocalizedStringKey, text keys: String...) { self.action = action; self.keys = keys }
    init(_ action: LocalizedStringKey, gesture: LocalizedStringKey) { self.action = action; keys = []; self.gesture = gesture }
}

/// The rows a shortcut hint (hold ⌘) shows too, so the hint and the help read the same words and keys.
@MainActor extension Shortcut {
    static let newAgent = Shortcut("New Agent…", .newAgent)
    static let sidebar = Shortcut("Show · hide sidebar", .sidebarSafari, .sidebar)
    static let unread = Shortcut("Show Only Unread", .unreadOnly)
    static let panel = Shortcut("Show · hide panel", .panel)
    static let source = Shortcut("Reading ↔ Source", .switchView)
    static let contents = Shortcut("Toggle Table of Contents", .tableOfContents)
    static let backForward = Shortcut("Back · forward", .back, .forward)
    static let find = Shortcut("Find", .find, .findSlash)
    static let searchSidebar = Shortcut("Search the sidebar (list focused)", .find)
    static let help = Shortcut("Keyboard Shortcuts", .shortcuts)
}

struct ShortcutGroup {
    let title: LocalizedStringKey
    let items: [Shortcut]
    init(_ title: LocalizedStringKey, _ items: [Shortcut]) { self.title = title; self.items = items }
}

@MainActor enum Shortcuts {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup("Documents & Tabs", [
            Shortcut("Open a document", .open),
            .newAgent,
            Shortcut("New tab from the sidebar · back to the page", .newTab),
            Shortcut("Close Tab", .closeTab, .closeTabX),
            Shortcut("Tab 1–8 · last tab", text: "⌘1–8", KeyboardShortcut.lastTab.glyph),
            Shortcut("Next · previous tab", .nextTab, .previousTab),
            Shortcut("Next · previous tab", text: "⇧⌘]", "⇧⌘["), // PageWebView, as in Safari
            Shortcut("Show in Finder", .showInFinder),
        ]),
        ShortcutGroup("Navigate", [
            .backForward,
            Shortcut("Back · forward", gesture: "Two-finger swipe"),
            Shortcut("Page down · up", .pageDown, .pageUp),
            Shortcut("Bottom · top", .bottom, .top),
            Shortcut("Line down · up", .lineDown, .lineUp),
            Shortcut("Half page down · up", .halfPageDown, .halfPageUp, .halfPageUpE),
            Shortcut("Page down · up", .vimPageDown, .vimPageUp),
            Shortcut("Bottom · top", .vimBottom, .vimTop),
            Shortcut("Next · previous change", .nextChange, .previousChange),
        ]),
        ShortcutGroup("View", [
            .sidebar,
            .unread,
            .panel,
            .source,
            .contents,
            Shortcut("Immersive Mode", .immersive),
            Shortcut("Reload", .reload),
            Shortcut("Full screen", text: "⌃⌘F", "fn F"), // PageWebView and the system
        ]),
        ShortcutGroup("Find & Text", [
            .find,
            .searchSidebar,
            Shortcut("Next · previous match", .findNext, .findPrevious),
            Shortcut("Bigger · smaller · default size", .bigger, .smaller, .defaultSize),
        ]),
        ShortcutGroup("Reply", [
            Shortcut("Note on the selected passage", .addNote),
            Shortcut("Send Reply", .sendReply),
        ]),
        ShortcutGroup("Settings", [
            .help,
            Shortcut("Settings…", text: "⌘,"), // the system's Settings item
        ]),
    ]
}

/// The panel's Shortcuts tab (⌘', Help > Keyboard Shortcuts): every group in one column, what a
/// key does at the left and its keys at the right.
struct ShortcutsList: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Shortcuts.groups.indices, id: \.self) { g in
                    let group = Shortcuts.groups[g]
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                        .padding(.top, g == 0 ? 0 : 14)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.items.indices, id: \.self) { i in
                        let s = group.items[i]
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(s.action)
                                .font(.system(size: 12.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 3) {
                                if let gesture = s.gesture {
                                    Text(gesture).font(.system(size: 12)).foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                                }
                                ForEach(s.keys, id: \.self) { KeyCap(glyph: $0) }
                            }
                            .fixedSize()
                        }
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts")
    }
}

/// A key as a small rounded cap.
private struct KeyCap: View {
    let glyph: String

    var body: some View {
        let cap = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(verbatim: glyph)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(Color.primary.opacity(0.06), in: cap)
            .overlay(cap.strokeBorder(Color(nsColor: .hairline), lineWidth: 1))
    }
}

/// While ⌘ alone is held (Store.shortcutHintsVisible): what an element's keys do, in a small
/// solid badge (ink on paper inverted, never glass on glass) laid over the window, so nothing
/// moves. A row per shortcut: its words and keys from Shortcuts.swift, as the help shows them.
/// VoiceOver already reads the keys as each control's hint, so the badge stays out of its way.
private struct ShortcutHint: ViewModifier {
    let rows: [Shortcut]
    var keys: String?
    let shown: Bool
    let alignment: Alignment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            badge
                .fixedSize()
                // Below the element (6 pt clear of it); a keys-only badge sits inside it, as Safari's ⌘1.
                .alignmentGuide(VerticalAlignment.bottom) { keys == nil ? $0[.top] - 6 : $0[.bottom] }
                .opacity(shown ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shown)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var badge: some View {
        let ink = Color(nsColor: .paper), ground = Color(nsColor: .ink)
        if let keys {
            Text(verbatim: keys)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(ground, in: Capsule())
                .padding(.trailing, 3) // where the × shows on hover
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].action).font(.system(size: 11.5))
                        Text(verbatim: rows[i].keys.joined(separator: "  "))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }
}

extension View {
    /// A badge of `rows` below this view while `shown`; `alignment` .bottomLeading, .bottom or
    /// .bottomTrailing picks which edge it hangs from.
    func shortcutHint(_ rows: [Shortcut], shown: Bool, alignment: Alignment = .bottom) -> some View {
        modifier(ShortcutHint(rows: rows, shown: shown, alignment: alignment))
    }

    /// Only the keys, inside this view at its trailing end: a tab's ⌘1.
    func shortcutHint(keys: String?, shown: Bool) -> some View {
        modifier(ShortcutHint(rows: [], keys: keys, shown: shown && keys != nil, alignment: .trailing))
    }
}
