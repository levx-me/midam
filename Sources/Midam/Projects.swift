import Foundation

// The orchestrator's data: which projects are registered, the conversations Midam runs in them,
// the recent agent sessions to resume, and new projects. Foundation only (tools/LibraryTest).

enum Registry {
    /// Once (flag `library.registry`): what the user had pinned or added stays; hidden ones go.
    /// Projects that were only auto-collected drop out; nothing on disk is touched.
    static func migrate(added: Set<String>, pinned: [String], hidden: Set<String>) -> Set<String> {
        added.union(pinned).subtracting(hidden)
    }

    /// `path` is a project's root or inside it. Paths are compared with symlinks resolved.
    static func contains(_ path: String, in roots: Set<String>) -> Bool {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return roots.contains { r in
            let root = URL(fileURLWithPath: r).resolvingSymlinksInPath().path
            return p == root || p.hasPrefix(root + "/")
        }
    }
}

/// A conversation Midam runs for a project (several per project). The conversation engine fills
/// `sessionID` once the agent reports it, and `topic` when it is known.
struct AgentConversation: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var sessionID: String?
    let root: String
    var topic: String?
    let created: Date

    init(id: String = UUID().uuidString, sessionID: String? = nil, root: String, topic: String? = nil, created: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.root = root; self.topic = topic; self.created = created
    }
}

/// A past agent session to resume, for the Add-agent sheet.
struct RecentSession: Codable, Hashable, Identifiable, Sendable {
    var id: String { agent.rawValue + ":" + sessionID }
    let agent: Agent
    let sessionID: String
    let projectRoot: String
    var projectName: String { (projectRoot as NSString).lastPathComponent }
    let topic: String
    let lastActive: Date

    /// Every word of the query is in the topic or the project name, ignoring case and accents
    /// (like the sidebar search). An empty query matches everything.
    func matches(_ query: String) -> Bool {
        Library.terms(query).allSatisfy { t in !Library.hits(t, in: topic).isEmpty || !Library.hits(t, in: projectName).isEmpty }
    }
}

/// The New Agent picker's rules (tools/AgentPickerTest).
enum AgentPickerRules {
    /// `path` with the home folder written as ~.
    static func friendly(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The folder `path` lives in, friendly.
    static func parent(_ path: String, home: String = NSHomeDirectory()) -> String {
        friendly((path as NSString).deletingLastPathComponent, home: home)
    }

    /// The selection once the shown rows change: kept while shown, else the first row (nil when none).
    static func keep(_ selected: String?, in shown: [String]) -> String? {
        if let selected, shown.contains(selected) { return selected }
        return shown.first
    }

    /// The sessions in `root`, newest first.
    static func sessions(in root: String, _ all: [RecentSession]) -> [RecentSession] {
        all.filter { $0.projectRoot == root }.sorted { $0.lastActive > $1.lastActive }
    }

    /// Whether counting `root`'s documents by walking it is reasonable (never the home folder or /).
    static func countable(_ root: String, home: String = NSHomeDirectory()) -> Bool {
        friendly(root, home: home) != "~" && root != "/"
    }
}

enum RecentSessions {
    /// The newest `limit` Claude sessions in `~/.claude/projects/*/*.jsonl`, newest first.
    // ponytail: reads only the first and last 256 KB of each transcript; a title or cwd outside
    // them is missed (the session then falls back to its first prompt, or is skipped without a cwd).
    static func load(home: String = NSHomeDirectory(), limit: Int = 300) -> [RecentSession] {
        var out: [RecentSession] = []
        for f in files(home: home).sorted(by: { $0.mtime > $1.mtime }) {
            guard out.count < limit else { break }
            guard let (cwd, topic) = read(f.path), let cwd else { continue }
            out.append(RecentSession(agent: .claude, sessionID: f.id, projectRoot: cwd, topic: topic, lastActive: f.mtime))
        }
        return out
    }

    /// Every `~/.claude/projects/*/<id>.jsonl` with a plain session id, and its mtime.
    static func files(home: String) -> [(path: String, id: String, mtime: Date)] {
        let fm = FileManager.default, base = home + "/.claude/projects"
        var files: [(path: String, id: String, mtime: Date)] = []
        for slug in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !slug.hasPrefix(".") {
            for f in (try? fm.contentsOfDirectory(atPath: base + "/" + slug)) ?? [] where f.hasSuffix(".jsonl") {
                let p = base + "/" + slug + "/" + f, id = String(f.dropLast(6))
                if WritingSession.isValidID(id), let m = LibraryScanner.mtime(p) { files.append((p, id, m)) }
            }
        }
        return files
    }

    /// The session's cwd and topic, from the head and tail of the file.
    static func read(_ path: String) -> (String?, String)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let chunk = 262_144
        let size = Int((try? h.seekToEnd()) ?? 0)
        try? h.seek(toOffset: 0)
        var text = String(decoding: (try? h.read(upToCount: chunk)) ?? Data(), as: UTF8.self)
        if size > 2 * chunk {
            try? h.seek(toOffset: UInt64(size - chunk))
            text += "\n" + String(decoding: (try? h.read(upToCount: chunk)) ?? Data(), as: UTF8.self)
        }
        return parse(text)
    }

    /// The cwd, and the topic: the last `ai-title`, else the first real user prompt. Lines cut at a
    /// chunk edge fail to parse and are skipped.
    static func parse(_ text: String) -> (String?, String) {
        var cwd: String?, title: String?, prompt: String?
        for line in text.split(separator: "\n") {
            let wantsTitle = line.contains("\"ai-title\""), wantsUser = prompt == nil && line.contains("\"user\"")
            guard wantsTitle || wantsUser || cwd == nil,
                  let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if cwd == nil, let c = o["cwd"] as? String { cwd = c }
            if o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String, !t.isEmpty { title = t }
            else if prompt == nil, o["type"] as? String == "user", o["isMeta"] as? Bool != true, let m = o["message"] as? [String: Any] {
                let raw: String? = (m["content"] as? String)
                    ?? (m["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
                // "<command-name>…", "<local-command-…>" and the like are not something the user wrote.
                if let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") { prompt = t }
            }
        }
        // The latest cwd wins: a session that moved folders (a renamed repo, a `cd`) belongs where it is now.
        // ponytail: resuming such a session from its new folder may not find it (Claude keys sessions
        // by the starting folder); handle when "Continue Here" on a moved session is reported broken.
        for line in text.split(separator: "\n").reversed() where line.contains("\"cwd\":") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let c = o["cwd"] as? String { cwd = c; break }
        }
        let topic = (title ?? prompt ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return (cwd, String(topic.prefix(120)))
    }
}

enum ProjectError: Error, Equatable { case invalidName, exists, gitFailed }

enum Projects {
    /// `<home>/workspace/<name>`, made and set up as a repository. The caller registers the result.
    static func create(name: String, home: String = NSHomeDirectory()) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name.count <= 100 else { throw ProjectError.invalidName }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: home).appendingPathComponent("workspace/\(name)")
        guard !fm.fileExists(atPath: dir.path) else { throw ProjectError.exists }
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init", "-q"]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ProjectError.gitFailed }
        } catch {
            try? fm.removeItem(at: dir) // ours, and empty
            throw ProjectError.gitFailed
        }
        return dir
    }
}
