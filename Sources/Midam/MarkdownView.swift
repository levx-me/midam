import AppKit
import SwiftUI
import WebKit

@MainActor private let world = WKContentWorld.world(name: "midam")

/// Renders Markdown in a WKWebView. Page JavaScript is disabled and blocked by CSP;
/// marked, highlight.js, KaTeX, mermaid and every call run only in an app-owned content world.
struct MarkdownView: NSViewRepresentable {
    let text: String
    let fileURL: URL?
    let reading: Reading
    let page: Page
    /// The selected tab. Every open file shown so far keeps its own web view (scroll, view, find,
    /// watcher); the others are hidden, so they take no events.
    let active: Bool
    /// The colour theme for each appearance; the current appearance picks one, and the page
    /// switches with it (System follows macOS).
    @AppStorage(Pref.lightTheme) private var lightTheme = ColorTheme.midam
    @AppStorage(Pref.darkTheme) private var darkTheme = ColorTheme.midam
    @Environment(\.colorScheme) private var scheme

    private var theme: ColorTheme {
        ColorTheme.named(scheme == .dark ? darkTheme : lightTheme, dark: scheme == .dark)
    }

    private static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let s = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("Missing \(name).\(ext) in Contents/Resources; run ./build.sh") }
        return s
    }

    /// The assembled page, written once to a temp file. Loaded with loadFileURL because
    /// loadHTMLString cannot read local images; the document folder is applied as <base href>.
    private static let page: URL = {
        // KaTeX's stylesheet first (its fonts come through midam-font:), then Midam's, which wins.
        let html = resource("template", "html").replacingOccurrences(of: "/*STYLE*/", with: resource("katex.min", "css") + "\n" + resource("style", "css"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Midam-page.html")
        do { try html.write(to: url, atomically: true, encoding: .utf8) } catch { fatalError("Cannot write \(url.path): \(error)") }
        return url
    }()

    private static let renderer = WKUserScript(
        source: [resource("marked.umd", "js"), resource("highlight.min", "js"), resource("katex.min", "js"),
                 resource("emoji", "js"), resource("markdown", "js"), resource("render", "js")].joined(separator: "\n;\n"),
        injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)

    /// Mermaid (about 5 MB), evaluated in the app's world only when a document has a diagram.
    /// It ends in an assignment of the mermaid object, which WebKit cannot return; hence the 0.
    static let mermaid = resource("mermaid.min", "js") + "\n;0"

    /// The words the page shows itself, localised here and passed to render.js with each render.
    static let words: [String: String] = [
        "note": String(localized: "Note"), "tip": String(localized: "Tip"), "important": String(localized: "Important"),
        "warning": String(localized: "Warning"), "caution": String(localized: "Caution"),
        "footnotes": String(localized: "Footnotes"), "back": String(localized: "Back to reference"),
        "diagram": String(localized: "Diagram could not be drawn"),
    ]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(Self.renderer)
        config.setURLSchemeHandler(FontSchemeHandler(), forURLScheme: FontSchemeHandler.scheme) // bundled fonts only
        // The section being read, from render.js; reachable from the app's world only, never the page.
        config.userContentController.add(TocSpy(page: page), contentWorld: world, name: TocSpy.name)
        let webView = PageWebView(frame: .zero, configuration: config)
        webView.page = page
        webView.isHidden = !active
        webView.setValue(false, forKey: "drawsBackground") // let the SwiftUI paper colour show: no white flash
        let c = context.coordinator
        webView.navigationDelegate = c
        c.webView = webView
        c.page = page
        c.input = text
        c.text = text // read again, with its stamp, once the page has loaded
        c.fileURL = fileURL
        c.reading = reading
        c.theme = theme
        webView.underPageBackgroundColor = theme.color("bg") // the rubber-band edges wear the theme too
        page.webView = webView
        page.fileURL = fileURL
        page.reload = { [weak c] in c?.reload(force: true) }
        c.watch()
        // Read access to "/" so images anywhere (e.g. ../img.png) load; the page runs no script.
        webView.loadFileURL(Self.page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.isHidden == active {
            webView.isHidden = !active
            if active { DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) } }
        }
        let c = context.coordinator
        let theme = theme
        if c.reading != reading || c.theme != theme {
            if c.theme != theme { webView.underPageBackgroundColor = theme.color("bg") }
            c.reading = reading
            c.theme = theme
            c.applyReading()
        }
        guard c.input != text else { return } // only a new document text from SwiftUI; reloads are handled by the watcher
        c.input = text
        c.text = text
        c.stamp = nil // from SwiftUI, not read here: not cached
        c.render()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: TocSpy.name, contentWorld: world)
        coordinator.stop()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var page: Page?
        var input = "" // last text SwiftUI gave us
        var text = ""  // what is on screen (may be newer, from disk)
        var stamp: FileStamp? // the file's mtime and size as `text` was read: the cache key
        var fileURL: URL?
        var reading: Reading?
        var theme: ColorTheme?
        private var loaded = false
        private var stopped = false
        private var source: DispatchSourceFileSystemObject?
        private var pendingReload: DispatchWorkItem?
        private var pendingSave: DispatchWorkItem?

        /// Fragments for documents opened from a link, applied on their first render.
        static var pendingFragments: [URL: String] = [:]
        /// Scroll offsets for documents returned to by Back or Forward, applied on their first render.
        static var pendingOffsets: [URL: Double] = [:]

        func render(fragment pending: String? = nil, offset pendingOffset: Double? = nil) {
            guard loaded, let webView else { return }
            let fragment = pending ?? fileURL.flatMap { Self.pendingFragments.removeValue(forKey: $0.standardizedFileURL) }
            let offset = pendingOffset ?? fileURL.flatMap { Self.pendingOffsets.removeValue(forKey: $0.standardizedFileURL) }
            let cacheKey = cacheKey() // the file as this render reads it
            // Markdown is passed as an argument, never spliced into JS source.
            webView.callAsyncJavaScript("return await midamRender(md, base, words)",
                                       arguments: ["md": text, "base": fileURL?.deletingLastPathComponent().absoluteString ?? "",
                                                   "words": MarkdownView.words],
                                       in: nil, in: world) { [weak self, weak webView] result in
                if case .failure(let error) = result { NSLog("Midam render failed: \(error)") }
                // The document has a diagram: mermaid (large) is evaluated in the app's world only
                // now, once per web view, and the render runs again (render.js asks only once).
                if case .success(let value) = result, value as? String == "mermaid", let webView {
                    webView.evaluateJavaScript(MarkdownView.mermaid, in: nil, in: world) { [weak self] loaded in
                        if case .failure(let error) = loaded { NSLog("Midam mermaid failed to load: \(error)") }
                        self?.render(fragment: fragment, offset: offset)
                    }
                    return
                }
                if case .success(let value) = result {
                    self?.page?.takeOutline(value)
                    if let cacheKey, let html = (value as? [String: Any])?["html"] as? String { self?.saveCache(cacheKey, html) }
                }
                if let fragment { self?.scroll(to: fragment) }
                if let offset { self?.page?.scroll(toOffset: offset) }
                self?.page?.refresh()
            }
        }

        /// Reading settings become CSS custom properties, set from the app's world with the
        /// values as arguments (render.js clamps the numbers, quotes the font names and takes
        /// only #rrggbb theme colours).
        // MARK: Render cache

        /// What this file's cached render must match: the file now, the reading settings and theme
        /// (not the header height, which only pads the page) and the page's localised words.
        private func cacheKey() -> RenderKey? {
            guard let fileURL, let stamp, var r = reading?.arguments, let theme else { return nil }
            r["header"] = nil
            return RenderCache.key(for: fileURL, stamp: stamp,
                                   settings: RenderCache.digest(["reading": r, "theme": theme.arguments, "words": MarkdownView.words]))
        }

        /// The last finished render of this file, if it was made from the same file, settings and
        /// build: shown at once, ahead of the real render (queued after it in the same world).
        private func showCached() {
            guard let webView, let key = cacheKey(), let html = RenderCache.load(key) else { return }
            webView.callAsyncJavaScript("return midamShowCached(html, base)",
                                       arguments: ["html": html, "base": fileURL?.deletingLastPathComponent().absoluteString ?? ""],
                                       in: nil, in: world) { [weak self] result in
                if case .failure(let error) = result { NSLog("Midam cached page failed: \(error)") }
                if case .success(let value) = result { self?.page?.takeOutline(value) }
            }
        }

        /// Writes a finished render off the main thread, a second after the last one (saves in bursts).
        private func saveCache(_ key: RenderKey, _ html: String) {
            pendingSave?.cancel()
            pendingSave = RenderCache.storeLater(key, html: html)
        }

        func applyReading() {
            guard loaded, let webView, let reading, let theme else { return }
            let s = reading.arguments.merging(theme.arguments) { a, _ in a }
            webView.callAsyncJavaScript("midamStyle(s)", arguments: ["s": s], in: nil, in: world) { result in
                if case .failure(let error) = result { NSLog("Midam style failed: \(error)") }
            }
        }

        private func scroll(to fragment: String) {
            webView?.callAsyncJavaScript("document.getElementById(id)?.scrollIntoView()",
                                         arguments: ["id": fragment.removingPercentEncoding ?? fragment], in: nil, in: world)
        }

        // MARK: Auto-reload

        /// Watches the file's inode. Editors save atomically (write temp, rename over), which
        /// leaves the descriptor on the old inode, so every reload re-opens the path.
        func watch() {
            source?.cancel()
            source = nil
            guard !stopped, let fileURL else { return }
            let fd = open(fileURL.path, O_EVTONLY)
            guard fd >= 0 else {
                // Gone (deleted, or mid-replace): keep the last content and look again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { self?.watch() } }
                return
            }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReload() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        }

        private func scheduleReload() {
            pendingReload?.cancel()
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
            pendingReload = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item) // debounce bursts
        }

        func reload(force: Bool = false) {
            watch()
            guard let fileURL, let read = RenderCache.read(fileURL) else { return }
            guard force || read.text != text else { return }
            (text, stamp) = read
            render()
        }

        func stop() {
            stopped = true
            pendingReload?.cancel()
            source?.cancel()
            source = nil
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true
            applyReading()
            // A tab first shown well after launch may have changed on disk since it was read.
            if let fileURL, let read = RenderCache.read(fileURL) { (text, stamp) = read }
            showCached()
            render()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard loaded else { return .allow } // the template itself
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .cancel }
            switch linkAction(url, current: fileURL) {
            case .browser(let url): NSWorkspace.shared.open(url)
            case .scroll(let fragment):
                Store.shared.leaveHere() // Back returns to where the link was
                scroll(to: fragment)
            case .open(let target, let fragment): Store.shared.open(target, fragment: fragment)
            case .reveal(let target): NSWorkspace.shared.activateFileViewerSelecting([target])
            case .ignore: break
            }
            return .cancel // the web view never navigates away
        }

    }
}

