import Foundation

/// Where agents run, as the UI sees it: sessions, their items and read state, and the project's
/// documents. The UI talks to this only (never to a process or a file path), so a remote host
/// (midam-host on a server, reached through the account server) can replace the local one.
/// Every value crossing it is Codable. Projects are opaque ids (locally, the folder's path).
@MainActor
protocol AgentHost: AnyObject {
    /// A new session in `project`, or `resume` an earlier one (its history is in `items` on return).
    /// Nothing runs until the first send. Returns the session id.
    func open(project: String, resume: String?) async throws -> String
    func close(_ session: String) async throws
    func send(_ session: String, text: String) async throws
    func interrupt(_ session: String) async throws
    func answer(_ session: String, permission id: String, allow: Bool) async throws
    /// `choices`: each question's text → the chosen labels (or the person's own words).
    func answer(_ session: String, question id: String, choices: [String: [String]]) async throws
    func info(_ session: String) async throws -> SessionInfo
    func items(_ session: String) async throws -> [ChatItem]
    /// The history page before the session's first item, to put in front of it (no events for
    /// it); empty at the start. `SessionInfo.earlier` says whether there is more.
    func earlier(_ session: String) async throws -> [ChatItem]
    /// Changes to every open session, from now on.
    func events() -> AsyncStream<HostEvent>
    func documents(project: String) async throws -> [DocumentRef]
    func read(_ document: DocumentRef) async throws -> String

    // The registry and the rest of what the sidebar needs.
    /// The conversations Midam started or resumed in `project`, in the order they were added.
    func conversations(project: String) -> [AgentConversation]
    /// The session's subagents as a tree; read incrementally on each call.
    func team(session: String) async throws -> TeamNode
    /// Past agent sessions to resume, newest first.
    func recentSessions(limit: Int) async -> [RecentSession]
    /// Makes a new project folder, registers it, returns its id.
    func createProject(name: String) async throws -> String
    /// The documents `session` wrote, newest first.
    func docs(ofSession session: String) -> [DocInfo]
    /// Whether the `claude` CLI is installed (Claude is the only agent offered).
    func claudeInstalled() async -> Bool
}

struct SessionInfo: Codable, Equatable, Sendable {
    var id: String
    var project: String
    var state: Conversation.State
    var model: String?
    var contextPercent: Int?
    var subagents: Int
    var topic: String?
    /// History before the first item is still to load (`AgentHost.earlier`).
    var earlier = false
}

enum HostEvent: Codable, Equatable, Sendable {
    /// A new or changed item (same id = replace it).
    case item(session: String, ChatItem)
    case info(SessionInfo)
}

/// A document in a project: `path` is relative to the project, `modified` its last change.
struct DocumentRef: Codable, Hashable, Sendable {
    var project: String
    var path: String
    var modified: Date
}

enum HostError: Error, Equatable {
    case noSession, noProject, notADocument
}

/// Agents on this Mac: one Conversation (a local `claude` process) per session.
@MainActor
final class LocalAgentHost: AgentHost {
    private var sessions: [String: (conversation: Conversation, project: String)] = [:]
    private var sent: [String: (items: [ChatItem], info: SessionInfo)] = [:]
    private var listeners: [UUID: AsyncStream<HostEvent>.Continuation] = [:]
    nonisolated static let documentTypes: Set<String> = ["md", "markdown", "mdown", "mkd"]
    /// The model new sessions use; nil = the person's default (the smoke test uses haiku).
    var model: String?
    /// Where conversations are recorded and documents found; nil in tests (nothing is written to the person's defaults).
    private let library: LibraryModel?
    private var teams: [String: TeamReader] = [:]

    init(library: LibraryModel? = nil) { self.library = library }

    func open(project: String, resume: String?) async throws -> String {
        var dir: ObjCBool = false
        guard project.hasPrefix("/"), FileManager.default.fileExists(atPath: project, isDirectory: &dir), dir.boolValue else { throw HostError.noProject }
        if let resume {
            guard let id = Conversation.sessionID(resume) else { throw HostError.noSession }
            if sessions[id] != nil { return id } // already open
        }
        let c = Conversation(project: URL(fileURLWithPath: project), resumeID: resume)
        c.modelOverride = model
        _ = await c.loadEarlier() // the newest page, one batch: the caller takes it from items(), not as an event per item
        let id = c.sessionID
        if sessions[id] != nil { return id } // opened meanwhile
        sessions[id] = (c, project)
        sent[id] = (c.items, try info(of: id))
        c.changed = { [weak self] in self?.emit(id) }
        if let library, !library.conversations(in: project).contains(where: { $0.sessionID == id }) {
            library.addConversation(AgentConversation(sessionID: id, root: project))
        }
        return id
    }

    func close(_ session: String) async throws {
        try conversation(session).stop()
        sessions[session] = nil
        sent[session] = nil
        teams[session] = nil
    }

