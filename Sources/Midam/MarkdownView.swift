import AppKit
import SwiftUI
import WebKit
import os

@MainActor private let world = WKContentWorld.world(name: "midam")

/// Renders Markdown in a WKWebView. Page JavaScript is disabled and blocked by CSP;
/// marked, highlight.js, KaTeX, mermaid and every call run only in an app-owned content world.
struct MarkdownView: NSViewRepresentable {
    let text: String
    /// The file's mtime and size as `text` was read (nil: not read from it, or changed while read).
    let stamp: FileStamp?
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
                 resource("emoji", "js"), resource("markdown", "js"), resource("changes", "js"), resource("render", "js")].joined(separator: "\n;\n"),
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
        "deleted": String(localized: "Deleted: {words}, {n}"), "line": String(localized: "1 line"), "lines": String(localized: "{n} lines"),
        "memo": String(localized: "Add Note"),
    ]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        c.name = fileURL?.lastPathComponent ?? ""
        c.span = OpenTiming.signposter.beginInterval("open", id: OpenTiming.signposter.makeSignpostID())
        OpenTiming.log.log("\(c.name, privacy: .private): make web view, \(OpenTiming.sinceEvent(), format: .fixed(precision: 1), privacy: .public) ms after the event")
        let spare = Spare.take()
        let (webView, spy) = spare.map { ($0.webView, $0.spy) } ?? Self.newWebView()
        OpenTiming.log.log("\(c.name, privacy: .private): \(spare == nil ? "new" : spare!.loaded ? "spare, loaded" : "spare, loading", privacy: .public) web view")
        spy.page = page
        webView.page = page
        webView.isHidden = !active
        webView.navigationDelegate = c
        c.webView = webView
        c.page = page
        c.input = text
        c.text = text // read again once the page has loaded, if the file changed since
        c.stamp = stamp
        c.fileURL = fileURL
        c.reading = reading
        c.theme = theme
        webView.underPageBackgroundColor = theme.color("bg") // the rubber-band edges wear the theme too
        page.webView = webView
        page.fileURL = fileURL
        page.reload = { [weak c] in c?.reload(force: true) }
        page.baseline = fileURL.flatMap { Baseline.read($0) } // the version last read: changes are marked against it
        c.watch()
        // Rendered once SwiftUI has put it in the window (a detached web view is throttled); a spare
        // still loading sends its didFinish to the coordinator.
        if spare?.loaded == true { DispatchQueue.main.async { [weak c] in MainActor.assumeIsolated { c?.didLoad() } } }
        OpenTiming.log.log("\(c.name, privacy: .private): web view made +\(OpenTiming.ms(since: c.born), format: .fixed(precision: 1), privacy: .public) ms")
        return webView
    }

    /// A web view loading the template, with the renderer scripts and the outline handler in the
    /// app's world; the handler's page is set when a tab takes it.
    fileprivate static func newWebView() -> (PageWebView, TocSpy) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(renderer)
        config.setURLSchemeHandler(FontSchemeHandler(), forURLScheme: FontSchemeHandler.scheme) // bundled fonts only
        // The section being read, from render.js; reachable from the app's world only, never the page.
        let spy = TocSpy(page: nil)
        config.userContentController.add(spy, contentWorld: world, name: TocSpy.name)
        let webView = PageWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // let the SwiftUI paper colour show: no white flash
        // Read access to "/" so images anywhere (e.g. ../img.png) load; the page runs no script.
        webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        return (webView, spy)
    }

    /// Makes the next tab's web view ahead, if there is none (Spare).
    static func warmSpare() { Spare.warm() }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.isHidden == active {
            webView.isHidden = !active
            if active { DispatchQueue.main.async { Sidebar.pageTakesFocus(webView) } }
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
        private var readingCache = false
        private var stopped = false
        private var source: DispatchSourceFileSystemObject?
        private var pendingReload: DispatchWorkItem?
        private var pendingSave: DispatchWorkItem?
        /// Open timing (OpenTiming): when this tab's web view was asked for, its file name, its signpost.
        let born = ContinuousClock.now
        var name = ""
        var span: OSSignpostIntervalState?

        /// Fragments for documents opened from a link, applied on their first render.
        static var pendingFragments: [URL: String] = [:]
        /// Scroll offsets for documents returned to by Back or Forward, applied on their first render.
        static var pendingOffsets: [URL: Double] = [:]

        func render(fragment pending: String? = nil, offset pendingOffset: Double? = nil) {
            guard loaded, !readingCache, let webView else { return }
            let fragment = pending ?? fileURL.flatMap { Self.pendingFragments.removeValue(forKey: $0.standardizedFileURL) }
            let offset = pendingOffset ?? fileURL.flatMap { Self.pendingOffsets.removeValue(forKey: $0.standardizedFileURL) }
            let cacheKey = cacheKey() // the file as this render reads it
            let started = ContinuousClock.now
            page?.shown = text
            // Markdown is passed as an argument, never spliced into JS source.
            webView.callAsyncJavaScript("return await midamRender(md, base, words, baseline)",
                                       arguments: ["md": text, "base": fileURL?.deletingLastPathComponent().absoluteString ?? "",
                                                   "words": MarkdownView.words, "baseline": page?.baseline ?? NSNull()],
                                       in: nil, in: world) { [weak self] result in
                if case .failure(let error) = result { NSLog("Midam render failed: \(error)") }
                // A re-render with a diagram: the page on screen stays until mermaid is loaded, then
                // the render runs again (render.js asks only once).
                if case .success(let value) = result, value as? String == "mermaid" {
                    self?.loadMermaid { self?.render(fragment: fragment, offset: offset) }
                    return
                }
                if let self {
                    let t = ((try? result.get()) as? [String: Any])?["timing"] as? [String: Any] ?? [:]
                    OpenTiming.log.log("\(self.name, privacy: .private): render in \(OpenTiming.ms(since: started), format: .fixed(precision: 1), privacy: .public) ms (page: \(t.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "), privacy: .public)), +\(OpenTiming.ms(since: self.born), format: .fixed(precision: 1), privacy: .public) ms")
                    if let span = self.span {
                        OpenTiming.signposter.endInterval("open", span)
                        self.span = nil
                        // The next tab's web view, made now the page shows, off this open's path.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MarkdownView.warmSpare() }
                    }
                }
                if case .success(let value) = result {
                    self?.page?.takeOutline(value)
                    self?.page?.takeChanges(value)
                    let r = value as? [String: Any]
                    if let cacheKey, let html = r?["html"] as? String { self?.saveCache(cacheKey, html) }
                    if r?["diagrams"] as? Bool == true { self?.drawDiagrams(cacheKey) }
                }
                if let fragment { self?.scroll(to: fragment) }
                if let offset { self?.page?.scroll(toOffset: offset) }
                self?.page?.refresh()
            }
        }

        /// Mermaid (large) is evaluated in the app's world only when a document has a diagram, once
        /// per web view; `then` runs once it is (or failed to load). A call while it loads waits for it.
        private var mermaid: [() -> Void]? // nil: not asked; the callers waiting while it loads
        private var mermaidLoaded = false

        private func loadMermaid(then: @escaping () -> Void) {
            if mermaidLoaded { return then() }
            if mermaid != nil { mermaid?.append(then); return }
            guard let webView else { return }
            mermaid = [then]
            let asked = ContinuousClock.now
            webView.evaluateJavaScript(MarkdownView.mermaid, in: nil, in: world) { [weak self] loaded in
                if case .failure(let error) = loaded { NSLog("Midam mermaid failed to load: \(error)") }
                guard let self else { return }
                OpenTiming.log.log("\(self.name, privacy: .private): mermaid evaluated in \(OpenTiming.ms(since: asked), format: .fixed(precision: 1), privacy: .public) ms")
                self.mermaidLoaded = true
                let waiting = self.mermaid ?? []
                self.mermaid = nil
                for f in waiting { f() }
            }
        }

        /// A first render shown with its diagrams as code: draws them in place once mermaid is
        /// loaded, and caches the finished page (render.js returns it only if no render overtook it).
        private func drawDiagrams(_ cacheKey: RenderKey?) {
            loadMermaid { [weak self] in
                let started = ContinuousClock.now
                self?.webView?.callAsyncJavaScript("return await midamDrawDiagrams()", arguments: [:], in: nil, in: world) { result in
                    if case .failure(let error) = result { NSLog("Midam diagrams failed: \(error)") }
                    guard let self else { return }
                    OpenTiming.log.log("\(self.name, privacy: .private): diagrams drawn in place in \(OpenTiming.ms(since: started), format: .fixed(precision: 1), privacy: .public) ms, +\(OpenTiming.ms(since: self.born), format: .fixed(precision: 1), privacy: .public) ms")
                    if let cacheKey, case .success(let value) = result, let html = value as? String { self.saveCache(cacheKey, html) }
                }
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
        /// The cache is read and decoded off the main thread; renders wait for it (`readingCache`),
        /// so the cached page never lands over a newer one.
        private func showCachedThenRender() {
            let started = ContinuousClock.now, key = cacheKey()
            readingCache = true
            Task { [weak self] in
                let html = await Task.detached(priority: .userInitiated) { key.flatMap { RenderCache.load($0) } }.value
                guard let self else { return }
                OpenTiming.log.log("\(self.name, privacy: .private): render cache \(html == nil ? "miss" : "hit", privacy: .public), read in \(OpenTiming.ms(since: started), format: .fixed(precision: 1), privacy: .public) ms")
                self.readingCache = false
                if let html { self.showCached(html) }
                self.render()
            }
        }

        private func showCached(_ html: String) {
            guard let webView else { return }
            page?.shown = text
            webView.callAsyncJavaScript("return midamShowCached(html, base, md, baseline, words)",
                                       arguments: ["html": html, "base": fileURL?.deletingLastPathComponent().absoluteString ?? "",
                                                   "md": text, "baseline": page?.baseline ?? NSNull(), "words": MarkdownView.words],
                                       in: nil, in: world) { [weak self] result in
                if case .failure(let error) = result { NSLog("Midam cached page failed: \(error)") }
                if case .success(let value) = result { self?.page?.takeOutline(value); self?.page?.takeChanges(value) }
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
            webView?.callAsyncJavaScript("midamScrollTo(id)",
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
            if let page, page === Store.shared.current?.page { LibraryModel.shared.opened(fileURL) } // read as it changes (D5)
        }

        func stop() {
            stopped = true
            pendingReload?.cancel()
            source?.cancel()
            source = nil
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { didLoad() }

        /// The template and scripts are loaded (in this tab's own web view, or in the spare it took).
        func didLoad() {
            guard !loaded else { return }
            loaded = true
            OpenTiming.log.log("\(self.name, privacy: .private): template and scripts loaded +\(OpenTiming.ms(since: self.born), format: .fixed(precision: 1), privacy: .public) ms")
            applyReading()
            // A tab first shown well after launch may have changed on disk since it was read.
            let reading = ContinuousClock.now
            if let fileURL, stamp == nil || stamp != Self.stamp(fileURL), let read = RenderCache.read(fileURL) {
                (text, stamp) = read
                OpenTiming.log.log("\(self.name, privacy: .private): file read again (\(self.text.utf8.count, privacy: .public) B) in \(OpenTiming.ms(since: reading), format: .fixed(precision: 1), privacy: .public) ms")
            }
            showCachedThenRender()
        }

        /// The file's mtime and size now, as RenderCache.read stamps them; nil if it cannot be read.
        private static func stamp(_ url: URL) -> FileStamp? {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return nil }
            return FileStamp(mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9, size: Int(st.st_size))
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

/// Receives the id of the section being read from render.js, in the "midam" world only, and the
/// Note button's {note: true} (V6). Weak to its page: the content controller keeps the handler alive.
@MainActor final class TocSpy: NSObject, WKScriptMessageHandler {
    static let name = "midamToc"
    weak var page: Page?

    init(page: Page?) { self.page = page }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let page else { return }
        if message.body is String { page.tocCurrent = page.tocAnchor(message.body) }
        else if (message.body as? [String: Any])?["note"] != nil { page.addNote() }
    }
}

// MARK: Spare web view

/// One web view made ahead, with the template and scripts loaded, which the next tab takes, so
/// opening a document skips WebKit's start (a new web content process, the template, 511 KB of
/// scripts). Made idle: after launch, and after each tab that took one has rendered. Dropped if
/// its load fails or its process ends; a tab then makes its own.
@MainActor private final class Spare: NSObject, WKNavigationDelegate {
    private static var next: Spare?
    let webView: PageWebView
    let spy: TocSpy
    private(set) var loaded = false

    private init(_ made: (PageWebView, TocSpy)) {
        (webView, spy) = made
        super.init()
        webView.navigationDelegate = self
    }

    static func warm() { if next == nil { next = Spare(MarkdownView.newWebView()) } }

    /// The spare, for a tab that sets itself as its navigation delegate at once.
    static func take() -> Spare? {
        defer { next = nil }
        return next
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { drop() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { drop() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { drop() }

    private func drop() {
        guard Self.next === self else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: TocSpy.name, contentWorld: world)
        Self.next = nil
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
/// arrows scroll at once; never from the sidebar's list (Sidebar.pageTakesFocus).
final class PageWebView: WKWebView {
    weak var page: Page?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isHidden else { return }
        DispatchQueue.main.async { [weak self] in if let self { Sidebar.pageTakesFocus(self) } }
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
        // Esc with the page focused closes the panel while it floats over the page; a docked one stays.
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, // 53 = kVK_Escape
           Store.shared.panelOpen, Store.shared.panelFloats {
            Store.shared.panelOpen = false
            return
        }
        super.keyDown(with: event)
    }
}

/// Per-tab state and actions behind the menus; find matching itself runs in render.js. Find is on
/// while the panel shows its find tab (Store.findOn); each tab keeps its own query.
@MainActor @Observable final class Page {
    var query = ""
    /// The current match (1-based, 0 for none) and how many there are on the page.
    var index = 0
    var count = 0
    /// The panel's find list: the first ≤500 matches, in page order.
    var matches: [FindMatch] = []
    var focusRequest = 0
    /// Showing the raw Markdown instead of the reading view (per window, off by default).
    var source = false
    /// The table of contents: h1-h3 from the last render, and the anchor of the section being read.
    var outline: [Heading] = []
    var tocCurrent: String?
    /// Places changed since the version last read (V3), from the last render; 0 with no baseline.
    var changes = 0 { didSet { if let fileURL { SidebarChanges.shared.set(fileURL, changes) } } }
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var fileURL: URL? {
        didSet { if let fileURL, fileURL != oldValue { reply = ReplyStore.load(fileURL.path) } }
    }
    /// The reply drafted on this document (V6), saved per document as it changes (ReplyStore),
    /// never into the file itself.
    var reply = Reply() {
        didSet { if let fileURL, reply != oldValue { try? ReplyStore.save(reply, for: fileURL.path) } }
    }
    /// A `midam review --wait` waiting for this document's reply (its reply.md): Send delivers there.
    var waiting: URL?
    /// The note just added, whose field takes focus in the Reply tab.
    var noteFocus: UUID?
    /// What the last Send did, shown under the Send button.
    var sent: String?
    @ObservationIgnored var reload: (() -> Void)?
    /// The version last read (nil: never read) and the text on screen now, which becomes it on leaving.
    @ObservationIgnored var baseline: String?
    @ObservationIgnored var shown: String?

    /// ⌘F, /: the panel on its find tab, the field focused.
    func show() {
        Store.shared.show(.find)
        focusField()
    }

    /// The find field takes focus, on the next turn: the panel may only now be opening.
    func focusField() { Task { self.focusRequest += 1 } }

    /// Esc in the find field: back to the page; the panel and the matches stay.
    func leaveField() {
        Store.shared.findFocused = false
        if let webView { Sidebar.pageTakesFocus(webView) }
    }

    /// Find turned off (the panel closed or on another tab): no match stays painted.
    func clearFind() {
        index = 0
        count = 0
        matches = []
        run("midamFindClear()")
    }

    func search() { run("return midamFind(q, 0)", ["q": query]) }
    func refresh() { if Store.shared.findOn { run("return midamFind(q, k)", ["q": query, "k": index]) } }

    func step(_ d: Int) {
        guard Store.shared.findOn else { return show() }
        run("return midamFindStep(d)", ["d": d])
    }

    /// A row of the find list: that match becomes the current one, scrolled to.
    func go(to match: FindMatch) { run("return midamFindGo(i)", ["i": match.id]) }

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
        run("midamScrollTo(id)", ["id": fragment.removingPercentEncoding ?? fragment])
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

    func takeChanges(_ value: Any?) {
        if let n = (value as? [String: Any])?["changes"] as? Int { changes = n }
    }

    /// The reader leaves this document (another tab, closed, window closed, quit): what it showed
    /// becomes the version last read, and its marks go.
    func markRead() {
        guard let fileURL, let shown, shown != baseline else { return }
        baseline = shown
        Baseline.write(fileURL, text: shown)
        webView?.callAsyncJavaScript("return midamMarks(b)", arguments: ["b": shown], in: nil, in: world) { _ in }
        changes = 0
    }

    /// n / N: the next or previous change, announced.
    func stepChange(_ d: Int) {
        webView?.callAsyncJavaScript("return midamChangeStep(d)", arguments: ["d": d], in: nil, in: world) { result in
            guard case .success(let value) = result, let r = value as? [String: Any],
                  let i = r["index"] as? Int, let n = r["count"] as? Int else { return }
            AccessibilityNotification.Announcement(n == 0 ? String(localized: "No changes since last read") : String(format: String(localized: "Change %lld of %lld"), i, n)).post()
        }
    }

    /// m or the Note button: the selected passage becomes a note, its field focused in the Reply
    /// tab. With nothing selected the tab opens on its hint.
    func addNote() {
        Store.shared.show(.reply)
        guard let webView, let fileURL else { return }
        webView.callAsyncJavaScript("return midamSelection()", arguments: [:], in: nil, in: world) { [weak self] result in
            guard let self, case .success(let value) = result, let s = value as? [String: Any],
                  let quote = s["quote"] as? String, let start = s["start"] as? Int, let end = s["end"] as? Int else {
                return AccessibilityNotification.Announcement(String(localized: "Select a passage first")).post()
            }
            let note = Note(quote: quote, path: DocKey.path(fileURL.path), start: start, end: end, text: "")
            self.reply.notes.append(note)
            self.sent = nil
            self.noteFocus = note.id
        }
    }

    /// A note's row: its first line scrolled under the header and flashed.
    func go(toLine line: Int) {
        Store.shared.leaveHere()
        webView?.callAsyncJavaScript("midamGoLine(n, true)", arguments: ["n": line], in: nil, in: world) { _ in }
    }

    /// The reply as Markdown, paths relative to the document's repository when it has one. All
    /// realpaths (as the notes' and the CLI's): a file URL may have lost /private.
    var replyMarkdown: String {
        guard let fileURL else { return "" }
        let real = URL(fileURLWithPath: DocKey.path(fileURL.path))
        let words = ReplyWords(title: String(localized: "Review"), approve: String(localized: "Approve"),
                               changes: String(localized: "Request changes"))
        return reply.markdown(path: real.path, root: Self.repository(of: real), words: words)
    }

    /// Send (⌘↩): to the agent waiting in `midam review --wait`, else (or if it stopped waiting)
    /// to the clipboard. The draft clears either way; the document is never touched.
    func sendReply() {
        guard reply.canSend, fileURL != nil else {
            return AccessibilityNotification.Announcement(String(localized: "Nothing to send yet")).post()
        }
        let markdown = replyMarkdown
        var said = String(localized: "Copied to the clipboard"), delivered = false
        if let waiting {
            do {
                // No verdict chosen: notes ask for changes, none approve.
                try ReviewRequest.deliver(reply: markdown, verdict: reply.verdict ?? (reply.notes.isEmpty ? .approve : .changes), to: waiting)
                said = String(localized: "Sent to the waiting agent")
                delivered = true
            } catch ReviewError.replyGone {
                said = String(localized: "The agent stopped waiting. Copied to the clipboard instead.")
            } catch {
                NSLog("Midam: reply delivery failed: \(error)")
                said = String(localized: "Couldn't reach the agent. Copied to the clipboard instead.")
            }
        }
        if !delivered {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
        reply = Reply()
        waiting = nil
        sent = said
        AccessibilityNotification.Announcement(said).post()
    }

    /// The nearest folder above `url` holding .git, for the reply's relative paths.
    private static func repository(of url: URL) -> String? {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            dir = dir.deletingLastPathComponent()
        }
        return nil
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
            guard let self, case .success(let value) = result, let r = FindMatch.result(value) else { return }
            (self.index, self.count) = (r.index, r.count)
            if let matches = r.matches { self.matches = matches }
            if Store.shared.findOn, !self.query.isEmpty, self === Store.shared.current?.page {
                AccessibilityNotification.Announcement(r.count == 0 ? String(localized: "No matches") : String(localized: "\(r.index) of \(r.count)")).post()
            }
        }
    }
}
