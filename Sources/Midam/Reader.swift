import AppKit
import SwiftUI
import UniformTypeIdentifiers

// One reader window owning the open files as tabs of our own (native window tabbing
// cannot hide its bar with two or more tabs). Every way of opening a file goes through
// Store.open: the open panel, Open Recent, Finder and the Dock, links and drops.

/// One open file: its own Page (find state, view) and, in ReaderView, its own web view and watcher.
@MainActor final class OpenFile: Identifiable {
    let id = UUID()
    let url: URL
    let text: String
    let page = Page()
    /// Selected at least once. A tab gets its web view only then, so a restored session renders
    /// just the selected tab at launch and each other one when first shown.
    var shown = false

    init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

/// A place read, for back and forward: a file and how far down it was scrolled. The offset
/// arrives from the page just after the place is recorded, so it is filled in then.
@MainActor final class Spot: @MainActor Equatable {
    let path: String
    var y: Double = 0

    init(path: String) { self.path = path }

    static func == (a: Spot, b: Spot) -> Bool { a.path == b.path && a.y == b.y }
}

@MainActor final class Store: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = Store()

    @Published private(set) var files: [OpenFile] = []
    @Published private(set) var selected: OpenFile.ID?
    /// The top of the header row: in a window, centred on the traffic lights' line; in full
    /// screen a small margin, or below the lights while macOS slides them in with the menu bar.
    @Published private(set) var rowTop: CGFloat = 3
    /// Where the header row starts: just after the traffic lights in a window, at the side margin
    /// in full screen.
    @Published private(set) var rowLeading: CGFloat = 81
    @Published private(set) var fullScreen = false
    /// The bare title bar's height (32 pt on macOS 26), measured when the window is made.
    private var titlebar: CGFloat = 32
    /// The whole header: the page runs under it and keeps this much padding at the top. In a
    /// window the row shares the title bar with the lights; in full screen it is the row alone.
    /// It does not follow the menu bar sliding in, so the page never reflows while it does.
    /// In immersive mode the row is gone: a window keeps the title bar (the lights are there),
    /// full screen starts at the top.
    var header: CGFloat { fullScreen ? (immersive ? 0 : 6 + TitleStrip.capsule + 6) : titlebar }
    /// Where the find field and the contents panel start: below the capsules (also while they
    /// slide down with the menu bar), or on the row's own line when it is hidden.
    var overlayTop: CGFloat { immersive ? rowTop : rowTop + TitleStrip.capsule + 8 }
    /// Back and forward through the places read (⌘[ ⌘]), in memory only.
    @Published private(set) var history = NavHistory<Spot>()
    /// View > Show Table of Contents (⌘T): the panel stays open, for every tab, until turned off.
    @Published var tocOpen = UserDefaults.standard.bool(forKey: Store.tocKey) {
        didSet { UserDefaults.standard.set(tocOpen, forKey: Self.tocKey) }
    }
    private static let tocKey = "tocOpen"
    /// View > Immersive Mode (⇧⌘F): the header row hidden, app-wide, remembered across launches.
    @Published var immersive = UserDefaults.standard.bool(forKey: Store.immersiveKey) {
        didSet { UserDefaults.standard.set(immersive, forKey: Self.immersiveKey) }
    }
    private static let immersiveKey = "immersive"
    private var keyMonitor: Any?
    /// The menus' single keys (no ⌘, ⌃ or ⌥): Space, j k g G d u e f b, / (find), x (close tab).
    private static let singleKeys = Set([KeyboardShortcut.pageDown, .pageUp, .lineDown, .lineUp, .vimTop, .vimBottom,
                                         .halfPageDown, .halfPageUp, .halfPageUpE, .vimPageDown, .vimPageUp,
                                         .findSlash, .closeTabX]
                                         .map { String($0.key.character).lowercased() })
    /// The keyboard shortcuts popover (the header's ⌘ button, Help > Keyboard Shortcuts).
    @Published var shortcutsShown = false
    /// The find field has focus: single-key Go shortcuts (Space, j, k, g, G) stand down.
    @Published var findFocused = false
    @Published private(set) var recents: [URL] = NSDocumentController.shared.recentDocumentURLs
    var quitting = false
    /// Last session's tabs, read before anything can overwrite them: files given at launch
    /// (application(_:open:)) arrive before applicationDidFinishLaunching runs restore().
    private let savedFiles = UserDefaults.standard.stringArray(forKey: Store.filesKey) ?? []
    private let savedSelection = UserDefaults.standard.string(forKey: Store.selectedKey)
    private var restored = false