// MARK: Table of contents

// Heading and the result decoding live in TocRules.swift (checked by tools/TocTest).

/// Receives the id of the section being read from render.js, in the "midam" world only.
/// Weak to its page: the content controller keeps the handler alive.
@MainActor final class TocSpy: NSObject, WKScriptMessageHandler {
    static let name = "midamToc"
    weak var page: Page?

    init(page: Page) { self.page = page }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.body is String, let page else { return }
        page.tocCurrent = page.tocAnchor(message.body)
    }
}

// MARK: Link policy

enum LinkAction: Equatable {
    case browser(URL), scroll(String), open(URL, fragment: String?), reveal(URL), ignore
}

/// What a clicked link does. Markdown opens in Midam; any other local file is only revealed
/// in Finder, never opened (a link to an .app, .command or script would otherwise run it).
func linkAction(_ url: URL, current: URL?) -> LinkAction {
    let scheme = url.scheme?.lowercased() ?? ""
    if ["http", "https", "mailto"].contains(scheme) { return .browser(url) }
    guard url.isFileURL else { return .ignore }
    let target = URL(fileURLWithPath: url.path).standardizedFileURL // drops the #fragment
    let fragment = url.fragment.flatMap { $0.isEmpty ? nil : $0 }
    let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || target.hasDirectoryPath
    if let fragment, let here = current?.standardizedFileURL,
       target.path == here.path || (isDir && target.path == here.deletingLastPathComponent().path) {
        return .scroll(fragment) // same page (a bare #anchor resolves against <base>, the folder)
    }
    let real = target.resolvingSymlinksInPath()
    let realIsDir = (try? real.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    if !isDir, !realIsDir, ["md", "markdown", "mdown", "mkd"].contains(real.pathExtension.lowercased()) {
        return .open(target, fragment: fragment)
    }
    return .reveal(target)
}

/// The document web view. Page script is off, so the page has no use for key equivalents:
/// the menu goes first, which keeps app and system items (full screen, find, Go, tabs)
/// working however WebKit routes a key. The selected tab's view takes focus, so Space and
/// arrows scroll at once.
final class PageWebView: WKWebView {
    weak var page: Page?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !isHidden else { return }
        DispatchQueue.main.async { [weak self] in window.makeFirstResponder(self) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌃⌘F: the system binds full screen to fn/🌐-F only, and WKWebView would swallow ⌃⌘F.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        if event.type == .keyDown, mods == [.control, .command],
           event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f" { // 3 = kVK_ANSI_F
            window?.toggleFullScreen(nil)
            return true
        }
        // ⌘[ / ⌘]: back / forward (WKWebView would take them), by character, so another layout's
        // key in that position does not go back. Layouts that type [ with Option reach the menu below.
        if event.type == .keyDown, mods == [.command] {
            let c = event.charactersIgnoringModifiers ?? ""
            if c == "[" { Store.shared.goBack(); return true }
            if c == "]" { Store.shared.goForward(); return true }
        }
        // ⇧⌘[ / ⇧⌘]: previous / next tab, as in Safari and Finder (the menu shows ⌃⇧Tab / ⌃Tab).
        // By character: charactersIgnoringModifiers keeps Shift, so US and Korean 2-set give { and };
        // [ and ] cover a layout whose shifted bracket key types the bracket itself.
        if event.type == .keyDown, mods == [.command, .shift] {
            let c = event.charactersIgnoringModifiers ?? ""
            if c == "{" || c == "[" { Store.shared.step(-1); return true }
            if c == "}" || c == "]" { Store.shared.step(1); return true }
        }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true || super.performKeyEquivalent(with: event)
    }

    // MARK: Swipe back and forward

    /// Whether what is under the fingers scrolls sideways itself (a wide table or code block),
    /// asked of the page when they touch the trackpad; nil until it answers.
    private var sideScroller: Bool?
    /// The first events of a gesture that may be a swipe, kept from the page until SwipeRules
    /// tells; empty when none is held.
    private var held: [NSEvent] = []

    /// A two-finger sideways swipe goes back or forward, as in Safari, when the system's
    /// "Swipe between pages" allows it and nothing under the fingers scrolls sideways. A gesture
    /// with up or down in it scrolls, even when its first event leans sideways.
    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .mayBegin: probeSideScroller(at: convert(event.locationInWindow, from: nil))
        case .ended, .cancelled: sideScroller = nil
        default: break
        }
        let store = Store.shared
        let back = store.history.canGoBack, forward = store.history.canGoForward
        if event.phase == .began {
            held = []
            guard sideScroller == false, back || forward, NSEvent.isSwipeTrackingFromScrollEventsEnabled
            else { return super.scrollWheel(with: event) }
        } else if held.isEmpty {
            return super.scrollWheel(with: event)
        }
        held.append(event)
        let dx = held.reduce(0) { $0 + $1.scrollingDeltaX }, dy = held.reduce(0) { $0 + $1.scrollingDeltaY }
        let moving = event.phase == .began || event.phase == .changed
        switch moving ? SwipeRules.verdict(dx: dx, dy: dy) : .scroll {
        case .undecided: return
        case .scroll: // the page gets the whole gesture, a few events late
            let events = held
            held = []
            for e in events { super.scrollWheel(with: e) }
        case .swipe:
            held = []
            sideScroller = nil // the swipe takes the rest of the gesture, its end included
            // A positive amount is a swipe to the right: back. Each side clamps to 0 with nowhere to go.
            event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                                  dampenAmountThresholdMin: forward ? -1 : 0, max: back ? 1 : 0) { amount, phase, _, _ in
                guard phase == .ended else { return } // the swipe went far enough to count
                MainActor.assumeIsolated { amount > 0 ? store.goBack() : store.goForward() }
            }
        }
    }

    private func probeSideScroller(at p: NSPoint) {
        sideScroller = nil
        let y = isFlipped ? p.y : bounds.height - p.y
        callAsyncJavaScript("""
            for (let e = document.elementFromPoint(x, y); e && e !== document.documentElement; e = e.parentElement) {
              if (e.scrollWidth > e.clientWidth + 1 && /auto|scroll/.test(getComputedStyle(e).overflowX)) return true;
            }
            return false
            """, arguments: ["x": p.x, "y": y], in: nil, in: world) { [weak self] result in
            if case .success(let value) = result { self?.sideScroller = (value as? Bool) ?? true }
        }
    }

    // MARK: Dropped files

    /// Markdown files in a file drag, nil for any other drag (left to WebKit). Other files are
    /// ignored rather than navigated to; the same rule as a clicked link decides.
    private func droppedMarkdown(_ info: NSDraggingInfo) -> [URL]? {
        let pb = info.draggingPasteboard
        guard pb.types?.contains(.fileURL) == true else { return nil }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.compactMap { if case .open(let target, _) = linkAction($0, current: nil) { target } else { nil } }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let urls = droppedMarkdown(info) else { return super.draggingEntered(info) }
        return urls.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let urls = droppedMarkdown(info) else { return super.draggingUpdated(info) }
        return urls.isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool {
        droppedMarkdown(info).map { !$0.isEmpty } ?? super.prepareForDragOperation(info)
    }

    override func draggingExited(_ info: NSDraggingInfo?) {
        if let info, droppedMarkdown(info) != nil { return }
        super.draggingExited(info)
    }

    override func concludeDragOperation(_ info: NSDraggingInfo?) {
        if let info, droppedMarkdown(info) != nil { return }
        super.concludeDragOperation(info)
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard let urls = droppedMarkdown(info) else { return super.performDragOperation(info) }
        Store.shared.open(urls)
        return !urls.isEmpty
    }

    override func keyDown(with event: NSEvent) {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return } // 🌐-F, Space, j/k reach the menu
        // Esc with the page focused: find closes first (Page.close, via onExitCommand), else the open TOC.
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, // 53 = kVK_Escape
           let page, !page.visible, page.tocAvailable, Store.shared.tocOpen {
            Store.shared.tocOpen = false
            return
        }
        super.keyDown(with: event)
    }
}

