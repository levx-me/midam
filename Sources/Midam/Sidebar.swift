import AppKit
import UniformTypeIdentifiers
import SwiftUI
import WebKit

// The left sidebar, Mail-style: the documents agents wrote (LibraryModel), by project, then by
// kind, newest first. A click opens a document as a tab (Store.open focuses one already open).
// Also the content area's own screens while no tab is open: the first run's welcome, or a calm
// empty page.

extension DocKind {
    /// The shown name; the raw value is the stored ID and never shown.
    var name: LocalizedStringResource {
        switch self {
        case .design: "Design"
        case .plan: "Plans"
        case .research: "Research"
        case .ops: "Operations"
        case .guide: "Guides"
        case .handoff: "Handoffs"
        case .instructions: "Agent Instructions"
        case .memory: "Memory"
        case .notes: "Working Notes"
        case .other: "Other"
        }
    }

    /// SF Symbols names, not shown text (`return` keeps strings-audit from taking them for keys).
    var symbol: String {
        switch self {
        case .design: return "pencil.and.ruler"
        case .plan: return "list.bullet.rectangle"
        case .research: return "doc.text.magnifyingglass"
        case .ops: return "gearshape.2"
        case .guide: return "book"
        case .handoff: return "arrow.right.doc.on.clipboard"
        case .instructions: return "terminal"
        case .memory: return "brain"
        case .notes: return "note.text"
        case .other: return "doc"
        }
    }
}

/// A project dragged inside the app: a type of our own, so Finder takes nothing from it.
struct ProjectDrag: Transferable, Codable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.midam.project-drag"))
    }
}

/// What the sidebar remembers while the app runs (in memory only, so every launch starts
/// collapsed and unfiltered): which projects and kinds are open (D9), the selected row, what is
/// being dragged, the search (⌘F with the list focused) and the unread filter (⌥⌘U).
@MainActor final class SidebarState: ObservableObject {
    static let shared = SidebarState()
    @Published var expanded: Set<String> = []
    @Published var selection: SidebarItem?
    /// The project or document a drag started from: drop targets light up only for what they take.
    @Published var draggingProject: String?
    @Published var draggingDoc: String?
    @Published var addingProject = false
    /// Projects just added from the Add Project sheet: selected and scrolled to once a scan lists them.
    var reveal: [String] = []
    /// A row to bring into view (ScrollViewReader); cleared once scrolled.
    @Published var scrollTarget: SidebarItem?

    private var dragWatch: Task<Void, Never>?
    /// SwiftUI says nothing when a drag is cancelled: clear the drag once the mouse button is up
    /// (after a beat, so a drop handler still sees it).
    func watchDragEnd() {
        dragWatch?.cancel()
        dragWatch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.draggingProject = nil
            self?.draggingDoc = nil
        }
    }

    // Search: the field shows while `searching`; `matches` is nil while the query is empty.
    @Published private(set) var searching = false
    @Published var query = "" { didSet { if query != oldValue { runSearch() } } }
    @Published private(set) var matches: [String: DocMatch]?
    @Published private(set) var searchBusy = false
    @Published private(set) var searchFocus = 0 // bumped to put the cursor in the field
    var searchFieldFocused = false

    /// The unread filter: what was unread when it was turned on (Library.unreadFilter); nil when off.
    @Published private(set) var keptUnread: Set<String>?
    var unreadOnly: Bool { keptUnread != nil }
    var filtering: Bool { keptUnread != nil || matches != nil }

    private var savedExpanded: Set<String>? // the tree as it was before a filter or the search
    private var autoExpanded: Set<String> = []
    private var searchTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private let texts = DocTexts()

    func isOpen(_ key: String) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(key) },
                set: { if $0 { self.expanded.insert(key) } else { self.expanded.remove(key) } })
    }

    static func key(_ project: LibraryProject, _ kind: DocKind) -> String { project.id + "\u{1F}" + kind.rawValue }

    /// The tree as the filters leave it.
    func shown(_ list: [LibraryProject]) -> [LibraryProject] {
        var list = list
        if let kept = keptUnread { list = Library.unreadFilter(list, kept: kept) }
        if let m = matches { list = Library.filter(list) { m[$0.id] != nil } }
        return list
    }

    /// While a filter is on, groups it brings into view open once; one the user then closes stays closed.
    func autoExpand(_ keys: Set<String>) {
        guard filtering else { return }
        let new = keys.subtracting(autoExpanded)
        guard !new.isEmpty else { return }
        expanded.formUnion(new)
        autoExpanded.formUnion(new)
    }

    private func begin() {
        guard savedExpanded == nil else { return }
        savedExpanded = expanded
        autoExpanded = []
    }

    private func endIfIdle() {
        guard !filtering, !searching, let saved = savedExpanded else { return }
        expanded = saved
        savedExpanded = nil
    }

    // MARK: Search

    func openSearch() {
        if !searching {
            begin()
            searching = true
            let paths = LibraryModel.shared.projects.flatMap { $0.groups.flatMap { $0.docs.flatMap { $0.variants.map(\.path) } } }
            warmTask = Task { [texts] in await texts.warm(paths) } // read ahead while the first letters are typed
        }
        searchFocus += 1
    }

    /// Esc: clears and closes, and the tree comes back as it was.
    func closeSearch() {
        guard searching else { return }
        warmTask?.cancel()
        searching = false
        searchFieldFocused = false // the field goes away with no focus change to report it
        query = ""
        endIfIdle()
    }

    /// Runs the query off the main thread (DocTexts); a newer keystroke cancels it.
    func runSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searching, !q.isEmpty else {
            matches = nil
            searchBusy = false
            endIfIdle()
            return
        }
        let docs = LibraryModel.shared.projects.flatMap { $0.groups.flatMap(\.docs) }
        searchBusy = true
        searchTask = Task { [texts] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let found = await texts.search(q, in: docs)
            guard !Task.isCancelled else { return }
            matches = found
            searchBusy = false
            AccessibilityNotification.Announcement(found.isEmpty ? String(localized: "No Matches") : Words.documents(found.count)).post()
        }
    }

    // MARK: Unread filter

    func setUnreadOnly(_ on: Bool) {
        guard on != unreadOnly else { return }
        if on {
            begin()
            keptUnread = Library.unreadIds(LibraryModel.shared.projects)
        } else {
            keptUnread = nil
            endIfIdle()
        }
        AccessibilityNotification.Announcement(on ? String(localized: "Showing only unread documents") : String(localized: "Showing all documents")).post()
    }
}