    private var window: NSWindow?
    private var observers: [Any] = []
    private static let filesKey = "openFiles", selectedKey = "selectedFile", frameName = "MidamMain"

    var current: OpenFile? { files.first { $0.id == selected } }

    // MARK: Opening

    func open(_ urls: [URL]) { for url in urls { open(url) } }

    /// Adds a tab for `url`, or selects it if that file is already open (by resolved path).
    func open(_ url: URL, fragment: String? = nil) {
        let url = url.standardizedFileURL
        if let open = file(at: url) {
            let hasView = open.shown
            select(open)
            if let fragment {
                if hasView { open.page.scroll(to: fragment) }
                else { MarkdownView.Coordinator.pendingFragments[open.url.standardizedFileURL] = fragment } // taken by its first render
            }
        } else {
            guard let new = load(url) else { return }
            if let fragment { MarkdownView.Coordinator.pendingFragments[url] = fragment }
            files.append(new)
            select(new)
        }
        showWindow()
    }

    private func file(at url: URL) -> OpenFile? {
        let path = url.resolvingSymlinksInPath().path
        return files.first { $0.url.resolvingSymlinksInPath().path == path }
    }

    private func load(_ url: URL) -> OpenFile? {
        do {
            let data = try Data(contentsOf: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            recents = NSDocumentController.shared.recentDocumentURLs
            return OpenFile(url: url, text: String(decoding: data, as: UTF8.self))
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.markdown]
        panel.collectionBehavior.insert(.fullScreenAuxiliary) // stay on a full-screen Space
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recents = []
    }

    /// Reopens the files that were open last time, ahead of any given at launch (which stay selected).
    func restore() {
        guard !restored else { return }
        restored = true
        let saved = savedFiles.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { file(at: $0) ?? load($0) } // a launch file already open keeps its object
        let given = !files.isEmpty
        files = mergeTabs(saved: saved, launched: files) { $0.url.resolvingSymlinksInPath().path }
        if !given, let first = files.first { select(files.first { $0.url.path == savedSelection } ?? first, record: false) }
        save()
        if !files.isEmpty { showWindow() }
    }

    /// The Dock icon was clicked: show the window, or the open panel if nothing is open.
    func reopen() {
        if files.isEmpty { showOpenPanel() } else { showWindow() }
    }

    // MARK: Tabs

    /// Shows `file`'s tab. Moving there by hand, a link or opening a file (`record`) leaves the
    /// place read so far in the history; closing a tab, restoring and back/forward do not.
    func select(_ file: OpenFile, record: Bool = true) {
        if record, file.id != selected, let here = here() { history.leave(here) }
        file.shown = true
        selected = file.id
        window?.title = file.url.lastPathComponent // Mission Control and the Window menu
        window?.representedURL = file.url
        save()
    }

    /// Selects tab `n` (1-based), or the last tab for nil.
    func select(_ n: Int?) {
        let i = n.map { $0 - 1 } ?? files.count - 1
        if files.indices.contains(i) { select(files[i]) }
    }

    func step(_ d: Int) {
        guard let i = files.firstIndex(where: { $0.id == selected }), files.count > 1 else { return }
        select(files[(i + d + files.count) % files.count])
    }

    /// Closes a tab; its web view and file watcher go with it. The last tab closes the window.
    func close(_ file: OpenFile) {
        guard let i = files.firstIndex(where: { $0.id == file.id }) else { return }
        files.remove(at: i)
        if files.isEmpty {
            selected = nil
            save()
            window?.close()
        } else if selected == file.id {
            select(files[min(i, files.count - 1)], record: false)
        } else {
            save()
        }
    }

    // MARK: Back and forward

    /// Where the reader is now. The page reports its scroll offset a moment later and fills it in;
    /// the read is queued ahead of anything the caller asks of the page next (an anchor's scroll).
    private func here() -> Spot? {
        guard let current else { return nil }
        let spot = Spot(path: current.url.path)
        current.page.scrollOffset { spot.y = $0 }
        return spot
    }

    /// An #anchor in the current document is about to be followed.
    func leaveHere() {
        if let here = here() { history.leave(here) }
    }

    func goBack() {
        guard let here = here(), let to = history.goBack(from: here) else { return }
        go(to)
    }

    func goForward() {
        guard let here = here(), let to = history.goForward(from: here) else { return }
        go(to)
    }

    /// Shows a place from the history: its tab, opened again if it was closed, scrolled back.
    private func go(_ spot: Spot) {
        let url = URL(fileURLWithPath: spot.path).standardizedFileURL
        var target = file(at: url)
        if target == nil, let reopened = load(url) {
            files.append(reopened)
            target = reopened
        }
        guard let target else { return } // gone from disk (load said so)
        let hasView = target.shown
        select(target, record: false)
        if hasView { target.page.scroll(toOffset: spot.y) }
        else { MarkdownView.Coordinator.pendingOffsets[target.url.standardizedFileURL] = spot.y } // taken by its first render
        showWindow()
    }

    /// ⌘W: the current tab in the reader window; any other window (Settings) just closes.
    func closeCurrent() {
        if let key = NSApp.keyWindow, key !== window { return key.performClose(nil) }
        if let current { close(current) }
    }

    private func save() {
        guard restored else { return } // until restore() has read last session's tabs
        let d = UserDefaults.standard
        d.set(files.map(\.url.path), forKey: Self.filesKey)
        d.set(current?.url.path, forKey: Self.selectedKey)
    }

    // MARK: Window

    /// The active colour theme's page background for the current appearance.
    private static func themeGround() -> NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let id = UserDefaults.standard.string(forKey: dark ? Pref.darkTheme : Pref.lightTheme) ?? ColorTheme.midam
        return ColorTheme.named(id, dark: dark).color("bg")
    }

