import Foundation

// Agent terminal tabs, the parts without a view: which agent CLIs are installed, the command line
// a tab runs, agents already running for a project, and paths in terminal output.
// Foundation only, so tools/AgentSessionsTest can compile it with Library.swift.

extension Agent {
    /// The CLI's name on PATH.
    var binary: String { self == .cursor ? "cursor-agent" : rawValue }

    /// The agents whose CLI the login shell finds, in `allCases` order. Asked once per run.
    static func installed() async -> [Agent] { await probe.value }

    // ponytail: probed once per launch; an agent installed while Midam runs shows after a relaunch.
    private static let probe = Task.detached(priority: .utility) {
        found(in: LoginShell.run(allCases.map { "command -v \($0.binary)" }.joined(separator: "; ")) ?? "")
    }

    /// `command -v` output (with whatever the shell's startup files printed around it) into agents.
    static func found(in output: String) -> [Agent] {
        let names = Set(output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("/") }.map { String($0.split(separator: "/").last ?? "") })
        return allCases.filter { names.contains($0.binary) }
    }

    /// The agent a process is, from its short name, executable path and argv. `claude` runs as a
    /// native `claude` (or `claude.exe`) or as `node …/claude-code/cli.js`; cursor-agent as its own `node`.
    // ponytail: name matching; a renamed or wrapped CLI is missed. Good enough for a warning.
    static func of(name: String, path: String?, argv: [String]) -> Agent? {
        let names = [name, path.map { ($0 as NSString).lastPathComponent }, argv.first.map { ($0 as NSString).lastPathComponent }]
            .compactMap { $0?.lowercased() }
        if let a = allCases.first(where: { names.contains($0.binary) || names.contains($0.binary + ".exe") }) { return a }
        guard names.contains(where: { ["node", "bun"].contains($0) }), argv.count > 1 else { return nil }
        let script = argv[1].lowercased()
        if script.contains("/@anthropic-ai/claude-code/") || script.hasSuffix("/claude") { return .claude }
        if script.contains("/@openai/codex/") || script.hasSuffix("/codex") { return .codex }
        if script.contains("cursor-agent") { return .cursor }
        return nil
    }
}

/// The user's login shell: where a GUI app finds the PATH the user's terminal has.
enum LoginShell {
    static var path: String {
        let user = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        for s in [ProcessInfo.processInfo.environment["SHELL"], user] {
            if let s, s.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    /// Interactive as well as login: nvm, pyenv and the like put CLIs on PATH from ~/.zshrc, which a
    /// login shell alone does not read (an nvm-installed `claude` is missing under `zsh -lc`).
    static func arguments(_ command: String) -> [String] { ["-l", "-i", "-c", command] }

    /// The command's stdout, or nil when the shell fails to start or runs past `timeout`.
    /// Blocks: call it off the main thread.
    static func run(_ command: String, timeout: TimeInterval = 3) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments(command)
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            return nil
        }
        // Non-blocking: a background job the startup files left running may still hold the pipe open.
        let fd = out.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `s` as one shell word, for sh, bash, zsh and fish.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}

/// One agent CLI to run in a terminal tab: in `project` (the PTY's cwd), resuming `sessionID` when
/// given. To resume a WritingSession, pass its `cwd` as the project: Claude finds a session only
/// from the folder it ran in.
struct AgentLaunch: Hashable, Sendable {
    let agent: Agent
    let project: URL
    let sessionID: String?

    /// nil when the session id is not a plain id (WritingSession.isValidID): it goes on a command line.
    init?(agent: Agent, project: URL, sessionID: String? = nil) {
        if let id = sessionID, !WritingSession.isValidID(id) { return nil }
        self.agent = agent
        self.project = project
        self.sessionID = sessionID
    }