enum SidebarItem: Hashable {
    case project(String)
    case kind(String, DocKind)
    case doc(String)
}

/// Counts and times as the sidebar words them, in the app's language.
@MainActor enum Words {
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named // "now", "yesterday"
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return f
    }()

    static func ago(_ date: Date) -> String { ago.localizedString(for: min(date, Date()), relativeTo: Date()) }

    static func documents(_ n: Int) -> String {
        n == 1 ? String(localized: "1 document") : String(format: String(localized: "%lld documents"), n)
    }

    static func unread(_ n: Int) -> String { String(format: String(localized: "%lld unread"), n) }

    /// Places changed since the version last read (V3).
    static func changes(_ n: Int) -> String {
        n == 1 ? String(localized: "1 change") : String(format: String(localized: "%lld changes"), n)
    }

    static func claudeProjects(_ n: Int) -> String {
        n == 1 ? String(localized: "1 Claude Code project") : String(format: String(localized: "%lld Claude Code projects"), n)
    }

    static func codexSessions(_ n: Int) -> String {
        n == 1 ? String(localized: "1 Codex session") : String(format: String(localized: "%lld Codex sessions"), n)
    }

    /// "Watching 3 Claude Code projects and 2 Codex sessions"; nil when no agent was found.
    static func watching(_ a: FoundAgents) -> String? {
        switch (a.claudeProjects > 0, a.codexSessions > 0) {
        case (true, true): String(format: String(localized: "Watching %@ and %@"), claudeProjects(a.claudeProjects), codexSessions(a.codexSessions))
        case (true, false): String(format: String(localized: "Watching %@"), claudeProjects(a.claudeProjects))
        case (false, true): String(format: String(localized: "Watching %@"), codexSessions(a.codexSessions))
        case (false, false): nil
        }
    }

    /// `text` with each match of `query` marked (semibold on a soft tint that reads in both appearances).
    static func marked(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        for r in Library.ranges(of: query, in: text) {
            guard let a = Range(r, in: out) else { continue }
            out[a].inlinePresentationIntent = .stronglyEmphasized
            out[a].backgroundColor = Color.primary.opacity(0.13)
        }
        return out
    }
}

/// The ⋯ menu, the right-click menu and VoiceOver's actions share these. They act on the
/// project as listed in full, not as a filter shows it.
@MainActor enum ProjectActions {
    private static var library: LibraryModel { .shared }
    private static func full(_ id: String) -> LibraryProject? { library.projects.first { $0.id == id } }
    private static func say(_ s: String) { AccessibilityNotification.Announcement(s).post() }

    static func togglePin(_ id: String) {
        let pinned = library.pinned.contains(id)
        Sidebar.animate { if pinned { library.unpin(id) } else { library.pin(id) } }
        say(pinned ? String(localized: "Unpinned") : String(localized: "Pinned to the top"))
    }

    /// A drag dropped `id` on pinned row `target` (or on the header or the empty zone: nil).
    static func drop(_ id: String, onto target: String?) {
        let wasPinned = library.pinned.contains(id)
        Sidebar.animate { library.pin(id, onto: target) }
        if wasPinned { sayPosition(id) } else { say(String(localized: "Pinned to the top")) }
    }

    static func move(_ id: String, by d: Int) {
        Sidebar.animate { library.movePinned(id, by: d) }
        sayPosition(id)
    }

    private static func sayPosition(_ id: String) {
        let a = available(id)
        if let i = a.index { say(String(format: String(localized: "Moved to position %lld of %lld"), i + 1, a.count)) }
    }

    static func markAllRead(_ id: String) {
        guard let p = full(id) else { return }
        library.markAllRead(p)
        say(String(localized: "Marked as read"))
    }

    static func reveal(_ id: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)]) }

    static func copyPath(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        say(String(localized: "Path copied"))
    }

    /// The unread documents, else all of them, newest first; the newest ends up in front.
    static func openAll(_ id: String) {
        guard let p = full(id) else { return }
        let docs = p.groups.flatMap(\.docs).filter { !$0.deleted }
        let unread = docs.filter(\.unread)
        // ponytail: at most 20 tabs; a project can hold hundreds of working notes. Ask first if that cap bites.
        let urls = (unread.isEmpty ? docs : unread).sorted { $0.modified > $1.modified }.prefix(20).map(library.url(for:))
        guard let first = urls.first else { return }
        Store.shared.open(Array(urls))
        Store.shared.open(first)
    }

    static func hide(_ id: String) {
        Sidebar.animate {
            library.unpin(id)
            library.hide(id)
        }
        say(String(localized: "Hidden from the list. Settings brings it back."))
    }

    static func available(_ id: String) -> (pinned: Bool, unread: Bool, index: Int?, count: Int) {
        let pins = library.pinned.filter { pid in library.projects.contains { $0.id == pid } }
        return (library.pinned.contains(id), (full(id)?.unread ?? 0) > 0, pins.firstIndex(of: id), pins.count)
    }
}