    func setWindowGround(_ color: NSColor) { window?.backgroundColor = color }

    private func showWindow() {
        let w = window ?? makeWindow()
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.backgroundColor = Self.themeGround() // ReaderView keeps it in step with the theme
        // No toolbar: on macOS 26 a toolbar brings its own glass, backdrop and scroll-edge layers
        // over the top of the page, and its title bar hosts the capsules outside the content, where
        // their glass cannot see the page. The bare transparent title bar paints nothing; the
        // capsules float in the content view (ReaderView) over the full-bleed page.
        w.titlebarSeparatorStyle = .none
        titlebar = w.frame.height - w.contentLayoutRect.height // before the content: the header row's place
        let host = ReaderHost(rootView: ReaderView(store: self))
        host.sizingOptions = [.minSize]
        w.contentView = host
        w.delegate = self
        observers = [NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.measureLights() }
        }]
        if let current { w.title = current.url.lastPathComponent; w.representedURL = current.url }
        place(w)
        window = w
        measureLights()
        // Events pass on untouched, except a single key that must not reach the menu (singleKeyBypass).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.singleKeyBypass(event) ?? false } ? nil : event
        }
        return w
    }

    /// AppKit offers every key to the menu before the focused view, so the Go menu's single keys
    /// would scroll the reader while someone types in a text field (the find field, Settings'
    /// search, a panel). They belong to the menu only while the reader window is key with no text
    /// field focused; otherwise the key goes straight to its window, which bypasses the menu.
    /// Returns whether it did that.
    private func singleKeyBypass(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        guard mods.isSubset(of: .shift), let c = event.charactersIgnoringModifiers?.lowercased(), Self.singleKeys.contains(c) else { return false }
        let key = NSApp.keyWindow
        if let key, key === window, !(key.firstResponder is NSText) { return false } // the page: the menu's
        guard let target = key ?? event.window else { return false }
        target.sendEvent(event)
        return true
    }

    /// The window comes back where and as large as it was last, however that was set (drag,
    /// zoom, Fill, another display): AppKit saves the frame under the autosave name on every
    /// change. The first time, ~900 pt wide (measure plus margins) and 85% of the visible
    /// height up to 1100, centred. A saved frame left on a display that is gone is brought back.
    private func place(_ window: NSWindow) {
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") != nil
        UserDefaults.standard.removeObject(forKey: "windowSize") // the size-only key it replaces
        // Named first, so whatever AppKit applies for the name comes before the checks below, and
        // from here on every move and resize is saved.
        window.setFrameAutosaveName(Self.frameName)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        if !saved || !window.setFrameUsingName(Self.frameName) {
            let size = NSSize(width: min(900, visible.width), height: min(1100, visible.height * 0.85))
            window.setContentSize(window.contentRect(forFrameRect: NSRect(origin: .zero, size: size)).size)
            window.center()
        } else if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
            window.setFrame(NSRect(origin: visible.origin, size: size), display: false)
            window.center()
        }
    }

    /// Places the header row by the traffic lights, which stay where macOS puts them. In a window
    /// the row shares their line, centred on it, starting just after them. In full screen their
    /// title bar lives in its own window, hidden above the screen until macOS slides it down with
    /// the menu bar: the row starts at the side margin at the top and moves down below it.
    private func measureLights() {
        guard let w = window, let content = w.contentView,
              let close = w.standardWindowButton(.closeButton), let bar = close.superview, let bw = bar.window else { return }
        let top = w.convertToScreen(content.convert(content.bounds, to: nil)).maxY
        var rowTop: CGFloat = 6, leading: CGFloat = 10
        if !fullScreen {
            let mid = top - bw.convertToScreen(close.convert(close.bounds, to: nil)).midY
            rowTop = max(0, (mid - TitleStrip.capsule / 2).rounded())
            if let zoom = w.standardWindowButton(.zoomButton) { leading = (zoom.convert(zoom.bounds, to: nil).maxX + 12).rounded() }
        } else if bw !== w {
            rowTop = max(6, top - bw.convertToScreen(bar.convert(bar.bounds, to: nil)).minY)
        }
        if abs(rowTop - self.rowTop) > 0.5 { self.rowTop = rowTop }
        if leading != rowLeading { rowLeading = leading }
    }

    /// ⌘W reaching the window itself (the standard Close item) closes one tab, not all of them;
    /// the red button closes the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown, files.count > 1 else { return true }
        closeCurrent()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        history = NavHistory() // the places read went with the window
        if !quitting {
            files.removeAll() // stops every tab's watcher
            selected = nil
            save()
        }
        window?.contentView = nil
        window = nil
        fullScreen = false // a window closed in full screen; the next one opens in a window
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fullScreen = true; measureLights() }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreen = false; measureLights() }
    func windowDidEnterFullScreen(_ notification: Notification) { measureLights() }
    func windowDidExitFullScreen(_ notification: Notification) { measureLights() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false // no native tab bar or its Window menu items
        Theme.apply(UserDefaults.standard.string(forKey: Pref.theme) ?? "")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.shared.restore()
        // Settings' font lists, built once off the main thread so the Fonts tab opens at once.
        DispatchQueue.global(qos: .utility).async { _ = Fonts.all; _ = BundledFonts.regular }
        // Files given at launch arrive before this; with nothing at all to show, offer the panel.
        DispatchQueue.main.async { MainActor.assumeIsolated { if Store.shared.files.isEmpty { Store.shared.showOpenPanel() } } }
    }

    func application(_ application: NSApplication, open urls: [URL]) { Store.shared.open(urls) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Store.shared.reopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Store.shared.quitting = true // keep the open files for next launch
        return .terminateNow
    }
}

