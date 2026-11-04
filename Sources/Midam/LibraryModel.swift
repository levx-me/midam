import AppKit

/// The sidebar's data: scans agent transcripts in the background, keeps what the user did in
/// UserDefaults (`library.*`) and the last scan in LibraryCache, and mirrors the unread count
/// to the Dock badge.
@MainActor final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    @Published private(set) var projects: [LibraryProject] = [] { didSet { updateBadge(); indexPaths() } }
    @Published private(set) var scanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var scannedOnce = false
    @Published private(set) var agents = FoundAgents(claudeProjects: 0, codexSessions: 0)
    /// Pinned project ids in the user's order.
    @Published private(set) var pinned: [String] = []
    /// The registry: the projects the user registered; the only ones scanned and listed.
    @Published private(set) var registered: Set<String> = []
    /// Midam-run conversations, several per project (the conversation engine fills them in).
    @Published private(set) var conversations: [AgentConversation] = []

    var totalUnread: Int { projects.reduce(0) { $0 + $1.unread } }

    private var state: LibraryState
    private var infos: [DocInfo] = []
    private var rescanAgain = false
    private var modelRunning = false
    private var baselining: Bool // first run: no scan has completed yet
    private var lastScan = Date.distantPast // when the last scan finished
    private var marks: ScanMarks? // the last scan's read state; nil until the cache is read at launch
    /// Projects just added from older history: their documents start read, as on a first run.
    /// Persisted (Key.baseline), so quitting before that scan ends does not flood unread.
    private var baselineProjects: Set<String> = []
    /// Each listed document's id by the resolved path of its file and of each language version (the
    /// first listed wins), for the sidebar's current row; resolved once per path (`resolved`).
    private(set) var docAtPath: [String: String] = [:]
    private var resolved: [String: String] = [:]
    /// The session that wrote each scanned document, by the resolved path of every language version.
    private var sessionAt: [String: WritingSession] = [:]

    private init() {
        // Until a first scan has completed (an install from before the flag has `known` instead):
        // an open during that scan saves `opened`, which must not end the baseline.
        let d = UserDefaults.standard
        baselining = !d.bool(forKey: Key.scannedOnce) && d.object(forKey: Key.known) == nil
        state = LibraryState(opened: Self.load(Key.opened, [:]), pinned: Self.load(Key.pinned, []),
                             added: Self.load(Key.added, []),
                             overrides: Self.load(Key.overrides, [:]), dismissed: Self.load(Key.dismissed, []),
                             known: Self.load(Key.known, [:]), modelKinds: Self.load(Key.modelKinds, [:]))
        baselineProjects = Self.load(Key.baseline, [])
        if !d.bool(forKey: Key.registry) { // once: the registry replaces auto collection and hiding
            state.added = Registry.migrate(added: state.added, pinned: state.pinned, hidden: Self.load(Key.hidden, Set<String>()))
            state.pinned = state.pinned.filter(state.added.contains)
            for old in [Key.hidden, "library.hiddenPins"] { d.removeObject(forKey: old) }
            Self.save(state.added, Key.added)
            Self.save(state.pinned, Key.pinned)
            d.set(true, forKey: Key.registry)
        }
        pinned = state.pinned
        registered = state.added
        conversations = Self.load(Key.conversations, [])
        for old in ["library.order", "library.folders"] { UserDefaults.standard.removeObject(forKey: old) } // replaced by pins and the registry
    }

    // MARK: Scanning

    /// A return to the app: a scan, unless one is running or the last finished under a minute ago.
    func refresh() {
        guard !scanning, Date().timeIntervalSince(lastScan) >= 60 else { return }
        rescan()
    }

    /// Starts a scan, or queues one more if a scan is running (calls in between collapse into it).
    /// The first one shows the cached list from the last run before scanning; a scan reads only
    /// what changed in the sources since the last (LibraryScanner.previous).
    func rescan() {
        if scanning { rescanAgain = true; return }
        scanning = true
        progress = 0
        let env = ScanEnv.standard(), known = state.known, added = state.added, last = marks
        Task.detached(priority: .utility) {
            var previous = last
            if previous == nil, let cache = LibraryCache.read() {
                previous = cache.marks
                await LibraryModel.shared.restore(cache)
            }
            let first = previous == nil // fills as it goes only without a cache to show
            let scan = LibraryScanner(env: env)
            scan.previous = previous ?? ScanMarks()
            let claude = scan.claudeTranscripts(registered: added), codex = scan.codexSessions(registered: added)
            let found = FoundAgents(claudeProjects: scan.claudeProjectCount(), codexSessions: codex.count)
            let total = claude.count + codex.count
            var hits: [Hit] = []
            var done = 0
            var published = Date.distantPast
            // Newest sources first: the first hit of a path decides its project. Another agent's
            // history joins this list (see Agent).
            let sources = claude.map { p in { scan.claudeHits(p) } } + codex.map { p in { scan.codexHits(p) } }
            for source in sources {
                hits += source()
                done += 1
                // ponytail: partial results at most 4 times a second; every source would rebuild ~900 times.
                // Only a first scan with no cache fills the list as it goes; later ones show their progress only.
                if Date().timeIntervalSince(published) > 0.25 && done < total {
                    published = Date()
                    let p = Double(done) / Double(total)
                    if first { await LibraryModel.shared.show(scan.docs(hits, known: known), progress: p, agents: found) }
                    else { await LibraryModel.shared.setProgress(p) }
                }
            }
            let cache = LibraryCache(infos: scan.docs(hits, known: known), agents: found, marks: scan.marks)
            cache.write()
            await LibraryModel.shared.finish(cache, added: added)
        }
    }

    /// Launch: the last run's list at once, until the rescan swaps in what is on disk now.
    private func restore(_ cache: LibraryCache) {
        show(cache.infos, progress: progress, agents: cache.agents)
        scannedOnce = true
    }

    private func show(_ infos: [DocInfo], progress: Double, agents: FoundAgents) {
        self.infos = infos
        var sessions: [String: WritingSession] = [:]
        for i in infos { if let s = i.session { for p in i.variants.map(\.path) + [i.id] { sessions[p] = s } } }
        sessionAt = sessions
        if baselining { state.opened.merge(Library.baseline(infos)) { mine, _ in mine } }
        else if !baselineProjects.isEmpty {
            state.opened.merge(Library.baseline(infos.filter { baselineProjects.contains($0.project) })) { mine, _ in mine }
        }
        self.progress = progress
        if self.agents != agents { self.agents = agents }
        recompute()
    }

    private func setProgress(_ p: Double) { progress = p }

    /// `added`: the added projects this scan collected (their baseline is done).
    private func finish(_ cache: LibraryCache, added: Set<String>) {
        let infos = cache.infos
        marks = cache.marks
        show(infos, progress: 1, agents: cache.agents)
        lastScan = Date()
        let deleted = Set(infos.filter(\.deleted).map(\.id))
        state.dismissed = state.dismissed.intersection(deleted)
        state.known = Library.known(infos, state: state)
        persist()
        scanning = false
        scannedOnce = true
        baselining = false
        UserDefaults.standard.set(true, forKey: Key.scannedOnce)
        baselineProjects.subtract(added)
        Self.save(baselineProjects, Key.baseline)
        if rescanAgain { rescanAgain = false; rescan(); return }
        classifyWithModel()
    }

    /// D3: docs no fixed rule decided are shown with the rules' kind first, then asked of the
    /// on-device model one at a time; each answer is cached per path+mtime and moves its row.
    private func classifyWithModel() {
        guard !modelRunning, KindModel.available else { return }
        let pending = Library.pendingModel(infos, state: state)
        guard !pending.isEmpty else { return }
        modelRunning = true
        Task {
            for doc in pending {
                guard let key = doc.modelKey else { continue }
                let kind = await KindModel.classify(title: doc.title, excerpt: doc.excerpt)
                state.modelKinds[key] = kind?.rawValue ?? ""
                recompute()
            }
            let live = Set(infos.compactMap(\.modelKey))
            state.modelKinds = state.modelKinds.filter { live.contains($0.key) }
            persist()
            modelRunning = false
        }
    }

    /// Every registered project is listed, one with no documents yet (only agents) after the rest.
    /// One whose folder is gone (deleted, drive away) is left out, and returns with its folder.
    private func recompute() {
        let present = state.added.filter { FileManager.default.fileExists(atPath: $0) }
        var next = Library.projects(infos.filter { present.contains($0.project) }, state: state)
        let listed = Set(next.map(\.id))
        next += present.subtracting(listed).sorted().map {
            LibraryProject(id: $0, name: ($0 as NSString).lastPathComponent, parent: nil, groups: [], docCount: 0, unread: 0, lastModified: .distantPast)
        }
        if next != projects { projects = next }
    }

    /// Sessions waiting for the person (a permission or a question), by session id → project
    /// root; Store keeps it, the sidebar rings and the Dock badge read it.
    @Published private(set) var blocked: [String: String] = [:] { didSet { if blocked != oldValue { updateBadge() } } }

    func setBlocked(_ session: String, root: String, _ on: Bool) { blocked[session] = on ? root : nil }

    /// The Dock badge: agents waiting for the person if any, else unread documents.
    private func updateBadge() {
        let n = blocked.isEmpty ? totalUnread : blocked.count
        NSApp?.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    private func indexPaths() {
        var map: [String: String] = [:]
        for p in projects {
            for g in p.groups {
                for d in g.docs {
                    for path in d.variants.map(\.path) + [d.id] { map[real(path)] = map[real(path)] ?? d.id }
                }
            }
        }
        docAtPath = map
    }

    private func real(_ path: String) -> String {
        if let r = resolved[path] { return r }
        let r = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        resolved[path] = r
        return r
    }

    // MARK: User actions

    /// A tab showed this file now: it and its other language versions count as read.
    func opened(_ url: URL) {
        state.opened[url.resolvingSymlinksInPath().path] = Date()
        Self.save(state.opened, Key.opened) // only what changed
        recompute()
    }

    /// The newest agent session that wrote this file (or another language version of it), for
    /// "Resume the session that wrote this"; nil when no scanned history wrote it.
    func session(for path: String) -> WritingSession? { sessionAt[real(path)] }

    /// The language version opened most recently, else the base (or the only one).
    func url(for doc: LibraryDoc) -> URL {
        let last = doc.variants.max { (state.opened[$0.path] ?? .distantPast) < (state.opened[$1.path] ?? .distantPast) }
        let pick = last.flatMap { state.opened[$0.path] != nil ? $0 : nil } ?? doc.variants.first
        return URL(fileURLWithPath: pick?.path ?? doc.id)
    }

    func setKind(_ kind: DocKind, for doc: LibraryDoc) {
        state.overrides[doc.id] = kind
        persist()
        recompute()
    }

    // MARK: Projects

    /// Pins `id` where it was dropped (see Library.pin), or at the bottom.
    func pin(_ id: String, onto target: String? = nil) { setPinned(Library.pin(id, onto: target, in: state.pinned)) }

    func unpin(_ id: String) { setPinned(state.pinned.filter { $0 != id }) }

    func movePinned(_ id: String, by d: Int) {
        setPinned(Library.movePinned(id, by: d, in: state.pinned, listed: Set(projects.map(\.id))))
    }

    private func setPinned(_ ids: [String]) {
        guard ids != state.pinned else { return }
        state.pinned = ids
        pinned = ids
        Self.save(ids, Key.pinned)
    }

    /// Every document of the project counts as read now.
    func markAllRead(_ project: LibraryProject) {
        for d in project.groups.flatMap(\.docs) where d.unread {
            for v in d.variants { state.opened[v.path] = max(Date(), d.modified) }
        }
        Self.save(state.opened, Key.opened)
        recompute()
    }

    /// Registers a project: it is scanned from all its history and listed, its documents starting read.
    func register(root: String) {
        guard !state.added.contains(root) else { return }
        state.added.insert(root)
        registered = state.added
        baselineProjects.insert(root)
        persist()
        recompute()
        rescan()
    }

    /// Takes the project off the list (nothing on disk is touched); its pin and conversations go too.
    func unregister(root: String) {
        guard state.added.remove(root) != nil else { return }
        registered = state.added
        baselineProjects.remove(root)
        unpin(root)
        conversations.removeAll { $0.root == root }
        persist()
        recompute()
    }

    /// Whether `path` is in a registered project; a plain .md outside them lives only as a tab.
    func isInRegisteredProject(_ path: String) -> Bool { Registry.contains(path, in: state.added) }

    // MARK: Conversations

    func conversations(in root: String) -> [AgentConversation] { conversations.filter { $0.root == root } }

    /// Registers the conversation's project too.
    func addConversation(_ c: AgentConversation) {
        register(root: c.root)
        conversations.append(c)
        Self.save(conversations, Key.conversations)
    }

    func updateConversation(_ id: String, _ change: (inout AgentConversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[i])
        Self.save(conversations, Key.conversations)
    }

    func removeConversation(_ id: String) {
        conversations.removeAll { $0.id == id }
        Self.save(conversations, Key.conversations)
    }

    /// The documents a session wrote, newest first.
    func docs(ofSession id: String) -> [DocInfo] { Library.docs(ofSession: id, in: infos) }

    /// The newest `limit` agent sessions to resume, read off the main thread.
    nonisolated func recentSessions(limit: Int = 300) async -> [RecentSession] {
        await Task.detached(priority: .userInitiated) { RecentSessions.load(limit: limit) }.value
    }

    /// New project: made, registered; the error is for the sheet to show.
    func createProject(name: String) throws -> URL {
        let url = try Projects.create(name: name)
        register(root: url.path)
        return url
    }

    func dismiss(_ doc: LibraryDoc) {
        state.dismissed.insert(doc.id)
        persist()
        recompute()
    }

    // MARK: Persistence

    private enum Key {
        static let opened = "library.opened", pinned = "library.pinned", hidden = "library.hidden", // hidden: read once by the migration
                   registry = "library.registry", conversations = "library.conversations",
                   added = "library.added", overrides = "library.kinds", dismissed = "library.dismissed",
                   known = "library.known", modelKinds = "library.modelKinds", scannedOnce = "library.scannedOnce",
                   baseline = "library.baselineProjects"
    }

    private func persist() {
        Self.save(state.opened, Key.opened)
        Self.save(state.pinned, Key.pinned)
        Self.save(state.added, Key.added)
        Self.save(state.overrides, Key.overrides)
        Self.save(state.dismissed, Key.dismissed)
        Self.save(state.known, Key.known)
        Self.save(state.modelKinds, Key.modelKinds)
        Self.save(baselineProjects, Key.baseline)
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback
    }
}