/// The items of the ⋯ and right-click menus of a project row.
private struct ProjectMenu: View {
    let id: String
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let a = ProjectActions.available(id)
        if a.pinned { Button("Unpin") { ProjectActions.togglePin(id) } } else { Button("Pin") { ProjectActions.togglePin(id) } }
        if a.pinned, let i = a.index {
            Button("Move Up") { ProjectActions.move(id, by: -1) }.disabled(i == 0)
            Button("Move Down") { ProjectActions.move(id, by: 1) }.disabled(i >= a.count - 1)
        }
        Divider()
        Button("Mark All as Read") { ProjectActions.markAllRead(id) }.disabled(!a.unread)
        Button("Open All in Tabs") { ProjectActions.openAll(id) }
        Divider()
        Button("Show in Finder") { ProjectActions.reveal(id) }
        Button("Copy Path") { ProjectActions.copyPath(id) }
        Divider()
        Button("Hide from List") { ProjectActions.hide(id) }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var store: Store
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var state = SidebarState.shared
    @State private var listFocused = false
    @State private var lastSelection: SidebarItem?

    var body: some View {
        let shown = state.shown(library.projects)
        VStack(spacing: 0) {
            // The traffic lights' strip: it moves the window, as the header does.
            WindowDragArea().frame(height: store.fullScreen ? 6 + TitleStrip.capsule + 6 : store.header)
                .overlay(alignment: .topTrailing) { // on the lights' line, clear of the drag gesture
                    HStack(spacing: 0) {
                        SidebarToggle(store: store)
                        UnreadFilterButton(state: state)
                    }
                    .frame(height: TitleStrip.capsule)
                    .padding(.top, store.rowTop)
                    .padding(.trailing, 10)
                }
            if state.searching {
                SidebarSearchField(state: state, toList: { focusList(firstOf: shown) }, closed: { focusList(firstOf: []) })
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if library.projects.isEmpty { SidebarEmpty(library: library) }
            else if shown.isEmpty, state.filtering { FilterEmpty(state: state) }
            else { list(shown).clipped() } // rows scroll out of sight below the lights' strip, not under it
            footer
        }
        .background { SidebarMaterial().ignoresSafeArea() }
        .sheet(isPresented: $state.addingProject) { AddProjectSheet() }
        .onChange(of: Library.groupKeys(shown), initial: true) { _, keys in state.autoExpand(keys) }
        .onChange(of: library.projects) { if state.matches != nil { state.runSearch() } } // new or changed docs
    }

    /// Pin, unpin and hide move rows between the sections; under Reduce Motion they just change.
    @MainActor static func animate(_ change: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { change() }
        else { withAnimation(.snappy(duration: 0.28), change) }
    }

    // MARK: Keyboard focus (⌘T, ⌘F, Esc, Return)

    static func find<V: NSView>(_ type: V.Type, in view: NSView?) -> V? {
        guard let view else { return nil }
        if let v = view as? V, !v.isHiddenOrHasHiddenAncestor { return v }
        for s in view.subviews { if let v = find(type, in: s) { return v } }
        return nil
    }

    /// The sidebar's list has keyboard focus in this window.
    @MainActor static func hasFocus(_ window: NSWindow) -> Bool {
        guard let outline = find(NSOutlineView.self, in: window.contentView), let r = window.firstResponder as? NSView else { return false }
        return r === outline || r.isDescendant(of: outline)
    }

    @MainActor static func focusPage(_ window: NSWindow) {
        if let web = find(WKWebView.self, in: window.contentView) { window.makeFirstResponder(web) }
    }

    /// A tab coming forward or find closing gives the page focus, but never takes it from the list
    /// (as in Mail): a click on a row opens the document and the list keeps focus; only ↩, Esc and
    /// ⌘T move on to the page (focusPage).
    @MainActor static func pageTakesFocus(_ web: NSView) {
        guard let window = web.window, !hasFocus(window) else { return }
        window.makeFirstResponder(web)
    }

    /// ⌘T (New Tab): into the list (opening the sidebar; the current tab's row is already selected, else the first project). Again in the list it stays there (Esc or ↩ go to the page).
    @MainActor static func toggleFocus(_ store: Store) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        store.sidebarOpen = true
        let state = SidebarState.shared, library = LibraryModel.shared
        if state.selection == nil {
            let parts = Library.sections(state.shown(library.projects), pinned: library.pinned)
            state.selection = (parts.pinned + parts.all).first.map { .project($0.id) }
        }
        // The current tab's row must show, or the list takes focus with nothing highlighted: open
        // its project and kind (every launch starts collapsed).
        if case .doc(let id)? = state.selection {
            for p in library.projects {
                for g in p.groups where g.docs.contains(where: { $0.id == id }) { state.expanded.formUnion([p.id, SidebarState.key(p, g.kind)]) }
            }
        }
        DispatchQueue.main.async { // after the column exists
            guard let outline = find(NSOutlineView.self, in: window.contentView) else { return }
            window.makeFirstResponder(outline)
            if let r = outline.selectedRowIndexes.first { outline.scrollRowToVisible(r) }
        }
    }

    /// From the search field (↓ or Return) into the results, the first document selected; or
    /// back to the list after Esc.
    private func focusList(firstOf shown: [LibraryProject]) {
        let parts = Library.sections(shown, pinned: library.pinned)
        if let doc = (parts.pinned + parts.all).lazy.flatMap({ $0.groups.flatMap(\.docs) }).first { state.selection = .doc(doc.id) }
        guard let window = NSApp.keyWindow else { return }
        DispatchQueue.main.async {
            guard let outline = Sidebar.find(NSOutlineView.self, in: window.contentView) else { return }
            window.makeFirstResponder(outline)
            if let r = outline.selectedRowIndexes.first { outline.scrollRowToVisible(r) }
        }
    }

