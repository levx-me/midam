import Combine
import Foundation

/// Claude sessions run outside Midam (a terminal's `claude`), listed under the project they ran
/// in (tools/ExternalSessionsTest).
enum ExternalSessions {
    /// How far back the sidebar lists them.
    static let days = 7
    /// A transcript written this recently (seconds) is being run elsewhere.
    static let runningWithin: TimeInterval = 120

    /// `cwd` is `root` or inside it (a path-component prefix: /a/b does not hold /a/bc).
    static func inProject(_ cwd: String, root: String) -> Bool {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        return cwd == root || cwd.hasPrefix(root == "/" ? root : root + "/")
    }

    /// The deepest of `roots` holding `cwd`: a session in a nested project belongs to the inner one.
    static func owner(of cwd: String, roots: [String]) -> String? {
        roots.filter { inProject(cwd, root: $0) }.max { $0.count < $1.count }
    }

    /// `root`'s sessions to list: owned by `root` among `roots`, active within `days`, not managed
    /// by Midam (`managed` session ids), newest first. Not capped.
    static func visible(root: String, roots: [String], all: [RecentSession], managed: Set<String>, now: Date) -> [RecentSession] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return all.filter {
            $0.lastActive >= since && !managed.contains($0.sessionID) && owner(of: $0.projectRoot, roots: roots + [root]) == root
        }.sorted { $0.lastActive > $1.lastActive }
    }

    /// Written to within `runningWithin` of `now`: probably still open in a terminal.
    static func running(lastActive: Date, now: Date) -> Bool { now.timeIntervalSince(lastActive) <= runningWithin }

    struct Cached: Sendable { let mtime: Date; let cwd: String?; let topic: String }

    /// The sessions written since `since`, newest first. A file whose mtime matches `cache` is not
    /// read again; `cache` comes back holding only the files seen now.
    static func scan(home: String, since: Date, cache: inout [String: Cached],
                     read: (String) -> (String?, String)? = RecentSessions.read) -> [RecentSession] {
        var seen: [String: Cached] = [:], out: [RecentSession] = []
        for f in RecentSessions.files(home: home) where f.mtime >= since {
            if let c = cache[f.path], c.mtime == f.mtime { seen[f.path] = c }
            else if let (cwd, topic) = read(f.path) { seen[f.path] = Cached(mtime: f.mtime, cwd: cwd, topic: topic) }
            if let c = seen[f.path], let cwd = c.cwd {
                out.append(RecentSession(agent: .claude, sessionID: f.id, projectRoot: cwd, topic: c.topic, lastActive: f.mtime))
            }
        }
        cache = seen
        return out.sorted { $0.lastActive > $1.lastActive }
    }
}

/// The external sessions of the last week, scanned off the main thread on `refresh()` (at launch,
/// when the app becomes active, when the sidebar asks); never on a timer.
@MainActor final class ExternalSessionsModel: ObservableObject {
    static let shared = ExternalSessionsModel()

    @Published private(set) var sessions: [RecentSession] = []
    private var cache: [String: ExternalSessions.Cached] = [:]
    private var scanning = false, again = false

    func refresh(home: String = NSHomeDirectory()) {
        guard !scanning else { again = true; return }
        scanning = true
        let (cache, since) = (self.cache, Date().addingTimeInterval(-Double(ExternalSessions.days) * 86_400))
        Task.detached(priority: .utility) { [weak self] in
            var cache = cache
            let found = ExternalSessions.scan(home: home, since: since, cache: &cache)
            await self?.finish(found, cache, home: home)
        }
    }

    private func finish(_ found: [RecentSession], _ cache: [String: ExternalSessions.Cached], home: String) {
        if found != sessions { sessions = found } // an unchanged scan does not redraw the sidebar
        (self.cache, scanning) = (cache, false)
        if again { again = false; refresh(home: home) }
    }

    /// What the sidebar lists under `root`: `roots` are every registered project, `managed` the
    /// session ids Midam runs (LibraryModel.managedSessionIDs).
    func rows(for root: String, roots: [String], managed: Set<String>, now: Date = Date()) -> [RecentSession] {
        ExternalSessions.visible(root: root, roots: roots, all: sessions, managed: managed, now: now)
    }
}

/// Calls `onChange` (main queue, debounced) when the file at `path` is written to.
final class FileWatch {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(path: String, onChange: @escaping @MainActor () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let item = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func cancel() { pending?.cancel(); source?.cancel(); source = nil }
    deinit { source?.cancel() }
}
