import Foundation

// The Team tab's data: a conversation's subagents as a tree (main agent → PM → builders …).
// Claude Code layout (observed): <project>/<session>.jsonl is the main transcript; each subagent
// writes <project>/<session>/subagents/agent-<agentId>.jsonl plus agent-<agentId>.meta.json
// {agentType, description, toolUseId, spawnDepth, finished, …}. A spawn is an `Agent` (older: `Task`)
// tool_use; its tool_result says the agent finished (sync) or `isAsync/async_launched` + agentId
// (background), and a background agent's end arrives later as a
// <task-notification><task-id>…</task-id><status>completed|failed|killed</status> line.
// A transcript only records finished turns, so "working" means "no end seen yet".

/// Words the tree shows. Defaults are English; the integrator fills it from Localizable.strings
/// (ko text in `TeamWords.ko`). `%@` is replaced by the file name where there is one.
struct TeamWords: Sendable {
    var lead = "Team lead", planner = "Planner", builder = "Builder", designer = "Designer"
    var checker = "Checker", tester = "Tester", scout = "Scout", helper = "Helper"
    var waiting = "Waiting for you", working = "Working…"
    /// Tool lines are ChatParse.friendly's English lines; this maps them to the display language.
    var tool: [String: String] = [:]

    static let en = TeamWords()
    static let ko = TeamWords(
        lead: "팀장", planner: "기획자", builder: "개발자", designer: "디자이너", checker: "검토자",
        tester: "테스터", scout: "조사원", helper: "도우미", waiting: "답변 대기 중", working: "작업 중…",
        tool: ["Writing a document…": "문서를 쓰는 중…", "Changing the app…": "앱을 고치는 중…",
               "Running the app…": "앱을 실행하는 중…", "Checking…": "확인하는 중…", "Setting things up…": "준비하는 중…",
               "Saving the work…": "작업을 저장하는 중…", "Reading…": "읽는 중…", "Asking a teammate…": "팀원에게 맡기는 중…",
               "Looking things up…": "찾아보는 중…", "Asking you…": "물어보는 중…", "Planning…": "계획하는 중…",
               "Using a connected service…": "연결된 서비스를 쓰는 중…", "Working…": "작업 중…"])
}

enum TeamState: String, Codable, Sendable { case working, done, blocked, failed }

struct TeamNode: Identifiable, Codable, Sendable {
    var id: String
    var role: String
    var doing: String
    var started: Date?
    var ended: Date?
    var state: TeamState
    var children: [TeamNode] = []

    func elapsed(now: Date = Date()) -> TimeInterval? {
        started.map { max(0, (ended ?? now).timeIntervalSince($0)) }
    }
}

enum Team {
    /// One-shot load. For a live session keep a `TeamReader` and call `refresh()` instead.
    static func load(_ transcript: URL, runLog: URL? = nil, words: TeamWords = .en) -> TeamNode {
        TeamReader(transcript: transcript, runLog: runLog, words: words).refresh()
    }
}

/// Keeps what it has read of each transcript (byte offsets), so a refresh parses only appended lines.
final class TeamReader {
    private struct Call {
        var id: String, type: String, desc: String, started: Date?
        var agentId: String?, ended: Date?, failed = false, finished = false
    }
    private final class Track {
        var offset = 0
        var first: Date?, last: Date?
        var pending: [String: String] = [:]  // tool_use id -> tool name, until its result
        var lastTool: (name: String, input: [String: Any])?
        var calls: [Call] = []
    }

    private let main: URL, runLog: URL?, words: TeamWords, iso = ISO8601DateFormatter()
    private var tracks: [String: Track] = [:]  // file path -> track
    private var metas: [String: (type: String, desc: String, toolUse: String, finished: Bool)] = [:]  // agentId
    private var ended: [String: (status: String, at: Date?)] = [:]  // task-id and tool-use-id -> notification