    private func list(_ shown: [LibraryProject]) -> some View {
        let parts = Library.sections(shown, pinned: library.pinned)
        return ScrollViewReader { proxy in List(selection: $state.selection) {
            if !(state.filtering && parts.pinned.isEmpty) {
                Section {
                    ForEach(parts.pinned) { tree($0, pinned: parts.pinned) }
                    if parts.pinned.isEmpty { PinDropZone(state: state) }
                } header: {
                    SectionHeader(title: Text("Pinned"), dropPins: true)
                }
            }
            if !(state.filtering && parts.all.isEmpty) {
                Section {
                    ForEach(parts.all) { tree($0, pinned: nil) }
                } header: {
                    SectionHeader(title: Text("All Projects"), add: true)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(FirstResponderWatch(changed: { listFocused = $0 }, rowClicked: { reclick in
            // A click on the selected row can leave the list with nothing selected: act on that row.
            if let item = state.selection ?? (reclick ? lastSelection : nil) { primary(item) }
        }))
        .onChange(of: state.selection) { _, new in if let new { lastSelection = new } } // SwiftUI's focus state does not follow the outline view
        .environment(\.sidebarFocused, listFocused) // unread dots take the accent only while the list has focus
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first, items.count == 1 { menu(item) }
        } primaryAction: { items in
            // Return; a double-click's clicks already acted (rows act on a single click).
            if NSApp.currentEvent?.type == .keyDown { items.forEach(primary) }
        }
        // The current tab's row stays highlighted.
        .onChange(of: store.selected, initial: true) { syncSelection() }
        .onChange(of: library.projects) {
            if state.selection == nil { syncSelection() } // keeps a row arrowed to
            // An added root may sit inside a repository the sidebar lists by its own root.
            let near = { (root: String, p: LibraryProject) in p.id == root || root.hasPrefix(p.id + "/") || p.id.hasPrefix(root + "/") }
            if let project = state.reveal.lazy.compactMap({ root in library.projects.first { near(root, $0) } }).first {
                state.reveal = []
                let item = SidebarItem.project(project.id)
                // The list takes a selection only once its rows exist: set it on the next turn,
                // then scroll to it as soon as the outline shows it selected.
                DispatchQueue.main.async { state.scrollTarget = item; state.selection = item }
                func scroll(_ tries: Int) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard let w = NSApp.mainWindow ?? NSApp.windows.first(where: { Sidebar.find(NSOutlineView.self, in: $0.contentView) != nil }),
                              let outline = Sidebar.find(NSOutlineView.self, in: w.contentView) else { return }
                        if state.selection != item { state.selection = item }
                        guard let r = outline.selectedRowIndexes.first else { if tries < 12 { scroll(tries + 1) }; return }
                        w.makeFirstResponder(outline)
                        outline.scrollRowToVisible(r)
                    }
                }
                scroll(0)
            }
        }
        .accessibilityLabel("Documents")
        .onChange(of: state.scrollTarget) { _, target in
            guard let target else { return }
            proxy.scrollTo(target, anchor: .center) // an offscreen row takes no selection until scrolled to
            state.scrollTarget = nil
        }
        }
    }

    /// A project, its kinds and their documents. `pinned` is the pinned section's rows, nil in All.
    private func tree(_ project: LibraryProject, pinned: [LibraryProject]?) -> some View {
        DisclosureGroup(isExpanded: state.isOpen(project.id)) {
            ForEach(project.groups) { group in
                let key = SidebarState.key(project, group.kind)
                DisclosureGroup(isExpanded: state.isOpen(key)) {
                    ForEach(group.docs) { doc in
                        DocRow(doc: doc, url: library.url(for: doc), match: state.matches?[doc.id], query: state.query) { primary(.doc(doc.id)) }
                            .tag(SidebarItem.doc(doc.id))
                    }
                } label: {
                    KindRow(project: project, group: group) { primary(.kind(project.id, group.kind)) }
                        .tag(SidebarItem.kind(project.id, group.kind))
                }
            }
        } label: {
            ProjectRow(project: project, pinnedRows: pinned) { primary(.project(project.id)) }
                .tag(SidebarItem.project(project.id))
                .id(SidebarItem.project(project.id))
        }
    }

    private var footer: some View { ScanLine(scanning: library.scanning, progress: library.progress) }

    // MARK: Actions

    private func find(_ id: String) -> (LibraryProject, LibraryDoc)? {
        for p in library.projects {
            for g in p.groups { if let d = g.docs.first(where: { $0.id == id }) { return (p, d) } }
        }
        return nil
    }

    private func syncSelection() {
        guard let here = store.current?.url.resolvingSymlinksInPath().path, let id = library.docAtPath[here] else {
            state.selection = store.project.map { .project($0) } // a conversation: its project's row
            return
        }
        if state.selection != .doc(id) { state.selection = .doc(id) }
    }

    /// A click or Return: a document opens (or its tab comes forward); a project or kind opens or closes.
    private func primary(_ item: SidebarItem) {
        // A mouse click on a row is handled by the row's tap gesture, which swallows the click
        // before the outline view sees it, so the list would never take focus: give it focus here.
        if NSApp.currentEvent?.type != .keyDown, let w = NSApp.keyWindow,
           let outline = Sidebar.find(NSOutlineView.self, in: w.contentView), w.firstResponder !== outline {
            w.makeFirstResponder(outline)
        }
        if state.selection != item { state.selection = item } // a click selects its row, as the arrow keys do
        switch item {
        case .doc(let id):
            guard let (_, doc) = find(id), !doc.deleted else { return } // a deleted one has nothing to show (V4)
            store.open(library.url(for: doc))
            if NSApp.currentEvent?.type == .keyDown, let w = NSApp.keyWindow { // Return: on to reading
                DispatchQueue.main.async { Sidebar.focusPage(w) }
            }
        case .project(let id):
            state.expanded.formSymmetricDifference([id])
            store.switchProject(id) // its tabs
        case .kind(let pid, let kind):
            state.expanded.formSymmetricDifference([pid + "\u{1F}" + kind.rawValue])
        }
    }

