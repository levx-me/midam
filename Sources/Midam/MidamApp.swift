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
    private var page: Page? { store.current?.page }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
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
            Divider()
            Button("Show in Finder") { page?.reveal() }
                .keyboardShortcut(.showInFinder).disabled(page == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { page?.show() }.keyboardShortcut(.find).disabled(page == nil)
            Button("Find…") { page?.show() }.keyboardShortcut(.findSlash).disabled(page == nil || store.findFocused)
            Button("Find Next") { page?.step(1) }.keyboardShortcut(.findNext).disabled(page == nil)
            Button("Find Previous") { page?.step(-1) }.keyboardShortcut(.findPrevious).disabled(page == nil)
        }
        CommandGroup(before: .toolbar) {
            Picker("View", selection: Binding(get: { page?.source ?? false }, set: { page?.setView(source: $0) })) {
                Text("Reading").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.inline)
            .disabled(page == nil)
            Button("Switch Reading/Source") { if let page { page.setView(source: !page.source) } }
                .keyboardShortcut(.switchView).disabled(page == nil)
            Toggle("Show Table of Contents", isOn: $store.tocOpen)
                .keyboardShortcut(.tableOfContents).disabled(!(page?.tocAvailable ?? false))
            // A menu item, so PageWebView hands ⇧⌘F to the menu before WKWebView sees it.
            Toggle("Immersive Mode", isOn: $store.immersive).keyboardShortcut(.immersive)
            Divider()
            Button("Reload") { page?.reload?() }.keyboardShortcut(.reload).disabled(page == nil)
            Divider()
        }
        CommandGroup(after: .windowArrangement) {
            // ⌘1…⌘8 pick a tab by position, ⌘9 the last, ⌃Tab and ⌃⇧Tab step, as in Safari.
            Divider()
            Button("Show Next Tab") { store.step(1) }.keyboardShortcut(.nextTab).disabled(store.files.count < 2)
            Button("Show Previous Tab") { store.step(-1) }.keyboardShortcut(.previousTab).disabled(store.files.count < 2)
            Divider()
            ForEach(1...8, id: \.self) { n in
                Button("Tab \(n)") { store.select(n) }
                    .keyboardShortcut(.tab(n)).disabled(store.files.count < n)
            }
            Button("Last Tab") { store.select(nil) }.keyboardShortcut(.lastTab).disabled(store.files.isEmpty)
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
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { store.shortcutsShown.toggle() }
                .keyboardShortcut(.shortcuts).disabled(store.current == nil)
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
                .font(.system(size: 15)) // optically matches the 14 pt tab names
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

/// 읽기 ↔ 원문, as ⌘/. The glyph shows where a click takes you: </> in 읽기, a page in 원문.
struct ViewToggle: View {
    let page: Page

    var body: some View {
        StripIcon(label: page.source ? "Show Reading" : "Show Source", keys: [.switchView], action: { page.setView(source: !page.source) }) {
            Image(systemName: page.source ? "doc.text" : "chevron.left.forwardslash.chevron.right")
        }
    }
}

/// Find at the start of the right capsule: a magnifying glass that grows leftward into the field
/// (⌘F, /, or a click), the glass staying at its left edge as the field's icon. Esc folds it back.
struct Search: View {
    let page: Page
    var field = true

    var body: some View {
        HStack(spacing: 0) {
            StripIcon(label: "Find", keys: [.find, .findSlash], active: page.visible, action: { page.show() }) {
                Image(systemName: "magnifyingglass")
            }
            if field, page.visible { FindField(page: page).transition(.opacity) }
        }
    }
}

/// The search field inside the capsule, with the match count at its right.
struct FindField: View {
    @Bindable var page: Page
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $page.query)
                .textFieldStyle(.plain)
                .frame(minWidth: 90, idealWidth: 180, maxWidth: 180)
                .focused($focused)
                .onSubmit { page.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1) }
                .onExitCommand { page.close() }
                .onChange(of: page.query) { page.search() }
            Text(verbatim: page.query.isEmpty ? "" : "\(page.index)/\(page.count)")
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .muted))
                .accessibilityLabel("\(page.index) of \(page.count) matches")
                .fastTip(Text(verbatim: "\(page.index)/\(page.count) — ") + Text("Next") + Text(verbatim: " \(KeyboardShortcut.findNext.glyph) · ")
                      + Text("Previous") + Text(verbatim: " \(KeyboardShortcut.findPrevious.glyph)"))
        }
        .font(.system(size: 13))
        .padding(.trailing, 9)
        .onAppear { focused = true }
        .onChange(of: page.focusRequest) { focused = true }
        .onChange(of: focused) {
            Store.shared.findFocused = focused
            // A click elsewhere folds an empty field; one with a query stays. Next turn, so a field
            // taking over (immersive mode switched) has claimed focus by then.
            if !focused {
                DispatchQueue.main.async { [page] in
                    if page.visible, page.query.isEmpty, !Store.shared.findFocused { page.close() }
                }
            }
        }
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
    /// The app accent in place of system blue: ink in light; in dark the faint warm grey, since a
    /// white knob or checkmark on off-white ink would vanish (3.7:1 with white, 4.6:1 on paper).
    /// Must match Assets.xcassets/AccentColor and --accent in style.css.
    static let accent = ink(light: 0x2b2a27, dark: 0x888480)
}
