import Foundation

/// One Claude Code conversation in a project: a single long-lived `claude -p` process speaking
/// stream-json over pipes (no terminal), started on the first send. Tool uses that Permission.decide
/// allows are answered at once; the rest become cards the person answers (fail closed: a card
/// nobody answered before the process ended counts as a denial, and the tool never ran).
@MainActor
final class Conversation: ObservableObject {
    enum State: Equatable, Codable, Sendable {
        case notStarted, working, blocked, idle
        /// The error: the CLI's last stderr line, or a Localizable.strings key; nil for a normal stop.
        case ended(String?)
    }

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var state = State.notStarted
    @Published private(set) var model: String?
    @Published private(set) var contextPercent: Int?
    @Published private(set) var subagents = 0
    @Published private(set) var topic: String?
    private(set) var sessionID: String

    let project: URL
    /// For the headless smoke test (`haiku`); nil = the person's default model.
    var modelOverride: String?
    /// Called after every change (LocalAgentHost turns it into events).
    var changed: (@MainActor () -> Void)?
    private var resume: Bool
    private var parse = ChatParse()
    private var process: Process?
    private var input: FileHandle?
    private var requests: [String: ToolRequest] = [:]
    private var queue: [(id: String, text: String)] = []
    private var turn = false
    private var stderrTail: [String] = []

    /// A new conversation, or (with `resumeID`) an earlier session whose history is loaded at once;
    /// nothing runs until the first send.
    init(project: URL, resumeID: String? = nil) {
        self.project = project
        resume = resumeID != nil
        sessionID = resumeID.flatMap(Self.sessionID) ?? UUID().uuidString.lowercased()
        if resume { loadHistory() }
    }