    @ViewBuilder private func menu(_ item: SidebarItem) -> some View {
        switch item {
        case .doc(let id):
            if let (_, doc) = find(id) {
                Button("Open") { primary(item) }.disabled(doc.deleted)
                Menu("Move to Kind") {
                    ForEach(DocKind.allCases.filter { $0 != doc.kind }, id: \.self) { kind in
                        Button { Sidebar.move(doc, to: kind) } label: { Text(kind.name) }
                    }
                }
                .disabled(doc.deleted)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.url(for: doc)]) }
                    .disabled(doc.deleted)
                if let s = library.session(for: library.url(for: doc).path), s.agent == .claude {
                    Button("Resume the Session That Wrote This") { Store.shared.openAgent(project: s.cwd, resume: s.id) }
                }
                if doc.deleted {
                    Divider()
                    Button("Remove from List") { library.dismiss(doc) }
                }
            }
        case .project(let id):
            ProjectMenu(id: id)
        case .kind:
            EmptyView()
        }
    }

    /// The menus and drops share this, and VoiceOver hears what happened.
    @MainActor static func move(_ doc: LibraryDoc, to kind: DocKind) {
        guard doc.kind != kind else { return }
        LibraryModel.shared.setKind(kind, for: doc)
        AccessibilityNotification.Announcement(String(format: String(localized: "Moved to %@"), String(localized: kind.name))).post()
    }
}

/// Native sidebar vibrancy, as in Mail and Finder; opaque under Reduce Transparency by itself.
/// The docked right panel wears it too.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The thin line at the sidebar's foot while a scan runs.
private struct ScanLine: View {
    let scanning: Bool
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .scaleEffect(x: max(0.02, progress), anchor: .leading)
            .opacity(scanning ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: scanning)
            .accessibilityElement()
            .accessibilityLabel("Looking for documents…")
            .accessibilityValue(Text(verbatim: "\(Int(progress * 100))%"))
            .accessibilityHidden(!scanning)
    }
}

/// The sidebar button, in the header while the sidebar is hidden and in the sidebar's top strip while it shows.
struct SidebarToggle: View {
    @ObservedObject var store: Store

    var body: some View {
        StripIcon(label: store.sidebarOpen ? "Hide Sidebar" : "Show Sidebar", keys: [.sidebarSafari, .sidebar],
                  action: { store.sidebarOpen.toggle() }) { // animated as from the keys, by ReaderView
            Image(systemName: "sidebar.left")
        }
    }
}

/// Mail's unread filter, beside the sidebar button in the sidebar's top strip:
/// only unread documents while on (filled accent).
struct UnreadFilterButton: View {
    @ObservedObject var state: SidebarState

    var body: some View {
        let on = state.unreadOnly
        StripIcon(label: "Show Only Unread", keys: [.unreadOnly], active: on, action: { state.setUnreadOnly(!on) }) {
            if on { Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor) }
            else { Image(systemName: "line.3.horizontal.decrease.circle") }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The search field at the top of the sidebar. ↓ or Return go to the results, Esc closes it.
private struct SidebarSearchField: View {
    @ObservedObject var state: SidebarState
    let toList: () -> Void
    let closed: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Documents", text: $state.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(toList)
                .onKeyPress(.downArrow) { toList(); return .handled }
                .onExitCommand { state.closeSearch(); closed() }
            if state.searchBusy {
                ProgressView().controlSize(.mini).accessibilityLabel("Searching…")
            } else if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .hairline), lineWidth: 1))
        .onAppear { focused = true }
        .onChange(of: state.searchFocus) { focused = true }
        .onChange(of: focused) { state.searchFieldFocused = focused }
    }
}

/// A section's title; All Projects has a + (Add Project…) at its trailing edge on hover, and
/// the Pinned title takes a dragged project as a pin at the bottom.
private struct SectionHeader: View {
    let title: Text
    var add = false
    var dropPins = false
    @ObservedObject private var state = SidebarState.shared
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 4) {
            title
            Spacer(minLength: 0)
            if add {
                Button { AddProject.show() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Add Project…")
                .accessibilityLabel("Add Project…")
            }
        }
        .padding(.vertical, 2)
        .background {
            if targeted, dropPins, state.draggingProject != nil {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pinDrop(onto: nil, if: dropPins, targeted: $targeted)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: Text("Add Project…")) { if add { AddProject.show() } }
    }
}

extension View {
    /// Takes a dragged project as a pin (onto a pinned row, or at the bottom with nil); only
    /// where pins go, so elsewhere a drag shows no drop.
    @ViewBuilder func pinDrop(onto target: String?, if enabled: Bool = true, targeted: Binding<Bool>) -> some View {
        if enabled {
            dropDestination(for: ProjectDrag.self) { drops, _ in
                guard let source = drops.first?.id else { return false }
                SidebarState.shared.draggingProject = nil
                ProjectActions.drop(source, onto: target)
                return true
            } isTargeted: { targeted.wrappedValue = $0 }
        } else {
            self
        }
    }
}

/// The empty Pinned section: a quiet hint that also takes a dragged project. No border at rest;
/// a light accent fill only while a project is dragged over it.
private struct PinDropZone: View {
    @ObservedObject var state: SidebarState
    @State private var targeted = false

    var body: some View {
        let lit = targeted && state.draggingProject != nil
        // Laid out as a row (icon + label, the rows' font), so it reads as the section's empty
        // content, not as another header.
        Label {
            Text("Pin a project from its ⋯ menu").lineLimit(1).truncationMode(.tail)
        } icon: {
            Image(systemName: "pin")
        }
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(lit ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("Pin a project from its ⋯ menu, or drag it here")
        .contentShape(Rectangle())
        .pinDrop(onto: nil, targeted: $targeted)
        .accessibilityElement(children: .combine)
    }
}

/// Reports whether the window's first responder is the sidebar's list, on every change (KVO on
/// NSWindow.firstResponder) and when the window becomes or stops being key.
private struct FirstResponderWatch: NSViewRepresentable {
    let changed: (Bool) -> Void
    /// A plain single click on a row (not its disclosure triangle, not a control in it, not a drag);
    /// `true` when it was the row already selected (the list may have just deselected it).
    var rowClicked: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> WatchView { WatchView(changed: changed) }
    func updateNSView(_ view: WatchView, context: Context) {
        view.changed = changed
        view.rowClicked = rowClicked
    }