// MARK: Reader window content

struct ReaderView: View {
    @ObservedObject var store: Store
    @AppStorage(Pref.font) private var font = ""
    @AppStorage(Pref.codeFont) private var codeFont = ""
    @AppStorage(Pref.size) private var size = Knob.size.initial
    @AppStorage(Pref.tracking) private var tracking = Spacing.normal
    @AppStorage(Pref.leading) private var leading = Spacing.normal
    @AppStorage(Pref.paragraph) private var paragraph = Spacing.normal
    @AppStorage(Pref.measure) private var measure = Spacing.normal
    @AppStorage(Pref.lightTheme) private var lightTheme = ColorTheme.midam
    @AppStorage(Pref.darkTheme) private var darkTheme = ColorTheme.midam
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The active colour theme's page background: shown before the page has styled itself,
    /// so a dark theme never flashes Midam's paper first.
    private var ground: NSColor {
        ColorTheme.named(scheme == .dark ? darkTheme : lightTheme, dark: scheme == .dark).color("bg")
    }

    var body: some View {
        let reading = Reading(font: font, mono: codeFont, size: size,
                              tracking: Spacing.tracking.value(tracking), leading: Spacing.leading.value(leading),
                              paragraph: Spacing.paragraph.value(paragraph), measure: Spacing.measure.value(measure),
                              header: store.header)
        let page = store.current?.page
        ZStack {
            ForEach(store.files.filter(\.shown)) { f in
                MarkdownView(text: f.text, fileURL: f.url, reading: reading, page: f.page, active: f.id == store.selected)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        // The header first: in immersive mode the panel moves up into its place, above its
        // window-drag strip, and below the search capsule while that shows.
        .overlay(alignment: .top) {
            TitleStrip(store: store)
        }
        .overlay {
            if let page {
                let search = store.immersive && page.visible ? TitleStrip.capsule + 8 : 0
                TableOfContents(store: store, page: page, top: store.overlayTop + search)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Immersive mode: find shows alone where the header's right capsule would be.
            if store.immersive, let page, page.visible {
                Search(page: page)
                    .padding(.horizontal, 3)
                    .frame(height: TitleStrip.capsule)
                    .glassCapsule()
                    .padding(.top, store.rowTop)
                    .padding(.trailing, 10)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: store.immersive) // the header's fade, the panel moving up
        .animation(reduceMotion ? nil : .smooth, value: page?.visible) // the search capsule growing or showing
        .overlay { TipLayer() }
        .coordinateSpace(.named(Tips.space))
        // The page runs to the top of the window and scrolls under the floating capsules;
        // render.js pads its first line below them.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: ground).ignoresSafeArea())
        .onChange(of: ground, initial: true) { store.setWindowGround(ground) }
        .onExitCommand { if let page, page.visible { page.close() } } // Esc with focus in the page
        .tint(Color(nsColor: .accent))
    }
}

/// The reader window's content. The capsules sit in the title bar's zone, so the view never
/// offers a mouse-down to AppKit for moving the window: clicks always reach them, and the
/// header's empty space moves the window through WindowDragArea instead.
final class ReaderHost: NSHostingView<ReaderView> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The header: a row of floating glass over the page, on the traffic lights' line in a window:
/// ‹ › (back, forward), the tabs' capsule with a round + (Open…) hugging it, and at the right the
/// view toggle and 'Aa'. Empty space in the header drags the window.
struct TitleStrip: View {
    @ObservedObject var store: Store
    @State private var formatShown = false
    @Namespace private var glass

    /// The capsules' height: centred on the lights' line (16 pt down), 26 pt leaves 3 pt above
    /// them. Labels and the 28 pt icon targets keep their size.
    static let capsule: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                StripIcon(label: "Back", keys: [.back], enabled: store.history.canGoBack, action: { store.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                StripIcon(label: "Forward", keys: [.forward], enabled: store.history.canGoForward, action: { store.goForward() }) {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.horizontal, 3)
            .frame(height: Self.capsule)
            .glassCapsule()
            .fixedSize()
            TabStrip(store: store)
                .layoutPriority(1) // offered all the room before the spacer, so it scrolls only when it must
            // Its own glass circle after the last tab: when the tabs overflow it stays at the
            // capsule's end and only they scroll.
            StripIcon(label: "Open…", keys: [.open], action: { store.showOpenPanel() }) {
                Image(systemName: "plus")
            }
            .frame(width: Self.capsule, height: Self.capsule)
            .glassCapsule()
            .fixedSize()
            Spacer(minLength: 0)
            if let page = store.current?.page {
                let tools = HStack(spacing: 0) {
                    Search(page: page, field: !store.immersive) // in immersive mode the window's own one
                    TocToggle(store: store, page: page)
                    ViewToggle(page: page)
                    FormatButton(shown: $formatShown)
                    ShortcutsButton(store: store)
                }
                .padding(.horizontal, 3)
                .frame(height: Self.capsule)
                .glassCapsule()
                .layoutPriority(2) // room for the search field before the tabs, which scroll instead
                if #available(macOS 26, *) {
                    GlassEffectContainer { tools.glassEffectID("tools", in: glass) } // the glass morphs as it grows
                } else {
                    tools
                }
            }
        }
        // Immersive mode: faded out and out of reach, but kept in place, so the ⌘ popover
        // (Help > Keyboard Shortcuts) still opens at the top right. The drag strip stays.
        .opacity(store.immersive ? 0 : 1)
        .allowsHitTesting(!store.immersive)
        .accessibilityHidden(store.immersive)
        .frame(height: Self.capsule)
        .padding(.leading, store.rowLeading)
        .padding(.trailing, 10)
        .padding(.top, store.rowTop)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background { WindowDragArea() }
        .allowsHitTesting(!(store.immersive && store.fullScreen)) // nothing to drag there: the page's
        .tint(Color(nsColor: .accent))
    }
}

/// Liquid Glass on macOS 26, a touch darker than plain so the page shows through it, blurred
/// (untinted glass in a light key window brightens thin text away; .clear does entirely); thin
/// material with a hairline before that; opaque paper under Reduce Transparency. Increase
/// Contrast makes the edge stronger. Capsules in the header, a rounded panel for the contents.
struct Glass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let edge = shape.strokeBorder(Color(nsColor: contrast == .increased ? .muted : .hairline), lineWidth: 1)
        if reduceTransparency {
            content.background(Color(nsColor: .paper), in: shape).overlay(edge)
        } else if #available(macOS 26, *) {
            // A faint ink hairline, always: lost in active glass, it keeps the shape when the
            // window is inactive and the glass goes flat (the tabs would read as bare text).
            content.glassEffect(.regular.tint(.black.opacity(0.06)), in: shape)
                .overlay {
                    if contrast == .increased { edge } else { shape.strokeBorder(Color(nsColor: .ink).opacity(0.1), lineWidth: 0.5) }
                }
        } else {
            content.background(.ultraThinMaterial, in: shape).overlay(edge)
        }
    }
}