    func start() {
        guard process == nil else { return }
        guard let argv = Self.argv(sessionID: sessionID, resume: resume, pluginDir: Self.pluginDir, model: modelOverride) else {
            return end("This conversation can't be opened.") // 이 대화를 열 수 없어요.
        }
        signal(SIGPIPE, SIG_IGN) // a write after the CLI exited must fail, not kill Midam
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.currentDirectoryURL = project
        let (inp, out, err) = (Pipe(), Pipe(), Pipe())
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return end(error.localizedDescription) }
        process = p
        input = inp.fileHandleForWriting
        resume = true // a restart after an exit resumes the same session
        publish()
        Self.read(out.fileHandleForReading, err: err.fileHandleForReading, process: p) { [weak self] lines, isErr in
            guard let self, self.process === p else { return }
            if isErr { self.stderrTail = Array((self.stderrTail + lines).suffix(5)) } else { self.handle(lines) }
        } ended: { [weak self] status in
            guard let self, self.process === p else { return }
            self.exited(status)
        }
    }

    /// Sends a message; while a turn runs it waits (shown greyed) and goes after that turn.
    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if process == nil { start() }
        guard process != nil else { return }
        let id = UUID().uuidString
        let busy = turn || !queue.isEmpty
        parse.userSent(text, id: id, queued: busy)
        if busy { queue.append((id, text)) } else { write(user: text) }
        publish()
    }

    func interrupt() {
        guard turn else { return }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func stop() {
        guard let p = process else { return }
        try? input?.close()
        p.terminate()
    }

    func answer(permission id: String, allow: Bool) {
        guard let r = requests.removeValue(forKey: id) else { return }
        respond(r, allow: allow)
        parse.answered(id, allow: allow)
        publish()
    }

    /// `choices` maps each question's text to the chosen labels (or the person's own words).
    func answer(question id: String, choices: [String: [String]]) {
        guard let r = requests.removeValue(forKey: id), var input = ChatParse.object(r.input) else { return }
        let answers = choices.mapValues { $0.joined(separator: ", ") }
        input["answers"] = answers
        write(["type": "control_response", "response": ["subtype": "success", "request_id": id,
               "response": ["behavior": "allow", "updatedInput": input]]])
        parse.answered(id, answers: answers)
        publish()
    }

    // MARK: - Output

    private func handle(_ lines: [String]) {
        for line in lines {
            if let r = parse.stream(line) { request(r) }
            if parse.turnEnded {
                turn = false
                if !queue.isEmpty {
                    let next = queue.removeFirst()
                    parse.unqueue(next.id)
                    write(user: next.text)
                }
            }
        }
        publish()
    }

    private func request(_ r: ToolRequest) {
        if r.tool == "AskUserQuestion" {
            requests[r.id] = r
            parse.question(r)
            return
        }
        // The plugin's files and the CLI's saved tool output for this project read without asking.
        let reads = [Self.pluginDir, Self.projectFolder(project).path].compactMap { $0 }
        switch Permission.decide(tool: r.tool, input: ChatParse.object(r.input) ?? [:], project: project, reads: reads) {
        case .allow: respond(r, allow: true)
        case .ask(let sentence):
            requests[r.id] = r
            parse.ask(r, sentence: sentence)
        }
    }

    private func respond(_ r: ToolRequest, allow: Bool) {
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": ChatParse.object(r.input) ?? [:]]
            : ["behavior": "deny", "message": "The person said no to this. Don't try it another way; ask them if it is needed."]
        write(["type": "control_response", "response": ["subtype": "success", "request_id": r.id, "response": response]])
    }

    private func exited(_ status: Int32) {
        for id in parse.pending { parse.settle(id) }
        requests = [:]
        process = nil
        input = nil
        turn = false
        queue = []
        let error = status == 0 || status == SIGTERM ? nil : (stderrTail.last ?? "Claude stopped unexpectedly.") // Claude가 뜻밖에 멈췄어요.
        end(error)
    }

    private func end(_ error: String?) {
        if let error { parse.error(error) }
        state = .ended(error)
        publish()
    }

    private func publish() {
        items = parse.items
        model = parse.model
        contextPercent = parse.contextPercent
        subagents = parse.subagents
        topic = parse.topic
        if let id = parse.sessionID { sessionID = id }
        if process != nil { state = !parse.pending.isEmpty ? .blocked : turn ? .working : .idle }
        changed?()
    }

    // MARK: - Input

    private func write(user text: String) {
        turn = true
        write(["type": "user", "message": ["role": "user", "content": text]])
    }

    private func write(_ object: [String: Any]) {
        guard let input, let d = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.write(contentsOf: d + Data([10]))
    }

    // MARK: - History

    private func loadHistory() {
        guard let url = Self.transcript(project: project, id: sessionID) else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            var p = ChatParse()
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") { p.transcript(String(line)) }
            let history = p
            await MainActor.run { [weak self] in
                guard let self, self.items.isEmpty else { return }
                self.parse = history
                self.publish()
            }
        }
    }

    /// `~/.claude/projects/<cwd with every non-alphanumeric as "-">/<id>.jsonl`, else any project
    /// folder holding `<id>.jsonl` (the CLI shortens very long folder names).
    nonisolated static func transcript(project: URL, id: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let root = home.appendingPathComponent(".claude/projects")
        let direct = projectFolder(project, home: home).appendingPathComponent(id + ".jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent(id + ".jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The CLI's folder for `project`'s sessions (transcripts, saved tool output).
    nonisolated static func projectFolder(_ project: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let slug = String(Permission.real(project.path).map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return home.appendingPathComponent(".claude/projects").appendingPathComponent(slug)
    }

    // MARK: - Launch

    /// The bundled wanjang plugin (build.sh copies it in), if this build has it.
    nonisolated static var pluginDir: String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("wanjang"),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude-plugin/plugin.json").path) else { return nil }
        return dir.path
    }

    /// The sandbox keeps writes inside the project (D14), with no way out of it for a command
    /// (allowUnsandboxedCommands) and the usual secrets unreadable to commands and file tools;
    /// the PreToolUse hook answers "ask" for every tool so each use reaches Midam over stdio
    /// (can_use_tool), even ones the person's own settings or hooks would allow. Passed with
    /// --settings, which adds to the person's settings.
    nonisolated static let settings: String = {
        let ask = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}"#
        let secrets = ["~/.ssh", "~/.aws", "~/.gnupg", "~/Library/Keychains"]
        let s: [String: Any] = [
            "sandbox": ["enabled": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false,
                        "filesystem": ["denyRead": secrets]],
            "permissions": ["deny": secrets.map { "Read(\($0)/**)" }],
            "hooks": ["PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "echo " + LoginShell.quote(ask)]]]]],
        ]
        return ChatParse.json(s)
    }()

    /// A lowercase UUID, or nil: the only session ids Midam passes to the CLI.
    nonisolated static func sessionID(_ id: String) -> String? {
        UUID(uuidString: id).map { _ in id.lowercased() }
    }

    /// `[$SHELL, "-l", "-i", "-c", "exec claude …"]`: an interactive login shell, so a GUI app finds
    /// the `claude` the person's shell finds (nvm and friends live in ~/.zshrc). Shell noise on
    /// stdout before the first event is not JSON and ChatParse skips it.
    nonisolated static func argv(sessionID: String, resume: Bool, pluginDir: String?, model: String? = nil,
                                 shell: String = LoginShell.path) -> [String]? {
        guard let id = Self.sessionID(sessionID) else { return nil }
        var args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-mode", "acceptEdits",
                    // Not in --help, but what the Agent SDK passes: tool approvals and
                    // AskUserQuestion come to the host as can_use_tool control requests.
                    "--permission-prompt-tool", "stdio",
                    "--settings", settings]
        if let pluginDir { args += ["--plugin-dir", pluginDir] }
        if let model { args += ["--model", model] }
        args += resume ? ["--resume", id] : ["--session-id", id]
        return [shell] + LoginShell.arguments("exec " + args.map(LoginShell.quote).joined(separator: " "))
    }

    /// Reads stdout and stderr off the main thread in lines, delivered on the main queue in order;
    /// `ended` comes after the last line of both.
    private nonisolated static func read(_ out: FileHandle, err: FileHandle, process: Process,
                                         lines: @escaping @MainActor ([String], Bool) -> Void,
                                         ended: @escaping @MainActor (Int32) -> Void) {
        let group = DispatchGroup()
        func pump(_ h: FileHandle, isErr: Bool) {
            group.enter()
            Thread.detachNewThread {
                var buf = Data()
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    buf.append(d)
                    var batch: [String] = []
                    while let i = buf.firstIndex(of: 10) {
                        batch.append(String(decoding: buf[buf.startIndex..<i], as: UTF8.self))
                        buf.removeSubrange(buf.startIndex...i)
                    }
                    if !batch.isEmpty { let b = batch; DispatchQueue.main.async { MainActor.assumeIsolated { lines(b, isErr) } } }
                }
                if !buf.isEmpty { let b = [String(decoding: buf, as: UTF8.self)]; DispatchQueue.main.async { MainActor.assumeIsolated { lines(b, isErr) } } }
                group.leave()
            }
        }
        pump(out, isErr: false)
        pump(err, isErr: true)
        group.notify(queue: .global()) {
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { ended(status) } }
        }
    }
}