    final class WatchView: NSView {
        var changed: (Bool) -> Void
        private var observation: NSKeyValueObservation?
        private var tokens: [NSObjectProtocol] = []
        private var monitor: Any?
        var rowClicked: (Bool) -> Void = { _ in }

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observation = nil
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.report(w) }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let w = self?.window { self?.report(w) } }
                })
            }
            // Any click in the list's area (rows, group rows, headers, empty space) gives the list
            // focus, as a click in Finder's or Mail's sidebar does: SwiftUI's row gestures and the
            // section headers swallow the click before the outline view would take it. A click in
            // a text field (the search field) keeps its own focus.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.mouse(event) }
                return event
            }
        }

        /// The row under a click: -1 outside rows, on a disclosure triangle, or on a control in the
        /// row (the ⋯ menu), which handle themselves.
        @MainActor private func row(at event: NSEvent, in outline: NSOutlineView, window w: NSWindow) -> Int {
            let hit = w.contentView?.hitTest(event.locationInWindow)
            let p = outline.convert(event.locationInWindow, from: nil)
            let r = outline.row(at: p)
            if let hit, hit is NSControl || hit is NSText { return -1 }
            guard r >= 0, !outline.frameOfOutlineCell(atRow: r).insetBy(dx: -4, dy: 0).contains(p) else { return -1 }
            return r
        }

        /// Any click in the list's area gives the list focus, as in Finder's or Mail's sidebar (a
        /// click in the search field keeps its own). A single click released on the row it went
        /// down on acts on that row: the whole row, the same way every time, decided here rather
        /// than by per-row gestures (which a drag start or a click beside the label missed).
        @MainActor private func mouse(_ event: NSEvent) {
            guard let w = window, event.window === w, bounds.contains(convert(event.locationInWindow, from: nil)),
                  let outline = Sidebar.find(NSOutlineView.self, in: w.contentView) else { return }
            guard event.type == .leftMouseDown else { return }
            if let hit = w.contentView?.hitTest(event.locationInWindow), hit is NSText || hit is NSTextField { return }
            let r = event.clickCount == 1 ? row(at: event, in: outline, window: w) : -1
            pending = (r, NSEvent.mouseLocation, r >= 0 && outline.selectedRowIndexes.contains(r))
            // The outline view tracks the press (its mouse-up never reaches this monitor); this runs
            // once that tracking has ended (default run-loop mode only): act on a press released in
            // place, not on a drag.
            perform(#selector(afterPress), with: nil, afterDelay: 0, inModes: [.default])
        }

        private var pending: (row: Int, at: NSPoint, wasSelected: Bool)?

        @objc private func afterPress() {
            guard let (r, down, wasSelected) = pending, let w = window, let outline = Sidebar.find(NSOutlineView.self, in: w.contentView) else { return }
            pending = nil
            if w.firstResponder !== outline { w.makeFirstResponder(outline) }
            let now = NSEvent.mouseLocation
            guard r >= 0, NSEvent.pressedMouseButtons & 1 == 0, abs(now.x - down.x) < 4, abs(now.y - down.y) < 4 else { return }
            rowClicked(wasSelected)
        }

        @MainActor private func report(_ window: NSWindow) {
            changed(Sidebar.hasFocus(window))
        }
    }
}

/// The ⋯ of a project row: secondary grey, white on a selected (accent-filled) row.
private struct MoreGlyph: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
    }
}

private struct SidebarFocusedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The sidebar's list has keyboard focus.
    var sidebarFocused: Bool {
        get { self[SidebarFocusedKey.self] }
        set { self[SidebarFocusedKey.self] = newValue }
    }
}

/// Unread on a row: a dot at its trailing edge, in the accent while the sidebar has focus in the
/// key window, grey otherwise. On a selected row (filled with the accent) it turns white.
private struct UnreadDot: View {
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.sidebarFocused) private var focused
    @Environment(\.controlActiveState) private var active

    var body: some View {
        let accent = focused && active == .key
        Circle().fill(prominence == .increased ? Color.white : accent ? Color.accentColor : Color.secondary)
            .frame(width: 7, height: 7)
    }
}