/// Per-window state and actions behind the menus; find matching itself runs in render.js.
@MainActor @Observable final class Page {
    var visible = false
    var query = ""
    var index = 0
    var count = 0
    var focusRequest = 0
    /// Showing the raw Markdown instead of the reading view (per window, off by default).
    var source = false
    /// The table of contents: h1-h3 from the last render, and the anchor of the section being read.
    var outline: [Heading] = []
    var tocCurrent: String?
    /// There is a table of contents to show: headings, in 읽기.
    var tocAvailable: Bool { !source && !outline.isEmpty }
    /// The table of contents has shown itself once for this tab, on its first showing.
    @ObservationIgnored var tocIntroduced = false
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var fileURL: URL?
    @ObservationIgnored var reload: (() -> Void)?

    func show() {
        visible = true
        focusRequest += 1
        search()
    }

    func close() {
        visible = false
        Store.shared.findFocused = false
        run("midamFindClear()")
        if let webView { webView.window?.makeFirstResponder(webView) }
    }

    func search() { run("return midamFind(q, 0)", ["q": query]) }
    func refresh() { if visible { run("return midamFind(q, k)", ["q": query, "k": index]) } }

    func step(_ d: Int) {
        guard visible else { return show() }
        run("return midamFindStep(d)", ["d": d])
    }