extension View {
    func glassCapsule() -> some View { modifier(Glass(shape: Capsule())) }
    func glassPanel() -> some View { modifier(Glass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))) }
}

/// Label colours on the capsules. On glass and material the hierarchical styles get the
/// system's vibrancy, which keeps them legible over whatever scrolls beneath; on the opaque
/// Reduce Transparency capsule the fixed ink and faint tokens (13.8:1 and 4.6:1 on paper) apply.
enum GlassLabel {
    static func style(strong: Bool, opaque: Bool) -> AnyShapeStyle {
        if opaque { return AnyShapeStyle(Color(nsColor: strong ? .ink : .faint)) }
        return strong ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

/// The header's empty space still moves the window, and a double-click does what the
/// system setting says (zoom by default).
struct WindowDragArea: View {
    @State private var dragging = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    guard !dragging, let e = NSApp.currentEvent else { return }
                    dragging = true
                    e.window?.performDrag(with: e) // returns when the drag ends
                    dragging = false
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard let w = NSApp.currentEvent?.window, !w.styleMask.contains(.fullScreen) else { return }
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": w.miniaturize(nil)
                case "None": break
                default: w.zoom(nil)
                }
            })
            .accessibilityHidden(true)
    }
}

/// The open files in one glass capsule. It hugs its tabs; when they overflow it takes the
/// room there is and scrolls sideways under soft faded edges.
struct TabStrip: View {
    @ObservedObject var store: Store

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                        }
                    }
                    .onChange(of: store.selected, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
            }
        }
        .frame(height: TitleStrip.capsule)
        .glassCapsule()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(store.files) { FileTab(file: $0, store: store).id($0.id) }
        }
        .padding(.horizontal, 3)
    }
}

