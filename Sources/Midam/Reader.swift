import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// One reader window owning the open files as tabs of our own (native window tabbing
// cannot hide its bar with two or more tabs). Every way of opening a file goes through
// Store.open: the open panel, Open Recent, Finder and the Dock, links and drops.

/// One open file: its own Page (find state, view) and, in ReaderView, its own web view and watcher.
@MainActor final class OpenFile: Identifiable {
    let id = UUID()
    let url: URL
    let text: String
    /// The file's mtime and size as `text` was read (RenderCache.read); nil if it changed meanwhile.
    let stamp: FileStamp?
    let page = Page()
    /// Selected at least once. A tab gets its web view only then, so a restored session renders
    /// just the selected tab at launch and each other one when first shown.
    var shown = false

    init(url: URL, text: String, stamp: FileStamp? = nil) {
        self.url = url
        self.text = text
        self.stamp = stamp
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
    /// Conversations (and terminals) with agents, after the documents in the tab strip.
    @Published private(set) var agents: [AgentTab] = []
    /// The selected tab: a document's or an agent's id.
    @Published private(set) var selected: UUID?
    /// Where agents run; the UI talks to it only (D19).
    let host: AgentHost = LocalAgentHost(library: LibraryModel.shared)
    private var listening = false
    /// Sessions whose team made the panel open on Team already (once per session).
    private var teamShown = Set<String>()
    /// File > New Agent… (⌘N) shows its sheet.
    @Published var newAgentOpen = false
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
    /// Where the panel starts while it floats over the page: below the capsules (also while they
    /// slide down with the menu bar), or on the row's own line when it is hidden.
    var overlayTop: CGFloat { immersive ? rowTop : rowTop + TitleStrip.capsule + 8 }
    /// Back and forward through the places read (⌘[ ⌘]), in memory only.
    @Published private(set) var history = NavHistory<Spot>()
    /// View > Show Panel (⌥⌘I): the right panel (find, contents, shortcuts), for every tab, on until
    /// turned off, remembered with its last tab.
    @Published var panelOpen = UserDefaults.standard.bool(forKey: Store.panelKey) {
        didSet { UserDefaults.standard.set(panelOpen, forKey: Self.panelKey); findTurned(oldValue && panelTab == .find) }
    }
    @Published var panelTab = PanelTab(rawValue: UserDefaults.standard.string(forKey: Store.panelTabKey) ?? "") ?? .find {
        didSet { UserDefaults.standard.set(panelTab.rawValue, forKey: Self.panelTabKey); findTurned(panelOpen && oldValue == .find) }
    }
    private static let panelKey = "panelOpen", panelTabKey = "panelTab"
    /// The panel floats over the page's right edge: docking it would leave the page too narrow.
    /// Set by ReaderView as the window's width changes.
    var panelFloats = false
    /// Find is on while the panel shows its find tab: every page paints its own query's matches.
    var findOn: Bool { panelOpen && panelTab == .find }

    /// The panel open on `tab`; the same key again closes it (⌥⌘T, ⌘').
    func togglePanel(_ tab: PanelTab) {
        if panelOpen, panelTab == tab { panelOpen = false } else { show(tab) }
    }

    func show(_ tab: PanelTab) {
        panelTab = tab
        panelOpen = true
    }

    /// Find turned on or off: each page shown so far paints its matches again, or clears them.
    private func findTurned(_ was: Bool) {
        guard was != findOn else { return }
        for f in files where f.shown { findOn ? f.page.refresh() : f.page.clearFind() }
    }
    /// View > Immersive Mode (⇧⌘F): the header row hidden, app-wide, remembered across launches.
    @Published var immersive = UserDefaults.standard.bool(forKey: Store.immersiveKey) {
        didSet { UserDefaults.standard.set(immersive, forKey: Self.immersiveKey) }
    }
    private static let immersiveKey = "immersive"
    /// View > Show Sidebar (⌃⌘S): the documents list at the left, on until turned off, remembered.
    @Published var sidebarOpen = UserDefaults.standard.object(forKey: Store.sidebarKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarOpen, forKey: Self.sidebarKey) }
    }
    private static let sidebarKey = "sidebarOpen"
    private var keyMonitor: Any?
    /// The menus' single keys (no ⌘, ⌃ or ⌥): Space, j k g G d u e f b, n N, m (note), / (find), x (close tab).
    private static let singleKeys = Set([KeyboardShortcut.pageDown, .pageUp, .lineDown, .lineUp, .vimTop, .vimBottom,
                                         .halfPageDown, .halfPageUp, .halfPageUpE, .vimPageDown, .vimPageUp,
                                         .findSlash, .closeTabX, .nextChange, .addNote]
                                         .map { String($0.key.character).lowercased() })
    /// The find field has focus: single-key Go shortcuts (Space, j, k, g, G) stand down.
    @Published var findFocused = false
    @Published private(set) var recents: [URL] = NSDocumentController.shared.recentDocumentURLs
    var quitting = false
    /// The project whose tabs show (a registered root); nil until something opens.
    @Published private(set) var project: String?
    /// Other projects' tabs opened this run, kept live: their agents go on working.
    private var parked: [String: (files: [OpenFile], agents: [AgentTab], selected: UUID?)] = [:]
    /// Last session's tabs of projects not opened yet this run, read before anything can overwrite
    /// them: files given at launch (application(_:open:)) arrive before restore() runs.
    private var savedTabs = Store.loadTabs()
    private var restored = false

    private var window: NSWindow?
    private var observers: [Any] = []
    private static let tabsKey = "projectTabs", frameName = "MidamMain"

    var current: OpenFile? { files.first { $0.id == selected } }
    var currentAgent: AgentTab? { agents.first { $0.id == selected } }
    /// Every tab in strip order: the documents, then the agents.
    private var order: [UUID] { files.map(\.id) + agents.map(\.id) }
    var tabCount: Int { files.count + agents.count }

    // MARK: Opening

    func open(_ urls: [URL]) { for url in urls { open(url) } }

    /// Adds a tab for `url`, or selects it if that file is already open (by resolved path).
    func open(_ url: URL, fragment: String? = nil) {
        let url = url.standardizedFileURL
        enterProject(of: url)
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

    /// A midam:// link (the `midam` command, ReviewRequest): open a document at a line, or open it
    /// for review on the Reply tab, remembering the CLI waiting for the reply. Anything invalid is
    /// only logged: any process can open such a link.
    func handle(_ link: URL) {
        switch ReviewRequest.parse(link) {
        case .success(.open(let path, let line)):
            open(URL(fileURLWithPath: path), fragment: line.map { "midam-line-\($0)" })
        case .success(.review(let path, let reply)):
            open(URL(fileURLWithPath: path))
            if let reply, let f = file(at: URL(fileURLWithPath: path)) { f.page.waiting = reply; f.page.sent = nil }
            show(.reply)
        case .failure(let error):
            NSLog("Midam: ignored a midam:// link (\(String(describing: error)))")
        }
    }

    private func file(at url: URL) -> OpenFile? {
        let path = url.resolvingSymlinksInPath().path
        return files.first { $0.url.resolvingSymlinksInPath().path == path }
    }

    private func load(_ url: URL) -> OpenFile? {
        do {
            // With its stamp, so the tab's web view need not read it again; Data for the error.
            let read = try RenderCache.read(url) ?? (String(decoding: try Data(contentsOf: url), as: UTF8.self), nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            recents = NSDocumentController.shared.recentDocumentURLs
            return OpenFile(url: url, text: read.text, stamp: read.stamp)
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

    /// Shows last time's project with its tabs, unless a file given at launch chose one already.
    func restore() {
        guard !restored else { return }
        restored = true
        if project == nil, let last = savedTabs.current { switchProject(last, fillDefault: false) }
        save()
        if tabCount > 0 { showWindow() }
    }

    // MARK: Projects

    private static func loadTabs() -> TabsSave {
        let d = UserDefaults.standard
        if let data = d.data(forKey: tabsKey), let saved = try? JSONDecoder().decode(TabsSave.self, from: data) { return saved }
        let registered = LibraryModel.shared.registered
        return TabsSave.migrate(files: d.stringArray(forKey: "openFiles") ?? [], selected: d.string(forKey: "selectedFile")) {
            ProjectRoot.of(file: $0, registered: registered).root
        }
    }

    /// A document's project becomes the current one: registered first (and shown in the sidebar)
    /// when the document belonged to none.
    private func enterProject(of url: URL) {
        let r = ProjectRoot.of(file: url.path, registered: LibraryModel.shared.registered)
        if !r.registered { SidebarState.shared.reveal = [r.root] }
        switchProject(r.root, fillDefault: false)
    }

    /// Swaps the tab strip to `root`'s tabs: as left this run, else as saved last time, else (with
    /// `fillDefault`) its conversation or newest document.
    func switchProject(_ root: String, fillDefault: Bool = true) {
        guard root != project else { return }
        if let project {
            if let here = current { // cheap: the shown page's place, taken by its next first render
                let key = here.url.standardizedFileURL
                here.page.scrollOffset { MarkdownView.Coordinator.pendingOffsets[key] = $0 }
            }
            parked[project] = (files, agents, selected)
        }
        project = root
        if !LibraryModel.shared.registered.contains(root) { LibraryModel.shared.register(root: root) }
        selected = nil
        if let p = parked.removeValue(forKey: root) {
            files = p.files
            agents = p.agents
            if let id = p.selected { select(id: id, record: false) }
        } else if let s = savedTabs.projects.removeValue(forKey: root) {
            files = s.files.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }.compactMap(load)
            agents = []
            let pick = s.selected ?? 0
            if files.indices.contains(pick) { select(files[pick], record: false) }
            Task { // conversations come back with their history, in order, without running
                for (i, a) in s.agents.enumerated() {
                    let show = pick == s.files.count + i
                    if a.terminal {
                        let tab = terminalTab(TerminalTabState(agent: .claude, project: URL(fileURLWithPath: a.project), sessionID: a.session), group: root)
                        add(tab, select: show)
                    } else if let session = a.session {
                        await openChat(project: a.project, group: root, resume: session, select: show)
                    }
                }
                if project == root, selected == nil, let first = files.first { select(first, record: false) }
            }
        } else {
            files = []
            agents = []
            if fillDefault {
                if let c = host.conversations(project: root).last(where: { $0.sessionID != nil }) {
                    Task { await openChat(project: root, group: root, resume: c.sessionID, select: true) }
                } else if let doc = LibraryModel.shared.projects.first(where: { $0.id == root })?.groups.flatMap(\.docs)
                            .filter({ !$0.deleted }).max(by: { $0.modified < $1.modified }),
                          let f = load(LibraryModel.shared.url(for: doc)) {
                    files = [f]
                    select(f, record: false)
                }
            }
        }
        if selected == nil {
            window?.title = (root as NSString).lastPathComponent
            window?.representedURL = nil
        }
        save()
    }

    /// The Dock icon was clicked, or the app launched with nothing to open: show the window,
    /// with its sidebar, even with no tab.
    func reopen() { showWindow() }

    // MARK: Tabs

    /// Shows `file`'s tab. Moving there by hand, a link or opening a file (`record`) leaves the
    /// place read so far in the history; closing a tab, restoring and back/forward do not.
    func select(_ file: OpenFile, record: Bool = true) {
        if record, file.id != selected, let here = here() { history.leave(here) }
        if file.id != selected { current?.page.markRead() } // left: what it showed is now read (V3)
        file.shown = true
        Welcome.launchEmpty = false
        selected = file.id
        window?.title = file.url.lastPathComponent // Mission Control and the Window menu
        window?.representedURL = file.url
        save()
        LibraryModel.shared.opened(file.url) // shown is read (D5)
    }

    /// Selects tab `n` (1-based), or the last tab for nil.
    func select(_ n: Int?) {
        let ids = order, i = n.map { $0 - 1 } ?? ids.count - 1
        if ids.indices.contains(i) { select(id: ids[i]) }
    }

    func step(_ d: Int) {
        let ids = order
        guard let i = ids.firstIndex(where: { $0 == selected }), ids.count > 1 else { return }
        select(id: ids[(i + d + ids.count) % ids.count])
    }

    private func select(id: UUID, record: Bool = true) {
        if let f = files.first(where: { $0.id == id }) { select(f, record: record) }
        else if let a = agents.first(where: { $0.id == id }) { select(a, record: record) }
    }

    /// After closing the tab at `i` in strip order: its neighbour, or nothing left to show.
    private func closed(at i: Int, wasSelected: Bool) {
        let ids = order
        if ids.isEmpty {
            selected = nil
            window?.title = "Midam"
            window?.representedURL = nil
            save()
        } else if wasSelected {
            select(id: ids[min(i, ids.count - 1)], record: false)
        } else {
            save()
        }
    }

    /// Closes a tab; its web view and file watcher go with it. The last one leaves the window
    /// open, with the sidebar, as Mail does (D11).
    func close(_ file: OpenFile) {
        guard let i = files.firstIndex(where: { $0.id == file.id }) else { return }
        if selected == file.id { file.page.markRead() }
        SidebarChanges.shared.forget(file.url)
        files.remove(at: i)
        closed(at: i, wasSelected: selected == file.id)
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
        enterProject(of: url)
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

    /// ⌘W: the current tab in the reader window, or the window once it has none; any other
    /// window (Settings) just closes.
    func closeCurrent() {
        if let key = NSApp.keyWindow, key !== window { return key.performClose(nil) }
        if let current { close(current) } else if let currentAgent { close(currentAgent) } else { window?.performClose(nil) }
    }

    private func save() {
        guard restored else { return } // until restore() has read last session's tabs
        var all = savedTabs
        all.current = project
        func tabs(_ files: [OpenFile], _ agents: [AgentTab], _ selected: UUID?) -> ProjectTabsSave {
            // A conversation nothing was said in yet has no history to resume: it is not kept.
            let kept = agents.filter { $0.terminal != nil || $0.resumable || !$0.items.isEmpty }
            let ids = files.map(\.id) + kept.map(\.id)
            return ProjectTabsSave(files: files.map(\.url.path), agents: kept.map(\.save), selected: selected.flatMap { ids.firstIndex(of: $0) })
        }
        for (root, p) in parked { all.projects[root] = tabs(p.files, p.agents, p.selected) }
        if let project { all.projects[project] = tabs(files, agents, selected) }
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.tabsKey)
    }

    /// Agents of every project opened this run.
    private var allAgents: [AgentTab] { agents + parked.values.flatMap(\.agents) }

    /// The open tab of `session`, in any project.
    func agentTab(session: String) -> AgentTab? { allAgents.first { $0.session == session } }

    /// An agent of project `root` is at work or waiting: the project can't be removed now.
    func running(in root: String) -> Bool { allAgents.contains { $0.group == root && $0.busy } }

    /// Into its project's strip: the current one, else that project's parked tabs.
    private func add(_ tab: AgentTab, select show: Bool) {
        if tab.group == project {
            agents.append(tab)
            if show { select(tab) } else { save() }
        } else if parked[tab.group] != nil {
            parked[tab.group]?.agents.append(tab)
        } else {
            parked[tab.group] = ([], [tab], tab.id) // its project was never shown this run
            savedTabs.projects[tab.group] = nil
        }
    }

    // MARK: Agents

    /// A conversation with Claude in `project` (an AgentHost project id), new or resuming an
    /// earlier session; as a terminal tab instead when Settings > Show as Terminal is on.
    func openAgent(project: String, resume: String?) {
        showWindow()
        let root = ProjectRoot.of(file: project, registered: LibraryModel.shared.registered, isFolder: true)
        if !root.registered { SidebarState.shared.reveal = [root.root] }
        switchProject(root.root, fillDefault: false)
        if let resume, let open = agents.first(where: { $0.session == resume }) { return select(open) }
        if UserDefaults.standard.bool(forKey: Pref.agentTerminal) {
            let tab = terminalTab(TerminalTabState(agent: .claude, project: URL(fileURLWithPath: project), sessionID: resume), group: root.root)
            tab.terminal?.start()
            return add(tab, select: true)
        }
        Task { await openChat(project: project, group: root.root, resume: resume, select: true) }
    }

    private func openChat(project: String, group: String, resume: String?, select show: Bool) async {
        listen()
        do {
            let session = try await host.open(project: project, resume: resume)
            let tab = AgentTab(session: session, project: project, group: group)
            tab.resumable = resume != nil
            add(tab, select: show)
            for item in (try? await host.items(session)) ?? [] { tab.upsert(item) }
            tab.info = try? await host.info(session)
        } catch {
            NSApp.presentError(error)
        }
    }

    private func terminalTab(_ state: TerminalTabState, group: String) -> AgentTab {
        let t = AgentTerminal(state)
        t.openLink = { [weak self] url, _ in self?.open(url) }
        return AgentTab(session: state.sessionID, project: state.project.path, group: group, terminal: t)
    }

    func select(_ tab: AgentTab, record: Bool = true) {
        if record, tab.id != selected, let here = here() { history.leave(here) }
        Welcome.launchEmpty = false
        selected = tab.id
        tab.unseen = false
        window?.title = tab.title
        window?.representedURL = nil
        save()
    }

    /// Closes an agent tab; one whose turn is running asks first. The agent stops with it.
    func close(_ tab: AgentTab) {
        guard let i = order.firstIndex(of: tab.id) else { return }
        if tab.busy {
            let alert = NSAlert()
            alert.messageText = String(localized: "Stop the agent and close this tab?")
            alert.addButton(withTitle: String(localized: "Close"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        agents.removeAll { $0.id == tab.id }
        if let s = tab.session { LibraryModel.shared.setBlocked(s, root: tab.group, false) }
        tab.terminal?.terminate()
        if let s = tab.session, tab.terminal == nil { Task { try? await host.close(s) } }
        closed(at: i, wasSelected: selected == tab.id)
    }

    /// The error line's Restart: the session opened again from its history.
    func restart(_ tab: AgentTab) {
        guard let s = tab.session, let i = agents.firstIndex(where: { $0.id == tab.id }) else { return }
        Task {
            try? await host.close(s)
            guard let session = try? await host.open(project: tab.project, resume: s) else { return }
            let fresh = AgentTab(session: session, project: tab.project, group: tab.group)
            fresh.resumable = true
            fresh.draft = tab.draft
            if agents.indices.contains(i), agents[i].id == tab.id { agents[i] = fresh } else { agents.append(fresh) }
            select(fresh, record: false)
            for item in (try? await host.items(session)) ?? [] { fresh.upsert(item) }
            fresh.info = try? await host.info(session)
        }
    }

    /// The host's events, to the tab of their session.
    private func listen() {
        guard !listening else { return }
        listening = true
        let stream = host.events()
        Task { [weak self] in
            for await event in stream { self?.route(event) }
        }
    }

    private func route(_ event: HostEvent) {
        switch event {
        case .item(let session, let item):
            guard let tab = allAgents.first(where: { $0.session == session }) else { return }
            let first = tab.items.isEmpty
            tab.upsert(item)
            if first { save() } // now worth restoring
        case .info(let info):
            guard let tab = allAgents.first(where: { $0.session == info.id }) else { return }
            if info.state == .blocked, tab.state != .blocked {
                AccessibilityNotification.Announcement(String(localized: "Waiting for you")).post()
                if !NSApp.isActive { notifyBlocked(tab, topic: info.topic) }
            }
            if tab.state == .working, info.state == .idle, tab.id != selected { tab.unseen = true } // done, not seen yet
            LibraryModel.shared.setBlocked(info.id, root: tab.group, info.state == .blocked)
            tab.info = info
            if tab.id == selected { window?.title = tab.title }
            if info.subagents > 0, tab.group == project, teamShown.insert(info.id).inserted { show(.team) }
        }
    }

    /// ⌘Q with agents at work asks first; quitting ends every agent.
    func quitAgents(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let tabs = allAgents
        guard !tabs.isEmpty else { return .terminateNow }
        if tabs.contains(where: \.busy) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Agents are still running. Quit anyway?")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            for t in tabs {
                t.terminal?.terminate(grace: 0)
                if let s = t.session, t.terminal == nil { try? await host.close(s) }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Window

    /// The active colour theme's page background for the current appearance.
    private static func themeGround() -> NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let id = UserDefaults.standard.string(forKey: dark ? Pref.darkTheme : Pref.lightTheme) ?? ColorTheme.midam
        return ColorTheme.named(id, dark: dark).color("bg")
    }

    func setWindowGround(_ color: NSColor) { window?.backgroundColor = color }

    func showWindow() {
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
        if let current { w.title = current.url.lastPathComponent; w.representedURL = current.url } else { w.title = "Midam" }
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
        // Esc in the sidebar's list: closes its search first, then back to the page.
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           let w = NSApp.keyWindow, w === window, Sidebar.hasFocus(w) {
            if SidebarState.shared.searching { SidebarState.shared.closeSearch() } else { Sidebar.focusPage(w) }
            return true
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        guard mods.isSubset(of: .shift), let c = event.charactersIgnoringModifiers?.lowercased(), Self.singleKeys.contains(c) else { return false }
        let key = NSApp.keyWindow
        if let key, key === window, !(key.firstResponder is NSText), !Sidebar.hasFocus(key) { return false } // the page: the menu's
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

    /// ⌘W reaching the window itself (the standard Close item) closes one tab, not all of them,
    /// and the window once it has none; the red button closes the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown, tabCount > 0 else { return true }
        closeCurrent()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        history = NavHistory() // the places read went with the window
        current?.page.markRead()
        if !quitting {
            files.removeAll() // stops every tab's watcher
            selected = agents.first?.id // agents keep running: the Dock brings their tabs back
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

extension Store: UNUserNotificationCenterDelegate {
    /// One banner for an agent that started waiting while Midam is in the background; the first
    /// one asks macOS for permission. Not in an unbundled build (the tests'), which has no centre.
    func notifyBlocked(_ tab: AgentTab, topic: String?) {
        guard Bundle.main.bundleIdentifier != nil, let session = tab.session else { return }
        let content = UNMutableNotificationContent()
        content.title = topic ?? tab.title
        content.body = String(localized: "Waiting for you")
        content.userInfo = ["session": session, "project": tab.project]
        let request = UNNotificationRequest(identifier: session, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    /// A click on the banner: that conversation, in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let session = info["session"] as? String, let project = info["project"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            Store.shared.openAgent(project: project, resume: session)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false // no native tab bar or its Window menu items
        Theme.apply(UserDefaults.standard.string(forKey: Pref.theme) ?? "")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.shared.restore()
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = Store.shared }
        // With a cached list from the last run the sidebar is filled at once: no welcome then.
        Welcome.launchEmpty = Store.shared.files.isEmpty && !FileManager.default.fileExists(atPath: LibraryCache.standardURL.path)
        // Settings' font lists, built once off the main thread so the Fonts tab opens at once.
        DispatchQueue.global(qos: .utility).async { _ = Fonts.all; _ = BundledFonts.regular }
        // Files given at launch arrive before this; with nothing to show, the window opens anyway:
        // its sidebar is where to start.
        DispatchQueue.main.async { MainActor.assumeIsolated { if Store.shared.files.isEmpty { Store.shared.reopen() } } }
        LibraryModel.shared.rescan()
        // The first tab's web view, made ahead once launch has settled (a restored tab warms it too).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { MarkdownView.warmSpare() } }
    }

    /// No live watching in the demo (D13): the list is brought up to date on a return to the app,
    /// unless a scan is running or finished under a minute ago.
    func applicationDidBecomeActive(_ notification: Notification) { LibraryModel.shared.refresh() }

    /// Files from Finder, the Dock and `open`; midam:// links from the `midam` command (Store.handle).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !url.isFileURL { Store.shared.handle(url) }
        Store.shared.open(urls.filter(\.isFileURL))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Store.shared.reopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = Store.shared.quitAgents(sender)
        guard reply != .terminateCancel else { return reply }
        Store.shared.quitting = true // keep the open files for next launch
        Store.shared.current?.page.markRead()
        Baseline.queue.sync {} // its write lands before the app ends
        return reply
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

    private var theme: ColorTheme { ColorTheme.named(scheme == .dark ? darkTheme : lightTheme, dark: scheme == .dark) }
    /// The active colour theme's page background: shown before the page has styled itself,
    /// so a dark theme never flashes Midam's paper first.
    private var ground: NSColor { theme.color("bg") }

    @AppStorage(PanelColumn.widthKey) private var panelWidth = PanelColumn.defaultWidth
    @AppStorage(SidebarColumn.widthKey) private var sidebarWidth = SidebarColumn.defaultWidth
    /// The page's narrowest: below it the panel floats over the page instead of docking.
    private static let minPage: CGFloat = 420

    var body: some View {
        let reading = Reading(font: font, mono: codeFont, size: size,
                              tracking: Spacing.tracking.value(tracking), leading: Spacing.leading.value(leading),
                              paragraph: Spacing.paragraph.value(paragraph), measure: Spacing.measure.value(measure),
                              header: store.header)
        let page = store.current?.page
        let side = store.sidebarOpen ? SidebarColumn.clamp(sidebarWidth) : 0
        // The sidebar at the left, under the traffic lights, the panel at the right; the header
        // floats over the page between them. The page's place in the row never changes, so its
        // web views stay as the panel docks or floats.
        GeometryReader { window in
            let floats = window.size.width - side - PanelColumn.clamp(panelWidth) < Self.minPage
            HStack(spacing: 0) {
                if store.sidebarOpen {
                    SidebarColumn(store: store)
                        .transition(.move(edge: .leading))
                        .zIndex(1) // its resize strip reaches over the page's edge
                }
                content(reading: reading, page: page, floats: floats)
                if store.panelOpen, !floats {
                    PanelColumn(store: store)
                        .transition(.move(edge: .trailing))
                        .zIndex(1) // its resize strip reaches over the page's edge
                }
            }
            .onChange(of: floats, initial: true) { store.panelFloats = floats }
        }
        .frame(minWidth: side + Self.minPage, minHeight: 320) // the window's narrowest: the panel can float
        .animation(reduceMotion ? nil : .smooth, value: store.sidebarOpen)
        .animation(reduceMotion ? nil : .smooth, value: store.panelOpen)
        .overlay(alignment: .topTrailing) { // the panel button: one place, open or closed, at the header's right end
            PanelToggle(store: store)
                .frame(width: TitleStrip.capsule, height: TitleStrip.capsule) // alone: a circle
                .glassCapsule()
                .padding(.top, store.rowTop)
                .padding(.trailing, 10)
                .opacity(store.immersive ? 0 : 1) // as the header's
                .allowsHitTesting(!store.immersive)
                .accessibilityHidden(store.immersive)
                .animation(reduceMotion ? nil : .smooth, value: store.immersive)
        }
        .overlay { TipLayer() }
        .sheet(isPresented: $store.newAgentOpen) { NewAgentSheet(store: store) }
        .coordinateSpace(.named(Tips.space))
        // The page runs to the top of the window and scrolls under the floating capsules;
        // render.js pads its first line below them.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: ground).ignoresSafeArea())
        .onChange(of: ground, initial: true) { store.setWindowGround(ground) }
        .tint(Color.accentColor)
    }

    private func content(reading: Reading, page: Page?, floats: Bool) -> some View {
        ZStack {
            ForEach(store.files.filter(\.shown)) { f in
                MarkdownView(text: f.text, stamp: f.stamp, fileURL: f.url, reading: reading, page: f.page, active: f.id == store.selected)
            }
            if let agent = store.currentAgent {
                Group {
                    if let terminal = agent.terminal { TerminalTabView(terminal: terminal, top: store.header) }
                    else { ChatView(tab: agent, store: store, ink: Color(nsColor: theme.color("text")), muted: Color(nsColor: theme.color("muted"))) }
                }
                .id(agent.id)
                .background(Color(nsColor: ground))
            }
            if store.tabCount == 0 {
                NoDocument(store: store, text: Color(nsColor: theme.color("text")), muted: Color(nsColor: theme.color("muted")))
                    .padding(.top, store.header)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            TitleStrip(store: store, panelDocked: store.panelOpen && !floats)
        }
        .overlay {
            if store.panelOpen, floats {
                FloatingPanel(store: store)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 16)))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: store.immersive) // the header's fade, the panel moving up
    }
}

/// The reader window's content. The capsules sit in the title bar's zone, so the view never
/// offers a mouse-down to AppKit for moving the window: clicks always reach them, and the
/// header's empty space moves the window through WindowDragArea instead.
final class ReaderHost: NSHostingView<ReaderView> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The header: a row of floating glass over the page, on the traffic lights' line in a window:
/// the sidebar button (as Safari's) while the sidebar is hidden, ‹ › (back, forward), the tabs' capsule, and at the right the
/// source button; the panel button floats at the window's right end (ReaderView), so the row leaves
/// it room unless the panel is docked. Empty space in the header drags the window.
struct TitleStrip: View {
    @ObservedObject var store: Store
    let panelDocked: Bool

    /// The capsules' height, a standard toolbar control's: centred on the lights' line (16 pt
    /// down), 30 pt leaves 1 pt above them and room around the 28 pt icon targets.
    static let capsule: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            if !store.sidebarOpen { // open: the toggle lives in the sidebar's top strip (SidebarButtons)
                SidebarToggle(store: store)
                    .frame(width: Self.capsule, height: Self.capsule) // alone: a circle
                    .glassCapsule()
                    .fixedSize()
            }
            HStack(spacing: 0) {
                StripIcon(label: "Back", keys: [.back], enabled: store.history.canGoBack, action: { store.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                StripIcon(label: "Forward", keys: [.forward], enabled: store.history.canGoForward, action: { store.goForward() }) {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.horizontal, 4)
            .frame(height: Self.capsule)
            .glassCapsule()
            .fixedSize()
            if store.tabCount > 0 {
                TabStrip(store: store)
                    .layoutPriority(1) // offered all the room before the spacer, so it scrolls only when it must
            }
            Spacer(minLength: 0)
            if let page = store.current?.page {
                SourceToggle(page: page)
                    .frame(width: Self.capsule, height: Self.capsule) // alone: a circle
                    .glassCapsule()
                    .fixedSize()
            }
        }
        // Immersive mode: faded out and out of reach, but kept in place. The drag strip stays.
        .opacity(store.immersive ? 0 : 1)
        .allowsHitTesting(!store.immersive)
        .accessibilityHidden(store.immersive)
        .frame(height: Self.capsule)
        .padding(.leading, store.sidebarOpen ? 10 : store.rowLeading) // the lights sit over the sidebar
        .padding(.trailing, panelDocked ? 10 : 10 + Self.capsule + 8)
        .padding(.top, store.rowTop)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background { WindowDragArea() }
        .allowsHitTesting(!(store.immersive && store.fullScreen)) // nothing to drag there: the page's
        .tint(Color.accentColor)
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
            ForEach(store.agents) { AgentTabButton(tab: $0, store: store).id($0.id) }
        }
        .padding(.horizontal, 4)
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
                    .font(.system(size: 13, weight: on ? .medium : .regular))
                    .foregroundStyle(GlassLabel.style(strong: on, opaque: reduceTransparency))
                    .lineLimit(1)
                if file.page.changes > 0 { ChangeChip(n: file.page.changes) }
                Color.clear.frame(width: 20, height: 20) // room for the ×
            }
            .padding(.leading, 12)
            .padding(.trailing, 3)
            .frame(height: TitleStrip.capsule - 8) // 4 pt of glass around the current tab's pill
            .background(Color.primary.opacity(on ? 0.09 : 0), in: Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fastTip(Text(verbatim: file.url.path + "\n" + (file.page.changes > 0 ? Words.changes(file.page.changes) + "\n" : "")) + position)
        .accessibilityLabel(Text(verbatim: file.page.changes > 0 ? file.url.lastPathComponent + ", " + Words.changes(file.page.changes) : file.url.lastPathComponent))
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