    func send(_ session: String, text: String) async throws { try conversation(session).send(text) }
    func interrupt(_ session: String) async throws { try conversation(session).interrupt() }
    func answer(_ session: String, permission id: String, allow: Bool) async throws {
        try conversation(session).answer(permission: id, allow: allow)
    }
    func answer(_ session: String, question id: String, choices: [String: [String]]) async throws {
        try conversation(session).answer(question: id, choices: choices)
    }
    func info(_ session: String) async throws -> SessionInfo { try info(of: session) }
    func items(_ session: String) async throws -> [ChatItem] { try conversation(session).items }
    func earlier(_ session: String) async throws -> [ChatItem] {
        let c = try conversation(session)
        let page = await c.loadEarlier()
        // Already in place: later changes are measured from here, so the page is not sent again as events.
        if sessions[session] != nil, let now = try? info(of: session) { sent[session] = (c.items, now) }
        return page
    }

    func events() -> AsyncStream<HostEvent> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<HostEvent>.makeStream()
        listeners[key] = continuation
        continuation.onTermination = { _ in Task { @MainActor [weak self] in self?.listeners[key] = nil } }
        return stream
    }

    func documents(project: String) async throws -> [DocumentRef] {
        let root = URL(fileURLWithPath: Permission.real(project))
        return try await Task.detached { try Self.scan(root, project: project) }.value
    }

    func read(_ document: DocumentRef) async throws -> String {
        let root = Permission.real(document.project)
        let path = try Self.inside(document.path, root: root)
        return try await Task.detached { try String(contentsOfFile: path, encoding: .utf8) }.value
    }

    func conversations(project: String) -> [AgentConversation] { library?.conversations(in: project) ?? [] }
    func recentSessions(limit: Int = 300) async -> [RecentSession] {
        await Task.detached(priority: .userInitiated) { RecentSessions.load(limit: limit) }.value
    }
    func createProject(name: String) async throws -> String {
        if let library { return try library.createProject(name: name).path }
        return try Projects.create(name: name).path
    }
    func docs(ofSession session: String) -> [DocInfo] { library?.docs(ofSession: session) ?? [] }
    func claudeInstalled() async -> Bool { await Agent.installed().contains(.claude) }

    // ponytail: no wanjang run log yet (runLog nil), so roles come from the subagent types only.
    func team(session: String) async throws -> TeamNode {
        guard let (_, project) = sessions[session],
              let file = Conversation.transcript(project: URL(fileURLWithPath: project), id: session) else { throw HostError.noSession }
        let reader = teams[session] ?? TeamReader(transcript: file, words: .localized)
        teams[session] = reader
        return reader.refresh() // incremental: only appended lines are parsed
    }

    // MARK: -

    private func conversation(_ session: String) throws -> Conversation {
        guard let c = sessions[session]?.conversation else { throw HostError.noSession }
        return c
    }

    private func info(of session: String) throws -> SessionInfo {
        guard let (c, project) = sessions[session] else { throw HostError.noSession }
        return SessionInfo(id: session, project: project, state: c.state, model: c.model,
                           contextPercent: c.contextPercent, subagents: c.subagents, topic: c.topic, earlier: c.hasEarlier)
    }

    /// Sends what changed since the last events for `session`.
    private func emit(_ session: String) {
        guard let c = sessions[session]?.conversation, let now = try? info(of: session) else { return }
        let before = sent[session]
        var events = Self.changes(old: before?.items ?? [], new: c.items).map { HostEvent.item(session: session, $0) }
        if before?.info != now { events.append(.info(now)) }
        sent[session] = (c.items, now)
        if let library, let topic = now.topic, topic != before?.info.topic,
           let id = library.conversations(in: now.project).first(where: { $0.sessionID == session })?.id {
            library.updateConversation(id) { $0.topic = topic }
        }
        for e in events { for l in listeners.values { l.yield(e) } }
    }

    /// Items that are new or differ from the item with the same id before.
    nonisolated static func changes(old: [ChatItem], new: [ChatItem]) -> [ChatItem] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return new.filter { before[$0.id] != $0 }
    }

    /// The real path of a document `path` (relative to the project) if it stays inside the project
    /// (no `..`, absolute path or symlink out of it) and is a Markdown document.
    nonisolated static func inside(_ path: String, root: String) throws -> String {
        guard !path.hasPrefix("/"), !path.isEmpty else { throw HostError.notADocument }
        let real = Permission.resolve(path, in: root)
        guard real != root, Permission.inside(real, root),
              documentTypes.contains((real as NSString).pathExtension.lowercased()) else { throw HostError.notADocument }
        return real
    }

    // ponytail: walks the whole project on each call, skipping hidden and build folders; an index
    // (the Library scanner's) when projects get large.
    nonisolated static func scan(_ root: URL, project: String) throws -> [DocumentRef] {
        let skip: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "vendor"]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw HostError.noProject }
        var docs: [DocumentRef] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if v?.isDirectory == true { if skip.contains(url.lastPathComponent) { e.skipDescendants() }; continue }
            guard documentTypes.contains(url.pathExtension.lowercased()), url.path.hasPrefix(prefix) else { continue }
            docs.append(DocumentRef(project: project, path: String(url.path.dropFirst(prefix.count)), modified: v?.contentModificationDate ?? .distantPast))
        }
        return docs.sorted { $0.modified > $1.modified }
    }
}