    /// The CLI's words: `claude --resume <id>`, `codex resume <id>`, `cursor-agent --resume=<id>`.
    var words: [String] {
        guard let id = sessionID else { return [agent.binary] }
        switch agent {
        case .claude: return ["claude", "--resume", id]
        case .codex: return ["codex", "resume", id]
        case .cursor: return ["cursor-agent", "--resume=" + id] // an optional-value flag: keep the id attached
        }
    }

    /// The PTY's program: the login shell, only for PATH and the environment, replaced by the agent
    /// (`exec`), so the tab ends when the agent does instead of dropping to a prompt.
    func argv(shell: String = LoginShell.path) -> [String] {
        [shell] + LoginShell.arguments("exec " + words.map(LoginShell.quote).joined(separator: " "))
    }

    /// What "Copy Command" puts on the clipboard, to run in the user's own terminal.
    var shellCommand: String { "cd " + LoginShell.quote(project.path) + " && " + words.map(LoginShell.quote).joined(separator: " ") }

    /// The PTY's environment: Midam's own (HOME, USER, PATH, SSH_AUTH_SOCK…) with the terminal's.
    static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG", default: ""].isEmpty { env["LANG"] = "en_US.UTF-8" }
        env["CLAUDECODE"] = nil // set when Midam was started from a Claude Code session; claude would refuse to start inside it
        return env.map { $0.key + "=" + $0.value }.sorted()
    }
}

/// What an agent tab remembers across launches: it comes back without running (the owner's
/// choice) and resumes on Return or a click.
struct TerminalTabState: Codable, Hashable, Sendable {
    let agent: Agent
    let project: URL
    var sessionID: String?

    /// "claude · dperp"
    var title: String { agent.binary + " · " + project.lastPathComponent }
    /// nil when a stored session id is not a plain id.
    var launch: AgentLaunch? { AgentLaunch(agent: agent, project: project, sessionID: sessionID) }
}

extension WritingSession {
    /// Resumes this session where it ran.
    var launch: AgentLaunch? { AgentLaunch(agent: agent, project: URL(fileURLWithPath: cwd), sessionID: id) }
}

// MARK: Running agents

/// Agent CLIs running with their cwd in `project` (or under it), other than Midam's own tabs, in
/// `Agent.allCases` order: "already running outside Midam". Reads the process table; call it off
/// the main thread.
func runningAgents(in project: URL) -> [Agent] { RunningAgents.find(in: project) }

private enum RunningAgents {
    static func find(in project: URL) -> [Agent] {
        // realpath, as the kernel reports cwds (resolvingSymlinksInPath turns /private/tmp into /tmp).
        guard let real = realpath(project.path, nil) else { return [] }
        let root = String(cString: real)
        free(real)
        let me = getpid()
        var found = Set<Agent>()
        for pid in pids() where pid != me {
            guard let info = bsdInfo(pid) else { continue }
            let name = text(info.pbi_name).isEmpty ? text(info.pbi_comm) : text(info.pbi_name)
            let path = executable(pid)
            let base = path.map { ($0 as NSString).lastPathComponent.lowercased() }
            let argv = ["node", "bun"].contains(name.lowercased()) || ["node", "bun"].contains(base ?? "") ? arguments(pid) : []
            guard let agent = Agent.of(name: name, path: path, argv: argv), !found.contains(agent),
                  let cwd = cwd(pid), cwd == root || cwd.hasPrefix(root == "/" ? "/" : root + "/"),
                  !descends(pid, from: me) else { continue }
            found.insert(agent)
        }
        return Agent.allCases.filter(found.contains)
    }

    private static func pids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var list = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = list.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return got > 0 ? Array(list.prefix(Int(got))) : []
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func executable(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : nil
    }

    private static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = text(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// argv from KERN_PROCARGS2: argc, the exec path, padding NULs, then the arguments.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 } // exec path
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// Whether `ancestor` started `pid` (directly or further up).
    private static func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
        var p = pid
        for _ in 0..<64 {
            guard let parent = bsdInfo(p).map({ pid_t($0.pbi_ppid) }), parent > 1 else { return false }
            if parent == ancestor { return true }
            p = parent
        }
        return false
    }