    enum Scroll: String {
        // Smooth unless Reduce Motion is on, as the page keys: WebKit's smooth scroll caps its own
        // duration, so a long document's top or bottom does not take seconds.
        case top = "scrollTo({ top: 0, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' })"
        case bottom = "scrollTo({ top: document.documentElement.scrollHeight, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' })"
        case pageDown = "midamScrollPage(1)" // Space, ⇧Space: the same step as f / b
        case pageUp = "midamScrollPage(-1)"
        case lineDown = "scrollBy(0, 40)"
        case lineUp = "scrollBy(0, -40)"
        case halfPageDown = "midamScrollPage(0.5)"
        case halfPageUp = "midamScrollPage(-0.5)"
    }

    func scroll(_ s: Scroll) { run(s.rawValue) }

    /// How far down the page is scrolled, for the history; 0 if the page cannot say.
    func scrollOffset(_ done: @escaping @MainActor (Double) -> Void) {
        guard let webView else { return done(0) }
        webView.callAsyncJavaScript("return scrollY", arguments: [:], in: nil, in: world) { result in
            if case .success(let value) = result { done((value as? Double) ?? 0) } else { done(0) }
        }
    }

    /// Back or Forward to a place in this page.
    func scroll(toOffset y: Double) { run("scrollTo(0, y)", ["y": y]) }