    init(transcript: URL, runLog: URL? = nil, words: TeamWords = .en) {
        main = transcript; self.runLog = runLog; self.words = words
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func refresh() -> TeamNode {
        let dir = main.deletingPathExtension().appendingPathComponent("subagents")
        scanMetas(dir)
        let root = track(main)
        let log = runLog.map(Self.parseRunLog) ?? [:]
        var used = Set<String>()
        var kids = children(of: root, dir: dir, log: log, used: &used)
        // agents whose spawn call we never saw (e.g. compacted away) hang off the root
        for (agent, m) in metas.sorted(by: { $0.key < $1.key }) where !used.contains(agent) {
            kids.append(node(Call(id: m.toolUse, type: m.type, desc: m.desc, started: nil, agentId: agent), dir: dir, log: log, used: &used))
        }
        let blocked = root.pending.values.contains("AskUserQuestion")
        return TeamNode(id: main.deletingPathExtension().lastPathComponent, role: words.lead,
                        doing: blocked ? words.waiting : root.lastTool.map(friendly) ?? words.working,
                        started: root.first, ended: nil, state: blocked ? .blocked : .working, children: kids)
    }

    // MARK: Tree

    private func children(of t: Track, dir: URL, log: [String: (role: String, state: TeamState)], used: inout Set<String>) -> [TeamNode] {
        t.calls.map { node($0, dir: dir, log: log, used: &used) }
    }

    private func node(_ c: Call, dir: URL, log: [String: (role: String, state: TeamState)], used: inout Set<String>) -> TeamNode {
        let agent = c.agentId ?? metas.first { $0.value.toolUse == c.id }?.key
        if let agent { used.insert(agent) }
        let m = agent.flatMap { metas[$0] }
        let sub = agent.map { track(dir.appendingPathComponent("agent-\($0).jsonl")) }
        let note = ended[agent ?? ""] ?? ended[c.id]
        let status = note?.status.lowercased()
        let logged = agent.flatMap { log[$0] }

        var state = TeamState.working
        var end = c.ended
        if c.failed || status == "failed" || status == "killed" || status == "error" { state = .failed }
        else if c.finished || status == "completed" || m?.finished == true { state = .done }
        if state != .working { end = note?.at ?? c.ended ?? sub?.last }
        else if sub?.pending.values.contains("AskUserQuestion") == true { state = .blocked }
        else if let l = logged?.state, l != .working { state = l; end = l == .done || l == .failed ? sub?.last : nil }

        let type = m?.type ?? c.type
        let desc = c.desc.isEmpty ? (m?.desc ?? "") : c.desc
        let doing: String
        switch state {
        case .blocked: doing = words.waiting
        case .working: doing = sub?.lastTool.map(friendly) ?? (desc.isEmpty ? words.working : desc)
        case .done, .failed: doing = desc.isEmpty ? words.working : desc
        }
        let nested = sub.map { children(of: $0, dir: dir, log: log, used: &used) } ?? []
        return TeamNode(id: agent ?? c.id, role: role(type, logRole: logged?.role), doing: doing,
                        started: c.started ?? sub?.first, ended: end, state: state, children: nested)
    }

    // MARK: Words

    private func known(_ s: String) -> String? {
        let t = s.lowercased()
        if t.contains("planner") || t == "plan" { return words.planner }
        if t.contains("builder") || t.contains("developer") { return words.builder }
        if t.contains("designer") { return words.designer }
        if t.contains("checker") || t.contains("reviewer") { return words.checker }
        if t.contains("tester") || t.hasSuffix("qa") { return words.tester }
        if t.contains("scout") || t == "explore" { return words.scout }
        if t == "wanjang" || t.hasSuffix(":wanjang") || t == "pm" || t.contains("manager") { return words.lead }
        return nil
    }

    private func role(_ type: String, logRole: String?) -> String {
        if let r = known(type) { return r }
        if let l = logRole, let r = known(l) { return r }
        if type.isEmpty || type == "general-purpose" { return words.helper }
        let plain = (type.split(separator: ":").last.map(String.init) ?? type)
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return plain.prefix(1).uppercased() + plain.dropFirst()
    }

    private func friendly(_ t: (name: String, input: [String: Any])) -> String {
        let (line, subject) = ChatParse.friendly(t.name, t.input)
        return [words.tool[line] ?? line, subject].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Reading

    private func scanMetas(_ dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where n.hasPrefix("agent-") && n.hasSuffix(".meta.json") {
            let agent = String(n.dropFirst(6).dropLast(10))
            // a finished agent's meta no longer changes; the others are re-read (cheap, tiny files)
            if metas[agent]?.finished == true { continue }
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            metas[agent] = (o["agentType"] as? String ?? "", o["description"] as? String ?? "",
                            o["toolUseId"] as? String ?? "", o["finished"] as? Bool ?? false)
        }
    }

    /// Reads the complete lines appended since the last call.
    private func track(_ url: URL) -> Track {
        let t = tracks[url.path] ?? Track()
        tracks[url.path] = t
        guard let h = try? FileHandle(forReadingFrom: url) else { return t }
        defer { try? h.close() }
        let size = Int((try? h.seekToEnd()) ?? 0)
        if size < t.offset { t.offset = 0; t.first = nil; t.last = nil; t.pending = [:]; t.lastTool = nil; t.calls = [] }  // replaced file
        guard size > t.offset, (try? h.seek(toOffset: UInt64(t.offset))) != nil,
              let data = try? h.readToEnd(), let cut = data.lastIndex(of: 10) else { return t }
        t.offset += cut + 1
        for line in data[data.startIndex...cut].split(separator: 10) { read(Data(line), into: t) }
        return t
    }

    private func read(_ line: Data, into t: Track) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let at = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
        if t.first == nil { t.first = at }
        if let at { t.last = at }
        let content = (o["message"] as? [String: Any])?["content"]
        if let s = content as? String { notification(s, at: at); return }
        guard let blocks = content as? [[String: Any]] else {
            if let s = o["content"] as? String { notification(s, at: at) }  // queue-operation
            return
        }
        for b in blocks {
            switch b["type"] as? String {
            case "text": if let s = b["text"] as? String { notification(s, at: at) }
            case "tool_use":
                guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                let input = b["input"] as? [String: Any] ?? [:]
                t.pending[id] = name
                t.lastTool = (name, input)
                if name == "Agent" || name == "Task" {
                    let first = (input["prompt"] as? String)?.split(separator: "\n").first.map(String.init) ?? ""
                    let d = input["description"] as? String ?? ""
                    t.calls.append(Call(id: id, type: input["subagent_type"] as? String ?? "", desc: d.isEmpty ? first : d, started: at))
                }
            case "tool_result":
                guard let id = b["tool_use_id"] as? String else { continue }
                t.pending[id] = nil
                guard let i = t.calls.firstIndex(where: { $0.id == id }) else { continue }
                let r = o["toolUseResult"] as? [String: Any]
                if let a = r?["agentId"] as? String { t.calls[i].agentId = a }
                if r?["isAsync"] as? Bool == true || r?["status"] as? String == "async_launched" { continue }  // runs on
                t.calls[i].ended = at
                if b["is_error"] as? Bool == true { t.calls[i].failed = true } else { t.calls[i].finished = true }
            default: break
            }
        }
    }

    private func notification(_ s: String, at: Date?) {
        guard s.contains("<task-notification>") else { return }
        for part in s.components(separatedBy: "<task-notification>").dropFirst() {
            func tag(_ n: String) -> String? {
                guard let a = part.range(of: "<\(n)>"), let b = part.range(of: "</\(n)>", range: a.upperBound..<part.endIndex) else { return nil }
                return String(part[a.upperBound..<b.lowerBound])
            }
            guard let status = tag("status") else { continue }
            for k in [tag("task-id"), tag("tool-use-id")].compactMap({ $0 }) { ended[k] = (status, at) }
        }
    }

    /// wanjang's run log: a Tasks table whose worker cell holds the agent id "(a6ef3acca635ee968)".
    static func parseRunLog(_ url: URL) -> [String: (role: String, state: TeamState)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: (role: String, state: TeamState)] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5, let r = cells[2].range(of: #"[0-9a-f]{16,17}"#, options: .regularExpression) else { continue }
            let status = cells[4].lowercased()
            let state: TeamState = status.hasPrefix("done") ? .done : status.hasPrefix("blocked") ? .blocked
                : status.hasPrefix("fail") ? .failed : .working
            out[String(cells[2][r])] = (cells[2].split(separator: " ").first.map(String.init) ?? "", state)
        }
        return out
    }
}

extension TeamWords {
    /// The tree's words in the app's language.
    static var localized: TeamWords {
        var w = TeamWords(lead: String(localized: "Team lead"), planner: String(localized: "Planner"), builder: String(localized: "Builder"),
                          designer: String(localized: "Designer"), checker: String(localized: "Checker"), tester: String(localized: "Tester"),
                          scout: String(localized: "Scout"), helper: String(localized: "Helper"),
                          waiting: String(localized: "Waiting for you"), working: String(localized: "Working…"))
        for k in TeamWords.ko.tool.keys { w.tool[k] = String(localized: String.LocalizationValue(k)) }
        return w
    }
}