struct FileTab: View {
    let file: OpenFile
    @ObservedObject var store: Store

    /// "Tab 2 (⌘2)" for tabs 1–8, "Last Tab (⌘9)" beyond them.
    private var position: Text {
        guard let i = store.files.firstIndex(where: { $0.id == file.id }) else { return Text(verbatim: "") }
        let n = i + 1
        if n <= 8 { return Text("Tab \(n)") + Text(verbatim: " (\(KeyboardShortcut.tab(n).glyph))") }
        if n == store.files.count { return Text("Last Tab") + Text(verbatim: " (\(KeyboardShortcut.lastTab.glyph))") }
        return Text(verbatim: "")
    }
    @State private var hover = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let on = store.selected == file.id
        // The whole tab, full capsule height, selects; the × keeps its own 20 pt target at the end.
        // The current tab is an inner pill one step denser than the glass.
        Button { store.select(file) } label: {
            HStack(spacing: 4) {
                Text(verbatim: file.url.lastPathComponent)
                    .font(.system(size: 14, weight: on ? .medium : .regular))
                    .foregroundStyle(GlassLabel.style(strong: on, opaque: reduceTransparency))
                    .lineLimit(1)
                Color.clear.frame(width: 20, height: 20) // room for the ×
            }
            .padding(.leading, 11)
            .padding(.trailing, 3)
            .frame(height: TitleStrip.capsule - 4)
            .background(Color.primary.opacity(on ? 0.09 : 0), in: Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fastTip(Text(verbatim: file.url.path + "\n") + position)
        .accessibilityLabel(Text(verbatim: file.url.lastPathComponent))
        .accessibilityHint(position)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: Text("Close Tab")) { store.close(file) }
        .overlay(alignment: .trailing) {
            Button { store.close(file) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .opacity(hover ? 1 : 0)
            .focusable(false)
            .accessibilityHidden(true) // the tab's own Close Tab action, and ⌘W, cover it
            .fastTip(Text("Close Tab") + Text(verbatim: " (\(KeyboardShortcut.closeTab.glyph), \(KeyboardShortcut.closeTabX.glyph))"))
        }
        .onHover { hover = $0 }
    }
}