private struct ProjectRow: View {
    let project: LibraryProject
    /// The pinned section's rows, nil for a row in All Projects (not a drop target: it sorts itself).
    let pinnedRows: [LibraryProject]?
    let click: () -> Void
    @ObservedObject private var state = SidebarState.shared
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Label {
                HStack(spacing: 5) {
                    Text(verbatim: project.name).fontWeight(project.unread > 0 ? .bold : .medium).lineLimit(1)
                    if let parent = project.parent {
                        Text(verbatim: parent).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: "folder")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // ⋯ sits beside the unread dot (never in its place), in the row's quiet grey: the
            // accent tint a menu label gets by default read as a second badge.
            if hovering {
                Menu { ProjectMenu(id: project.id) } label: { MoreGlyph() }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More Actions")
                    .accessibilityLabel("More Actions")
                    .frame(width: 20, height: 18)
            }
            if project.unread > 0 { UnreadDot().frame(width: 12, height: 18) }
        }
        .help(project.unread > 0 ? Words.unread(project.unread) : "")
        .overlay(alignment: indicatorEdge) {
            if targeted, pinnedRows != nil, let source = state.draggingProject, source != project.id {
                Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: indicatorEdge == .top ? -4 : 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .draggable(drag()) // app-internal, Finder takes nothing
        .pinDrop(onto: project.id, if: pinnedRows != nil, targeted: $targeted) // All Projects sorts itself
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAction(.default, click)
        .accessibilityAction(named: pinnedRows != nil ? Text("Unpin") : Text("Pin")) { ProjectActions.togglePin(project.id) }
        .accessibilityAction(named: Text("Move Up")) { if pinnedRows != nil { ProjectActions.move(project.id, by: -1) } }
        .accessibilityAction(named: Text("Move Down")) { if pinnedRows != nil { ProjectActions.move(project.id, by: 1) } }
        .accessibilityAction(named: Text("Mark All as Read")) { ProjectActions.markAllRead(project.id) }
        .accessibilityAction(named: Text("Open All in Tabs")) { ProjectActions.openAll(project.id) }
        .accessibilityAction(named: Text("Show in Finder")) { ProjectActions.reveal(project.id) }
        .accessibilityAction(named: Text("Copy Path")) { ProjectActions.copyPath(project.id) }
        .accessibilityAction(named: Text("Hide from List")) { ProjectActions.hide(project.id) }
    }

    /// Where the dragged project will land: a pinned one from above goes below this row; one from
    /// below, or from All Projects, goes above it (Library.pin).
    private var indicatorEdge: Alignment {
        guard let rows = pinnedRows, let from = rows.firstIndex(where: { $0.id == state.draggingProject }),
              let to = rows.firstIndex(where: { $0.id == project.id }) else { return .top }
        return from < to ? .bottom : .top
    }

    private func drag() -> ProjectDrag {
        state.draggingDoc = nil
        state.draggingProject = project.id
        state.watchDragEnd()
        return ProjectDrag(id: project.id)
    }

    private var label: String {
        var parts = [project.parent.map { "\(project.name), \($0)" } ?? project.name, Words.documents(project.docCount)]
        if project.unread > 0 { parts.append(Words.unread(project.unread)) }
        if pinnedRows != nil { parts.append(String(localized: "Pinned")) }
        return parts.joined(separator: ", ")
    }
}

private struct KindRow: View {
    let project: LibraryProject
    let group: KindGroup
    let click: () -> Void
    @ObservedObject private var state = SidebarState.shared
    @State private var targeted = false

    var body: some View {
        let lit = targeted && takes(state.draggingDoc) != nil
        Label {
            HStack(spacing: 5) {
                Text(group.kind.name).fontWeight(group.unread > 0 ? .bold : .regular).lineLimit(1)
                Spacer(minLength: 4)
                if group.unread > 0 { UnreadDot().frame(width: 20) }
            }
        } icon: {
            Image(systemName: group.kind.symbol)
        }
        .padding(.vertical, 1)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
            }
        }
        .help(group.unread > 0 ? Words.unread(group.unread) : "")
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let doc = urls.lazy.compactMap(docFor).first else { return false }
            Sidebar.move(doc, to: group.kind)
            state.draggingDoc = nil
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAction(.default, click)
    }

    /// The dragged document, when it is in this project and of another kind.
    private func takes(_ id: String?) -> LibraryDoc? {
        guard let id else { return nil }
        return project.groups.lazy.flatMap(\.docs).first { $0.id == id && $0.kind != group.kind && !$0.deleted }
    }

    private func docFor(_ url: URL) -> LibraryDoc? {
        let path = url.standardizedFileURL.path
        return project.groups.lazy.flatMap(\.docs).first {
            $0.kind != group.kind && !$0.deleted && ($0.id == path || $0.variants.contains { $0.path == path })
        }
    }

    private var label: String {
        var parts = [String(localized: group.kind.name), Words.documents(group.docs.count)]
        if group.unread > 0 { parts.append(Words.unread(group.unread)) }
        return parts.joined(separator: ", ")
    }
}

private struct DocRow: View {
    let doc: LibraryDoc
    let url: URL
    /// How it matched the sidebar search, nil when not searching.
    let match: DocMatch?
    let query: String
    let click: () -> Void
    @ObservedObject private var state = SidebarState.shared

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            UnreadDot()
                .padding(.top, 5)
                .opacity(doc.unread && !doc.deleted ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(match?.title == true ? Words.marked(doc.title, query) : AttributedString(doc.title))
                        .lineLimit(1)
                        .foregroundStyle(doc.deleted ? .secondary : .primary)
                    if let n = changes, n > 0 { ChangeChip(n: n) }
                    if let lang = doc.langLabel {
                        Text(verbatim: lang)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 0.5))
                            .fixedSize()
                    }
                }
                Group {
                    if let snippet = match?.snippet { Text(Words.marked(snippet, query)) }
                    else if match?.name == true, match?.title == false { Text(Words.marked(fileName, query)) }
                    else if doc.deleted { Text("Deleted") + Text(verbatim: " · ") + Text(verbatim: secondLine) }
                    else { Text(verbatim: secondLine) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(match?.snippet != nil ? .tail : .middle)
            }
            Spacer(minLength: 0)
            if doc.deleted {
                Button { LibraryModel.shared.dismiss(doc) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from List")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .draggable(drag()) // the file itself, for Finder and other apps too
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAction(.default, click)
        .accessibilityAction(named: Text("Remove from List")) { if doc.deleted { LibraryModel.shared.dismiss(doc) } }
    }

    private var fileName: String { (doc.id as NSString).lastPathComponent }
    private var changes: Int? { doc.deleted ? nil : SidebarChanges.shared.count(url, modified: doc.modified) }

    private func drag() -> URL {
        state.draggingProject = nil
        state.draggingDoc = doc.id
        state.watchDragEnd()
        return url
    }

    private var secondLine: String { doc.folder.isEmpty ? Words.ago(doc.modified) : doc.folder + " · " + Words.ago(doc.modified) }

    private var label: String {
        var parts = [doc.title]
        if doc.deleted { parts.append(String(localized: "Deleted")) } else if doc.unread { parts.append(String(localized: "Unread")) }
        if let n = changes, n > 0 { parts.append(Words.changes(n)) }
        if let lang = doc.langLabel { parts.append(lang) }
        if let snippet = match?.snippet { parts.append(snippet) }
        else if match?.name == true, match?.title == false { parts.append(fileName) }
        if !doc.folder.isEmpty { parts.append(doc.folder) }
        parts.append(Words.ago(doc.modified))
        return parts.joined(separator: ", ")
    }
}

/// The sidebar rows' "N changes": an open document's from its page (Page.changes), any other's
/// counted here off the main thread from its baseline and the file, once per path and mtime.
@MainActor @Observable final class SidebarChanges {
    static let shared = SidebarChanges()
    private(set) var counts: [String: Int] = [:]
    /// What each count was made from: the file's mtime, or nil when its page set it.
    @ObservationIgnored private var made: [String: Date?] = [:]

    /// The count for a row (nil: none yet, or no baseline); starts counting if it is out of date.
    func count(_ url: URL, modified: Date) -> Int? {
        let path = url.standardizedFileURL.path
        if let m = made[path], m == nil || m == modified { return counts[path] }
        made[path] = modified
        Task.detached(priority: .utility) {
            guard let old = Baseline.read(url), let new = try? String(contentsOf: url, encoding: .utf8) else { return }
            let n = old == new ? 0 : await ChangeCount.count(old: old, new: new)
            await MainActor.run { if SidebarChanges.shared.made[path] == modified { SidebarChanges.shared.counts[path] = n } }
        }
        return counts[path]
    }

    /// A page's own count, which wins over a counted one while the page lives.
    func set(_ url: URL, _ n: Int) {
        let path = url.standardizedFileURL.path
        made[path] = .some(nil)
        if counts[path] != n { counts[path] = n }
    }

    /// Its page went (tab closed): count from the file again from now on.
    func forget(_ url: URL) { made[url.standardizedFileURL.path] = nil }
}

/// "N changes since last read" as a small count, on a tab and a sidebar row; the words are its tooltip.
struct ChangeChip: View {
    let n: Int

    var body: some View {
        Text(verbatim: "\(n)")
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 4.5)
            .frame(minWidth: 15, minHeight: 14)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .fixedSize()
            .help(Words.changes(n))
            .accessibilityLabel(Words.changes(n))
    }
}

