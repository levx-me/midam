import SwiftUI

/// Every key the menus bind, named once: the menus use these, and the shortcuts help shows them,
/// so the two cannot drift. Keys handled outside the menus (⇧⌘[ ], ⌃⌘F, ⌘1-8) are listed as text.
/// Bare keys (Space, j k g G d u e f b, /, x) are menu items too; Store.singleKeyBypass keeps
/// them out of text fields and other windows.
extension KeyboardShortcut {
    static let open = KeyboardShortcut("o")
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
    static let bigger = KeyboardShortcut("+")
    static let smaller = KeyboardShortcut("-")
    static let defaultSize = KeyboardShortcut("0")

    /// How the key reads in the help: ⌥⌘R, ⌃⇧Tab, Space; a single letter as typed (G for ⇧g).
    var glyph: String {
        let names: [Character: String] = ["\u{F700}": "↑", "\u{F701}": "↓", " ": "Space", "\t": "Tab", "-": "−"]
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

struct ShortcutGroup {
    let title: LocalizedStringKey
    let items: [Shortcut]
    init(_ title: LocalizedStringKey, _ items: [Shortcut]) { self.title = title; self.items = items }
}

@MainActor enum Shortcuts {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup("Documents & Tabs", [
            Shortcut("Open a document", .open),
            Shortcut("New tab from the sidebar · back to the page", .newTab),
            Shortcut("Close Tab", .closeTab, .closeTabX),
            Shortcut("Tab 1–8 · last tab", text: "⌘1–8", KeyboardShortcut.lastTab.glyph),
            Shortcut("Next · previous tab", .nextTab, .previousTab),
            Shortcut("Next · previous tab", text: "⇧⌘]", "⇧⌘["), // PageWebView, as in Safari
            Shortcut("Show in Finder", .showInFinder),
        ]),
        ShortcutGroup("Navigate", [
            Shortcut("Back · forward", .back, .forward),
            Shortcut("Back · forward", gesture: "Two-finger swipe"),
            Shortcut("Page down · up", .pageDown, .pageUp),
            Shortcut("Bottom · top", .bottom, .top),
            Shortcut("Line down · up", .lineDown, .lineUp),
            Shortcut("Half page down · up", .halfPageDown, .halfPageUp, .halfPageUpE),
            Shortcut("Page down · up", .vimPageDown, .vimPageUp),
            Shortcut("Bottom · top", .vimBottom, .vimTop),
        ]),
        ShortcutGroup("View", [
            Shortcut("Show · hide sidebar", .sidebarSafari, .sidebar),
            Shortcut("Show Only Unread", .unreadOnly),
            Shortcut("Reading ↔ Source", .switchView),
            Shortcut("Toggle Table of Contents", .tableOfContents),
            Shortcut("Immersive Mode", .immersive),
            Shortcut("Reload", .reload),
            Shortcut("Full screen", text: "⌃⌘F", "fn F"), // PageWebView and the system
        ]),
        ShortcutGroup("Find & Text", [
            Shortcut("Find", .find, .findSlash),
            Shortcut("Search the sidebar (list focused)", .find),
            Shortcut("Next · previous match", .findNext, .findPrevious),
            Shortcut("Bigger · smaller · default size", .bigger, .smaller, .defaultSize),
        ]),
        ShortcutGroup("Settings", [
            Shortcut("Keyboard Shortcuts", .shortcuts),
            Shortcut("Settings…", text: "⌘,"), // the system's Settings item
        ]),
    ]
}

/// ⌘ at the end of the header's right capsule: the shortcuts help, as a popover like Aa's.
/// Help > Keyboard Shortcuts opens the same one.
struct ShortcutsButton: View {
    @ObservedObject var store: Store

    var body: some View {
        StripIcon(label: "Keyboard Shortcuts", keys: [.shortcuts], active: store.shortcutsShown, action: { store.shortcutsShown.toggle() }) {
            Image(systemName: "command")
        }
        .popover(isPresented: $store.shortcutsShown, arrowEdge: .bottom) {
            ShortcutsPopover().onExitCommand { store.shortcutsShown = false }
        }
    }
}

struct ShortcutsPopover: View {
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            column(Shortcuts.groups.prefix(2))
            column(Shortcuts.groups.dropFirst(2))
        }
        .padding(18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts")
    }

    private func column(_ groups: ArraySlice<ShortcutGroup>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(groups.indices, id: \.self) { g in
                GridRow {
                    Text(groups[g].title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, g == groups.startIndex ? 0 : 10)
                        .gridCellColumns(2)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(groups[g].items.indices, id: \.self) { i in
                    let s = groups[g].items[i]
                    GridRow {
                        HStack(spacing: 4) {
                            if let gesture = s.gesture {
                                Text(gesture).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(s.keys, id: \.self) { KeyCap(glyph: $0) }
                        }
                        Text(s.action).font(.system(size: 13))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .fixedSize()
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
