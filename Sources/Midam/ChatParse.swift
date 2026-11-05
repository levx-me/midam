import Foundation

/// One row of a conversation: what the person said, the agent's reply, a tool it used, a card
/// waiting for the person, an error or a turn's cost. `id` is stable while the item updates.
struct ChatItem: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case user(text: String, queued: Bool)
        case assistant(markdown: String, streaming: Bool)
        /// `line` is an English source string (a Localizable.strings key), `subject` a file name
        /// or a teammate's task, `detail` the command or path plus the result, for the expanded view.
        case tool(name: String, line: String, subject: String?, detail: String, status: ToolStatus)
        /// `sentence` is a Localizable.strings key (Permission.decide); `answer` nil until answered,
        /// false when denied, cancelled or the process ended first (fail closed).
        case permission(sentence: String, tool: String, input: String, answer: Bool?)
        case question(questions: [Question], answers: [String: String]?)
        case error(String)
        case result(cost: Double, inputTokens: Int, outputTokens: Int)
    }
    enum ToolStatus: Equatable, Codable, Sendable { case running, done, failed }
    struct Question: Equatable, Codable, Sendable {
        var header: String
        var question: String
        var multiSelect: Bool
        var options: [Option]
    }
    struct Option: Equatable, Codable, Sendable {
        var label: String
        var description: String
        var preview: String?
    }
    let id: String
    var kind: Kind
}

/// A `can_use_tool` control request: the CLI waits until Midam answers it.
struct ToolRequest: Equatable {
    var id: String
    var tool: String
    var input: String // JSON object text, echoed back as updatedInput on allow
}

/// Turns Claude Code's stream-json output lines and transcript JSONL lines into chat items and the
/// conversation's metadata. Pure: no IO, so tools/ConversationTest feeds it recorded lines.
struct ChatParse {
    private(set) var items: [ChatItem] = []
    private(set) var model: String?
    private(set) var sessionID: String?
    /// The ai-title, else the first prompt. History paging seeds it from the transcript's head.
    var topic: String?
    private(set) var contextTokens = 0
    private(set) var contextWindow: Int?
    /// A `result` line arrived: the turn in flight is over.
    private(set) var turnEnded = false
    private var openTasks = Set<String>()
    /// History read from the end: tool results whose tool use is on an earlier page, by tool use id.
    var laterResults: [String: (output: String, failed: Bool)] = [:]
    private var interrupted = false

    /// Teammates (Task/Agent tool uses) still running.
    var subagents: Int { openTasks.count }

    /// Share of the model's context window the newest main-thread message used, 0–100.
    var contextPercent: Int? {
        guard contextTokens > 0 else { return nil }
        // ponytail: window guessed from the model name until a result reports contextWindow.
        let window = contextWindow ?? ((model ?? "").hasSuffix("[1m]") ? 1_000_000 : 200_000)
        return min(100, contextTokens * 100 / window)
    }

    /// One stdout line of `claude -p --output-format stream-json`. Returns the control request the
    /// CLI is waiting on, if the line is one.
    mutating func stream(_ line: String) -> ToolRequest? {
        guard let m = Self.object(line) else { return nil }
        turnEnded = false
        switch m["type"] as? String {
        case "system":
            if m["subtype"] as? String == "init" {
                model = m["model"] as? String ?? model
                sessionID = m["session_id"] as? String ?? sessionID
            } // hook_started, hook_response, status, thinking_tokens: nothing to show
        case "stream_event":
            guard m["parent_tool_use_id"] is NSNull || m["parent_tool_use_id"] == nil,
                  let e = m["event"] as? [String: Any], let msg = m["api_message_id"] as? String,
                  let index = e["index"] as? Int else { break }
            let id = "\(msg)#\(index)"
            if e["type"] as? String == "content_block_start",
               (e["content_block"] as? [String: Any])?["type"] as? String == "text" {
                items.append(ChatItem(id: id, kind: .assistant(markdown: "", streaming: true)))
            } else if e["type"] as? String == "content_block_delta",
                      let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                      let text = d["text"] as? String,
                      let i = items.lastIndex(where: { $0.id == id }),
                      case .assistant(let md, true) = items[i].kind {
                items[i].kind = .assistant(markdown: md + text, streaming: true)
            }
        case "assistant", "user":
            message(m, live: true)
        case "result":
            turnEnded = true
            for case let usage as [String: Any] in (m["modelUsage"] as? [String: Any] ?? [:]).values {
                if let w = usage["contextWindow"] as? Int { contextWindow = w }
            }
            let usage = m["usage"] as? [String: Any] ?? [:]
            // An interrupted turn ends as an error result too; that is the person's own Stop.
            if m["is_error"] as? Bool == true, !interrupted {
                let text = m["result"] as? String ?? "Something went wrong." // 문제가 생겼어요.
                items.append(ChatItem(id: "result-\(items.count)", kind: .error(text)))
            }
            interrupted = false
            items.append(ChatItem(id: "result-\(items.count)", kind: .result(
                cost: m["total_cost_usd"] as? Double ?? 0,
                inputTokens: Self.int(usage, "input_tokens") + Self.int(usage, "cache_read_input_tokens") + Self.int(usage, "cache_creation_input_tokens"),
                outputTokens: Self.int(usage, "output_tokens"))))
        case "control_request":
            guard let r = m["request"] as? [String: Any], r["subtype"] as? String == "can_use_tool",
                  let id = m["request_id"] as? String, let tool = r["tool_name"] as? String else { break }
            let input = r["input"] as? [String: Any] ?? [:]
            return ToolRequest(id: id, tool: tool, input: Self.json(input))
        case "control_cancel_request":
            if let id = m["request_id"] as? String { settle(id) }
        default: break // rate_limit_event, control_response, unknown kinds
        }
        return nil
    }