/// A filter left nothing: no search match, or nothing unread.
private struct FilterEmpty: View {
    @ObservedObject var state: SidebarState

    var body: some View {
        VStack(spacing: 8) {
            if state.matches != nil {
                Text("No Matches").fontWeight(.medium)
                Text(verbatim: String(format: String(localized: "Nothing matches “%@”."), state.query.trimmingCharacters(in: .whitespaces)))
                    .foregroundStyle(.secondary)
            } else {
                Text("No Unread Documents").fontWeight(.medium)
                Button("Show All Documents") { state.setUnreadOnly(false) }
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The sidebar with nothing to list yet: still looking, agents found but no documents, or none found.
private struct SidebarEmpty: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        VStack(spacing: 10) {
            if !library.scannedOnce {
                ProgressView().controlSize(.small)
                Text("Looking for documents…").foregroundStyle(.secondary)
            } else {
                if let watching = Words.watching(library.agents) {
                    Text(verbatim: watching).fontWeight(.medium)
                    Text("Documents agents write in .md gather here").foregroundStyle(.secondary)
                } else {
                    Text("No agent history found on this Mac yet.").foregroundStyle(.secondary)
                }
                Button("Add Project…") { AddProject.show() }
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Content area with no tab

/// What the content area shows with no tab open: the welcome on the very first run while the
/// first scan runs (D10), otherwise a calm empty page. Files dropped on it open.
struct NoDocument: View {
    @ObservedObject var store: Store
    let text: Color
    let muted: Color
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        Group {
            if Welcome.launchEmpty { WelcomeView(library: library, text: text, muted: muted) }
            else {
                VStack(spacing: 6) {
                    Text("No Document Open").font(.system(size: 15, weight: .medium)).foregroundStyle(muted)
                    Group {
                        if store.sidebarOpen { Text("Choose one in the sidebar.") }
                        else { Text("Open a document, or show the sidebar.") + Text(verbatim: " (\(KeyboardShortcut.open.glyph), \(KeyboardShortcut.sidebar.glyph))") }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let md = urls.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            store.open(md)
            return !md.isEmpty
        }
    }
}

enum Welcome {
    /// Set at launch when no tab opened or was restored and no cached list exists (spec: the
    /// welcome shows on every such launch); the first tab shown ends it (Store.select).
    @MainActor static var launchEmpty = false
}

private struct WelcomeView: View {
    @ObservedObject var library: LibraryModel
    let text: Color
    let muted: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Midam")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(text)
                    .accessibilityAddTraits(.isHeader)
                Text("Midam gathers the Markdown documents your coding agents write, by project, in the sidebar. Everything stays on this Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Agents on this Mac")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(muted)
                    .accessibilityAddTraits(.isHeader)
                agent("Claude Code", found: library.agents.claudeProjects, Words.claudeProjects)
                agent("Codex", found: library.agents.codexSessions, Words.codexSessions)
            }
            if library.scanning {
                ProgressView(value: library.progress) {
                    Text("Looking for documents…").font(.system(size: 12)).foregroundStyle(muted)
                }
                .progressViewStyle(.linear)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
    }

    private func agent(_ name: String, found n: Int, _ words: (Int) -> String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: n > 0 ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(n > 0 ? text : muted)
                .accessibilityHidden(true)
            if n > 0 { Text(verbatim: words(n)).foregroundStyle(text) }
            else { Text(verbatim: name + " · ").foregroundStyle(muted) + Text("Not found").foregroundStyle(muted) }
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Layout

/// The sidebar with its edge: a hairline, and a strip that resizes it (width remembered).
struct SidebarColumn: View {
    @ObservedObject var store: Store
    @AppStorage(SidebarColumn.widthKey) private var width = SidebarColumn.defaultWidth
    @State private var start: Double?
    static let widthKey = "sidebarWidth", defaultWidth = 260.0
    static let widths = 200.0...400.0
    static func clamp(_ w: Double) -> Double { min(max(w, widths.lowerBound), widths.upperBound) }

    var body: some View {
        Sidebar(store: store)
            .frame(width: Self.clamp(width))
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).ignoresSafeArea()
            }
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: 8)
                    .offset(x: 4) // half over the page: ReaderView puts the column above it
                    .contentShape(Rectangle())
                    .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let from = start ?? width
                            start = from
                            width = Self.clamp(from + v.translation.width)
                        }
                        .onEnded { _ in start = nil })
                    .accessibilityHidden(true)
            }
    }
}
