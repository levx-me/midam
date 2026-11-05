import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MidamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Spacing.migrate() // before any setting is read
    }

    // The reader window is AppKit-owned (see Store); SwiftUI provides the menus and Settings.
    var body: some Scene {
        Settings { SettingsView() }
            .commands {
                MidamCommands()
                FormatMenu()
            }
    }
}

@MainActor struct MidamCommands: Commands {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var sidebar = SidebarState.shared
    private var page: Page? { store.current?.page }

    /// ⌘F searches the sidebar while its list or its search field has focus (or no page is
    /// open), else finds in the page: the panel on its find tab.
    private func find() {
        let inSidebar = sidebar.searchFieldFocused || (NSApp.keyWindow.map(Sidebar.hasFocus) ?? false)
        if inSidebar || page == nil {
            store.sidebarOpen = true
            sidebar.openSearch()
        } else {
            page?.show()
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent…") { store.showWindow(); store.newAgentOpen = true }.keyboardShortcut(.newAgent)
            Button("New Tab") { Sidebar.toggleFocus(store) }.keyboardShortcut(.newTab)
            Button("Open…") { store.showOpenPanel() }.keyboardShortcut(.open)
            Menu("Open Recent") {
                ForEach(store.recents, id: \.self) { url in
                    Button { store.open([url]) } label: { Text(verbatim: url.lastPathComponent) }
                }
                Divider()
                Button("Clear Menu") { store.clearRecents() }.disabled(store.recents.isEmpty)
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { store.closeCurrent() }.keyboardShortcut(.closeTab)
            Button("Close Tab") { store.closeCurrent() }.keyboardShortcut(.closeTabX).disabled(store.current == nil || store.findFocused)
            Button("Clear Scrollback") { store.currentAgent?.terminal?.clear() }
                .keyboardShortcut(.clearScrollback).disabled(store.currentAgent?.terminal == nil)
            Divider()
            Button("Show in Finder") { page?.reveal() }
                .keyboardShortcut(.showInFinder).disabled(page == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { find() }.keyboardShortcut(.find).disabled(page == nil && !store.sidebarOpen)
            Button("Find…") { page?.show() }.keyboardShortcut(.findSlash).disabled(page == nil || store.findFocused)
            Button("Find Next") { page?.step(1) }.keyboardShortcut(.findNext).disabled(page == nil)
            Button("Find Previous") { page?.step(-1) }.keyboardShortcut(.findPrevious).disabled(page == nil)
            Divider()
            // m stands down while a text field has focus (Store.singleKeyBypass), so it types there.
            Button("Add Note") { page?.addNote() }.keyboardShortcut(.addNote).disabled(page == nil || store.findFocused)
            Button("Send Reply") { page?.sendReply() }.keyboardShortcut(.sendReply).disabled(page?.reply.canSend != true)
        }
        CommandGroup(before: .toolbar) {
            // ⇧⌘L as in Safari, ⌃⌘S as macOS's sidebars.
            if store.sidebarOpen {
                Button("Hide Sidebar") { store.sidebarOpen = false }.keyboardShortcut(.sidebarSafari)
                Button("Hide Sidebar") { store.sidebarOpen = false }.keyboardShortcut(.sidebar)
            } else {
                Button("Show Sidebar") { store.sidebarOpen = true }.keyboardShortcut(.sidebarSafari)
                Button("Show Sidebar") { store.sidebarOpen = true }.keyboardShortcut(.sidebar)
            }
            Toggle("Show Only Unread", isOn: Binding(get: { sidebar.unreadOnly }, set: { on in
                store.sidebarOpen = true
                sidebar.setUnreadOnly(on)
            }))
            .keyboardShortcut(.unreadOnly)
            Divider()
            Picker("View", selection: Binding(get: { page?.source ?? false }, set: { page?.setView(source: $0) })) {
                Text("Reading").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.inline)
            .disabled(page == nil)
            Button("Switch Reading/Source") { if let page { page.setView(source: !page.source) } }
                .keyboardShortcut(.switchView).disabled(page == nil)
            // ⌥⌘I as the inspector in Pages and Keynote; ⌥⌘T and ⌘' open it on their tab, or close it there.
            if store.panelOpen {
                Button("Hide Panel") { store.panelOpen = false }.keyboardShortcut(.panel)
            } else {
                Button("Show Panel") { store.panelOpen = true }.keyboardShortcut(.panel)
            }
            Toggle("Show Table of Contents", isOn: Binding(get: { store.panelOpen && store.panelTab == .toc },
                                                           set: { _ in store.togglePanel(.toc) }))
                .keyboardShortcut(.tableOfContents)
            // A menu item, so PageWebView hands ⇧⌘F to the menu before WKWebView sees it.
            Toggle("Immersive Mode", isOn: $store.immersive).keyboardShortcut(.immersive)
            Divider()
            Button("Reload") { page?.reload?() }.keyboardShortcut(.reload).disabled(page == nil)
            Divider()
        }
        CommandGroup(after: .windowArrangement) {
            // ⌘1…⌘8 pick a tab by position, ⌘9 the last, ⌃Tab and ⌃⇧Tab step, as in Safari.
            Divider()
            Button("Show Next Tab") { store.step(1) }.keyboardShortcut(.nextTab).disabled(store.tabCount < 2)
            Button("Show Previous Tab") { store.step(-1) }.keyboardShortcut(.previousTab).disabled(store.tabCount < 2)
            Divider()
            ForEach(1...8, id: \.self) { n in
                Button("Tab \(n)") { store.select(n) }
                    .keyboardShortcut(.tab(n)).disabled(store.tabCount < n)
            }
            Button("Last Tab") { store.select(nil) }.keyboardShortcut(.lastTab).disabled(store.tabCount == 0)
        }
        CommandMenu("Go") {
            // Through the places read, across tabs: links followed and tabs switched (⇧⌘[ ] switch tabs).
            Button("Back") { store.goBack() }.keyboardShortcut(.back).disabled(store.current == nil || !store.history.canGoBack)
            Button("Forward") { store.goForward() }.keyboardShortcut(.forward).disabled(store.current == nil || !store.history.canGoForward)
            Divider()
            go("Top", .top, .top)
            go("Bottom", .bottom, .bottom)
            Divider()
            go("Page Down", .pageDown, .pageDown)
            go("Page Up", .pageUp, .pageUp)
            Section("Vim") {
                go("Line Down", .lineDown, .lineDown)
                go("Line Up", .lineUp, .lineUp)
                go("Half Page Down", .halfPageDown, .halfPageDown)
                go("Half Page Up", .halfPageUp, .halfPageUp)
                go("Half Page Up", .halfPageUp, .halfPageUpE)
                go("Page Down", .pageDown, .vimPageDown)
                go("Page Up", .pageUp, .vimPageUp)
                go("Top", .top, .vimTop) // gg reads as g twice: still the top
                go("Bottom", .bottom, .vimBottom)
            }
            Divider()
            Button("Next Change") { page?.stepChange(1) }.keyboardShortcut(.nextChange).disabled(page == nil || store.findFocused)
            Button("Previous Change") { page?.stepChange(-1) }.keyboardShortcut(.previousChange).disabled(page == nil || store.findFocused)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { store.togglePanel(.shortcuts) }.keyboardShortcut(.shortcuts)
        }
    }

    /// Single keys (no modifiers, Space and ⇧Space too) stand down while the find field has focus,
    /// so they can be typed there; the page web view hands them to the menu otherwise.
    private func go(_ title: String, _ s: Page.Scroll, _ key: KeyboardShortcut) -> some View {
        Button(LocalizedStringKey(title)) { page?.scroll(s) }
            .keyboardShortcut(key)
            .disabled(page == nil || (!key.modifiers.contains(.command) && store.findFocused))
    }
}

/// A small icon button for the title strip: faint, ink on hover or while `active`, 28 pt target.
/// Its tooltip is `tip` (else the label) with the keys from Shortcuts.swift, as "Back (⌘[)"; still
/// shown while disabled. VoiceOver gets the label, and the keys as a hint.
struct StripIcon<Glyph: View>: View {
    let label: LocalizedStringKey
    var tip: LocalizedStringKey?
    var keys: [KeyboardShortcut] = []
    var active = false
    var enabled = true
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @State private var hover = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let on = isEnabled && enabled
        let glyphs = keys.map(\.glyph).joined(separator: ", ")
        Button(action: action) {
            glyph()
                .font(.system(size: 14)) // a little over the 13 pt tab names, as toolbar glyphs are
                .foregroundStyle(GlassLabel.style(strong: on && (hover || active), opaque: reduceTransparency))
                .opacity(on ? 1 : 0.35) // disabled (nowhere to go back to): fainter still
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled) // inside, so the tooltip below still shows
        .accessibilityLabel(label)
        .accessibilityHint(Text(verbatim: glyphs))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .fastTip(keys.isEmpty ? Text(tip ?? label) : Text(tip ?? label) + Text(verbatim: " (\(glyphs))"))
    }
}

/// 원본 보기 (⌘/): the raw Markdown or the reading view, its </> in the accent colour on a soft
/// disc while the source shows.
struct SourceToggle: View {
    let page: Page

    var body: some View {
        StripIcon(label: page.source ? "Show Reading" : "Show Source", keys: [.switchView], active: page.source,
                  action: { page.setView(source: !page.source) }) {
            let glyph = Image(systemName: "chevron.left.forwardslash.chevron.right")
            if page.source {
                glyph.foregroundStyle(Color.accentColor)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 24, height: 24))
            } else {
                glyph
            }
        }
        .accessibilityAddTraits(page.source ? [.isToggle, .isSelected] : .isToggle)
    }
}

extension UTType {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

extension NSColor {
    private static func ink(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
    }
    /// These must match `--bg`, `--hairline` and `--muted` in style.css.
    static let paper = ink(light: 0xfbfaf7, dark: 0x1d1c1a)
    static let hairline = ink(light: 0xe4e1da, dark: 0x363430)
    static let ink = ink(light: 0x2b2a27, dark: 0xe4e1db) // matches --text
    static let muted = ink(light: 0x67645e, dark: 0xa09c94)
    /// The faintest grey that still meets 4.5:1 on paper (4.6 light, 4.59 dark).
    static let faint = ink(light: 0x75726b, dark: 0x888480)
}