    /// A C char array imported as a tuple, up to its NUL.
    private static func text<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

// MARK: Terminal output

/// Paths to Markdown files in a line of terminal output, for ⌘-click.
enum TerminalLinks {
    typealias Link = (range: Range<String.Index>, url: URL, line: Int?)

    /// `docs/plan.md`, `./docs/plan.md:40`, `docs/plan.md:40:3`, `/abs/x.md`, `~/x.markdown`: relative
    /// ones against `project`; only existing files; never URLs. Paths with spaces are not found.
    static func find(in line: String, project: URL, home: String = NSHomeDirectory()) -> [Link] {
        var out: [Link] = []
        var i = line.startIndex
        while i < line.endIndex {
            if line[i].isWhitespace { i = line.index(after: i); continue }
            var j = i
            while j < line.endIndex && !line[j].isWhitespace { j = line.index(after: j) }
            if let link = link(line, i..<j, project: project, home: home) { out.append(link) }
            i = j
        }
        return out
    }

    private static func link(_ line: String, _ word: Range<String.Index>, project: URL, home: String) -> Link? {
        var lo = word.lowerBound, hi = word.upperBound
        while lo < hi, "\"'`([{<".contains(line[lo]) { lo = line.index(after: lo) }
        while lo < hi, "\"'`)]}>,.;:!?".contains(line[line.index(before: hi)]) { hi = line.index(before: hi) }
        let token = line[lo..<hi]
        guard !token.contains("://") else { return nil }
        // Up to two ":<digits>" at the end: line, then column.
        var pathEnd = hi
        var numbers: [Int] = []
        while numbers.count < 2, let colon = token[lo..<pathEnd].lastIndex(of: ":") {
            let digits = token[token.index(after: colon)..<pathEnd]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits) else { break }
            numbers.insert(n, at: 0)
            pathEnd = colon
        }
        let path = String(token[lo..<pathEnd])
        let lower = path.lowercased()
        guard lower.hasSuffix(".md") || lower.hasSuffix(".markdown") else { return nil }
        let full = path.hasPrefix("/") ? path : path.hasPrefix("~/") ? home + path.dropFirst() : project.path + "/" + path
        let url = URL(fileURLWithPath: full).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return (lo..<hi, url, numbers.first)
    }

    /// The character of a row's text under cell `column`, given the row's cell widths (SwiftTerm's
    /// TerminalVisibleRowSnapshot: 2 then 0 for a wide character, which is one character of text).
    static func character(atColumn column: Int, cellWidths: [Int]) -> Int {
        var n = 0
        for c in 0..<min(column, cellWidths.count) where !(c > 0 && cellWidths[c] == 0 && cellWidths[c - 1] == 2) { n += 1 }
        return n
    }
}

/// Text typed into an agent as one paste (V6 "Send to claude · dperp").
enum BracketedPaste {
    /// The bytes to send: wrapped in ESC[200~ … ESC[201~ when the program turned bracketed paste on.
    /// Control characters other than tab and newline become spaces, so the text cannot end the paste
    /// early or drive the program. nil when the text has several lines and the program reads keys
    /// one by one: each newline would submit a line.
    static func bytes(_ text: String, bracketed: Bool) -> [UInt8]? {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{1b}[201~", with: "")
        guard bracketed || !t.contains("\n") else { return nil }
        var clean = String.UnicodeScalarView()
        for s in t.unicodeScalars {
            let v = s.value
            clean.append(v == 9 || v == 10 || (v >= 32 && v != 127 && !(0x80...0x9f).contains(v)) ? s : " ")
        }
        let body = Array(String(clean).utf8)
        return bracketed ? Array("\u{1b}[200~".utf8) + body + Array("\u{1b}[201~".utf8) : body
    }
}