    /// A link to a #fragment of a file that is already open.
    func scroll(to fragment: String) {
        run("document.getElementById(id)?.scrollIntoView()", ["id": fragment.removingPercentEncoding ?? fragment])
    }

    /// A table of contents entry: the same jump as an #anchor link, recorded for Back, and smooth
    /// unless Reduce Motion is on.
    func jump(to anchor: String) {
        Store.shared.leaveHere()
        run("document.getElementById(id)?.scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' })",
            ["id": anchor])
    }

    /// A render's result: the outline and the section on screen. A render a newer one overtook
    /// returns nothing and changes nothing.
    func takeOutline(_ value: Any?) {
        guard let toc = Heading.toc(value) else { return }
        outline = toc.outline
        tocCurrent = toc.current
    }

    /// An id from the page, taken only if the outline holds it (at most 512 UTF-16 units); else nil.
    func tocAnchor(_ value: Any?) -> String? {
        Heading.anchor(value, in: outline)
    }

    func setView(source: Bool) {
        Store.shared.objectWillChange.send() // the View menu's checkmark reads this
        self.source = source
        run("midamSetView(s)", ["s": source])
        refresh()
    }

    func reveal() { if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } }

    private func run(_ js: String, _ args: [String: Any] = [:]) {
        webView?.callAsyncJavaScript(js, arguments: args, in: nil, in: world) { [weak self] result in
            guard let self, case .success(let value) = result, let r = value as? [Int], r.count == 2 else { return }
            (self.index, self.count) = (r[0], r[1])
            if self.visible, !self.query.isEmpty {
                AccessibilityNotification.Announcement(r[1] == 0 ? String(localized: "No matches") : String(localized: "\(r[0]) of \(r[1])")).post()
            }
        }
    }
}