    /// One line of a session transcript (`~/.claude/projects/<slug>/<id>.jsonl`), for history.
    mutating func transcript(_ line: String) {
        guard let m = Self.object(line), m["isSidechain"] as? Bool != true else { return }
        switch m["type"] as? String {
        case "ai-title":
            if let t = m["aiTitle"] as? String, !t.isEmpty { topic = t }
        case "user", "assistant":
            if sessionID == nil { sessionID = m["sessionId"] as? String }
            if m["isMeta"] as? Bool == true { return }
            message(m, live: false)
        default: break
        }
    }

    /// The person sent `text` (stream-json does not echo it back).
    mutating func userSent(_ text: String, id: String, queued: Bool) {
        items.append(ChatItem(id: id, kind: .user(text: text, queued: queued)))
        if topic == nil { topic = Self.topic(text) }
    }

    mutating func unqueue(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }), case .user(let t, _) = items[i].kind {
            items[i].kind = .user(text: t, queued: false)
        }
    }

    /// Shows a permission card for a request Permission.decide asked about.
    mutating func ask(_ r: ToolRequest, sentence: String) {
        items.append(ChatItem(id: r.id, kind: .permission(sentence: sentence, tool: r.tool, input: r.input, answer: nil)))
    }

    /// Shows the choice card for an AskUserQuestion request.
    mutating func question(_ r: ToolRequest) {
        items.append(ChatItem(id: r.id, kind: .question(questions: Self.questions(r.input), answers: nil)))
    }

    mutating func answered(_ id: String, allow: Bool) {
        if let i = items.firstIndex(where: { $0.id == id }), case .permission(let s, let t, let inp, nil) = items[i].kind {
            items[i].kind = .permission(sentence: s, tool: t, input: inp, answer: allow)
        }
    }

    mutating func answered(_ id: String, answers: [String: String]) {
        if let i = items.firstIndex(where: { $0.id == id }), case .question(let q, nil) = items[i].kind {
            items[i].kind = .question(questions: q, answers: answers)
        }
    }

    /// Cards still waiting for the person.
    var pending: [String] {
        items.compactMap {
            switch $0.kind {
            case .permission(_, _, _, nil), .question(_, nil): return $0.id
            default: return nil
            }
        }
    }

    /// Closes a card nobody can answer any more (request cancelled, process ended): a denial.
    mutating func settle(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].kind {
        case .permission(let s, let t, let inp, nil): items[i].kind = .permission(sentence: s, tool: t, input: inp, answer: false)
        case .question(let q, nil): items[i].kind = .question(questions: q, answers: [:])
        default: break
        }
    }

    mutating func error(_ text: String) {
        items.append(ChatItem(id: "error-\(items.count)", kind: .error(text)))
    }

    /// Puts `earlier`, the history page before this one (parsed with this parse's laterResults),
    /// in front; what this parse has not learned yet (model, topic, …) comes from it.
    mutating func prepend(_ earlier: ChatParse) {
        items = earlier.items + items
        laterResults = earlier.laterResults
        openTasks.formUnion(earlier.openTasks)
        model = model ?? earlier.model
        sessionID = sessionID ?? earlier.sessionID
        topic = topic ?? earlier.topic
        if contextTokens == 0 { contextTokens = earlier.contextTokens }
    }

    // MARK: - Messages

    private mutating func message(_ m: [String: Any], live: Bool) {
        guard let msg = m["message"] as? [String: Any] else { return }
        let sub = !(m["parent_tool_use_id"] is NSNull || m["parent_tool_use_id"] == nil)
        if msg["role"] as? String == "assistant" {
            if sub { return } // a teammate's own messages (not forwarded unless --forward-subagent-text)
            if let mod = msg["model"] as? String, mod != "<synthetic>" { model = mod }
            if let u = msg["usage"] as? [String: Any] {
                let t = Self.int(u, "input_tokens") + Self.int(u, "cache_read_input_tokens") + Self.int(u, "cache_creation_input_tokens")
                if t > 0 { contextTokens = t }
            }
            let mid = msg["id"] as? String ?? UUID().uuidString
            // A transcript line's own uuid keeps ids the same however the history is paged.
            let line = live ? nil : m["uuid"] as? String
            for case let (n, b as [String: Any]) in (msg["content"] as? [Any] ?? []).enumerated() {
                switch b["type"] as? String {
                case "text":
                    let text = b["text"] as? String ?? ""
                    if live, let i = items.lastIndex(where: { $0.id.hasPrefix(mid + "#") }),
                       case .assistant(_, true) = items[i].kind {
                        items[i].kind = .assistant(markdown: text, streaming: false)
                    } else if !text.isEmpty {
                        let id = line.map { "\(mid)#\($0).\(n)" } ?? "\(mid)#\(items.count)"
                        items.append(ChatItem(id: id, kind: .assistant(markdown: text, streaming: false)))
                    }
                case "tool_use":
                    guard let id = b["id"] as? String, let name = b["name"] as? String,
                          !items.contains(where: { $0.id == id }) else { continue }
                    let input = b["input"] as? [String: Any] ?? [:]
                    let f = Self.friendly(name, input)
                    let detail = Self.detail(name, input)
                    if let r = laterResults.removeValue(forKey: id) { // its result is already on a later page
                        items.append(ChatItem(id: id, kind: .tool(name: name, line: f.line, subject: f.subject,
                                                                  detail: Self.detail(detail, r.output), status: r.failed ? .failed : .done)))
                        continue
                    }
                    items.append(ChatItem(id: id, kind: .tool(name: name, line: f.line, subject: f.subject, detail: detail, status: .running)))
                    if name == "Task" || name == "Agent" { openTasks.insert(id) }
                default: break // thinking
                }
            }
            return
        }
        // role user: a typed prompt (transcript), tool results, or an interrupt marker.
        if let text = msg["content"] as? String {
            if !live, !sub, let t = Self.prompt(text) {
                items.append(ChatItem(id: m["uuid"] as? String ?? "u\(items.count)", kind: .user(text: t, queued: false)))
                if topic == nil { topic = Self.topic(t) }
            }
            return
        }
        for case let b as [String: Any] in msg["content"] as? [Any] ?? [] {
            switch b["type"] as? String {
            case "tool_result":
                guard let id = b["tool_use_id"] as? String else { continue }
                openTasks.remove(id)
                let out = String(Self.text(b["content"]).prefix(2000)), failed = b["is_error"] as? Bool == true
                guard let i = items.firstIndex(where: { $0.id == id }),
                      case .tool(let n, let l, let s, let d, _) = items[i].kind else {
                    if !live { laterResults[id] = (out, failed) }
                    continue
                }
                items[i].kind = .tool(name: n, line: l, subject: s, detail: Self.detail(d, out), status: failed ? .failed : .done)
            case "text":
                if (b["text"] as? String ?? "").hasPrefix("[Request interrupted") { interrupted = true }
                if !live, !sub, let t = Self.prompt(b["text"] as? String ?? "") {
                    items.append(ChatItem(id: m["uuid"] as? String ?? "u\(items.count)", kind: .user(text: t, queued: false)))
                    if topic == nil { topic = Self.topic(t) }
                }
            default: break
            }
        }
    }

    /// A real prompt, not a command echo, a system reminder or an interrupt marker.
    private static func prompt(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("[Request interrupted") { return nil }
        return t
    }

    private static func topic(_ text: String) -> String? {
        guard let t = prompt(text) else { return nil }
        let line = t.split(separator: "\n").first.map(String.init) ?? t
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    // MARK: - Friendly tool lines

    /// Plain words for a tool use. Lines are English source strings (Localizable.strings keys):
    /// "Writing a document…" 문서를 쓰는 중…, "Changing the app…" 앱을 고치는 중…,
    /// "Running the app…" 앱을 실행하는 중…, "Checking…" 확인하는 중…, "Setting things up…" 준비하는 중…,
    /// "Saving the work…" 작업을 저장하는 중…, "Reading…" 읽는 중…, "Asking a teammate…" 팀원에게 맡기는 중…,
    /// "Looking things up…" 찾아보는 중…, "Asking you…" 물어보는 중…, "Planning…" 계획하는 중…,
    /// "Using a connected service…" 연결된 서비스를 쓰는 중…, "Working…" 작업하는 중….
    static func friendly(_ name: String, _ input: [String: Any]) -> (line: String, subject: String?) {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? input["path"] as? String
        let file = path.map { ($0 as NSString).lastPathComponent }
        let doc = path.map { ["md", "markdown", "mdown", "mkd", "txt"].contains(($0 as NSString).pathExtension.lowercased()) } ?? false
        switch name {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            return doc ? ("Writing a document…", file) : ("Changing the app…", nil)
        case "Read", "Grep", "Glob", "LS":
            return ("Reading…", doc ? file : nil)
        case "Bash":
            return (bashLine(input["command"] as? String ?? ""), nil)
        case "Task", "Agent":
            return ("Asking a teammate…", input["description"] as? String)
        case "WebFetch", "WebSearch":
            return ("Looking things up…", nil)
        case "AskUserQuestion":
            return ("Asking you…", nil)
        case "TodoWrite", "TaskCreate", "TaskUpdate", "EnterPlanMode", "ExitPlanMode":
            return ("Planning…", nil)
        default:
            return (name.hasPrefix("mcp__") ? "Using a connected service…" : "Working…", nil)
        }
    }

    // ponytail: keyword match on the command, not a shell parser.
    private static func bashLine(_ command: String) -> String {
        let c = " " + command.lowercased() + " "
        func has(_ words: [String]) -> Bool { words.contains { c.contains($0) } }
        if has([" test", "check", " lint", "tsc ", "typecheck", "pytest", "vitest", "jest"]) { return "Checking…" }
        if has(["install", " add ", "brew ", "pip "]) { return "Setting things up…" }
        if has(["git commit", "git add", "git push"]) { return "Saving the work…" }
        if has(["build", " run ", " start", " dev ", " dev\n", "serve", " open ", "make ", "./"]) { return "Running the app…" }
        if has(["cat ", "ls ", "grep ", "find ", "head ", "tail ", " rg "]) { return "Reading…" }
        return "Working…"
    }

    /// A tool's detail with its result below.
    private static func detail(_ detail: String, _ output: String) -> String {
        output.isEmpty ? detail : detail + "\n\n" + output
    }

    private static func detail(_ name: String, _ input: [String: Any]) -> String {
        if name == "Bash", let c = input["command"] as? String { return c }
        if let p = input["file_path"] as? String ?? input["notebook_path"] as? String { return p }
        if let d = input["description"] as? String, let p = input["prompt"] as? String { return d + "\n\n" + p }
        return json(input)
    }

    // MARK: - AskUserQuestion

    static func questions(_ inputJSON: String) -> [ChatItem.Question] {
        guard let m = object(inputJSON) else { return [] }
        return (m["questions"] as? [[String: Any]] ?? []).map { q in
            ChatItem.Question(
                header: q["header"] as? String ?? "", question: q["question"] as? String ?? "",
                multiSelect: q["multiSelect"] as? Bool ?? false,
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    ChatItem.Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "",
                                    preview: $0["preview"] as? String)
                })
        }
    }

    // MARK: - JSON helpers

    static func object(_ line: String) -> [String: Any]? {
        guard line.first == "{" || line.hasPrefix(" {") else { return nil } // shell noise before the first event
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    private static func int(_ m: [String: Any], _ k: String) -> Int { m[k] as? Int ?? 0 }

    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
