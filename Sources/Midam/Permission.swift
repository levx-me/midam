import Foundation

/// Whether a conversation's tool use runs at once or waits for the person's OK. Work inside the
/// project runs; anything outside it, deleting, publishing, system installs, connected services
/// that change things and anything about money asks. `.ask` carries the card's one plain sentence
/// (an English source string, a Localizable.strings key; Korean in the comment beside each).
/// ponytail: a speed bump read off the command text, not a shell parser; the sandbox (D14) is what
/// actually keeps writes inside the project.
enum Permission: Equatable {
    case allow
    case ask(String)

    static let money = "It may cost money." // 비용이 들 수 있어요.
    static let delete = "It wants to delete files." // 파일을 지우려고 해요.
    static let publish = "It wants to publish or send your work online." // 작업을 인터넷에 올리거나 보내려고 해요.
    static let system = "It wants to install or change something on this Mac." // 이 Mac에 무언가를 설치하거나 바꾸려고 해요.
    static let outsideWrite = "It wants to change a file outside this project." // 이 프로젝트 밖의 파일을 바꾸려고 해요.
    static let outsideShell = "It wants to work with files outside this project." // 이 프로젝트 밖의 파일을 다루려고 해요.
    static let service = "It wants to use a connected service." // 연결된 서비스를 쓰려고 해요.

    /// The temporary folders writes may always go to: $TMPDIR and /tmp, resolved.
    static let temp = [real(NSTemporaryDirectory()), "/private/tmp"]
    /// Tools and devices commands may name and file tools may read.
    static let tools = ["/usr", "/bin", "/sbin", "/opt/homebrew", "/dev/null", "/dev/stdout", "/dev/stderr"]
    /// Inside the project, but what Claude Code or git run on their own next time (hooks,
    /// settings, MCP servers): changing them asks.
    static func runsOnItsOwn(_ path: String, root: String) -> Bool {
        guard inside(path, root) else { return false }
        let parts = path.dropFirst(root.count).split(separator: "/")
        return parts.contains { $0 == ".claude" || $0 == ".git" } || parts.last == ".mcp.json"
    }

    /// `reads`: folders outside the project the file tools may read without asking (the plugin,
    /// the CLI's saved tool output for this project).
    static func decide(tool: String, input: [String: Any], project: URL, temp: [String] = temp, reads: [String] = []) -> Permission {
        let root = real(project.path)
        // A project at the home folder or `/` has no inside: everything there asks.
        let roots = root == real(NSHomeDirectory()) || root == "/" ? [] : [root]
        if ChatParse.json(input).lowercased().range(of: #"stripe|billing|payment"#, options: .regularExpression) != nil {
            return .ask(money)
        }
        // Midam's settings forbid running outside the sandbox (allowUnsandboxedCommands); this asks too.
        if input["dangerouslyDisableSandbox"] as? Bool == true { return .ask(system) }
        switch tool {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let p = input["file_path"] as? String ?? input["notebook_path"] as? String else { return .allow }
            let r = resolve(p, in: root)
            if runsOnItsOwn(r, root: root) { return .ask(system) }
            return (roots + temp).contains { inside(r, $0) } ? .allow : .ask(outsideWrite)
        case "Bash", "Monitor":
            return shell(input["command"] as? String ?? "", root: root, inside: roots + tools + temp)
        default:
            if tool.hasPrefix("mcp__") {
                // The verb the tool's name starts with: get_x, listItems, search (not update_spreadsheet).
                let name = tool.components(separatedBy: "__").last ?? ""
                let read = #"^(?i:get|list|search|read|fetch|query|find|describe|view|show)([^a-z]|$)"#
                return name.range(of: read, options: .regularExpression) != nil ? .allow : .ask(service)
            }
            // Read, Glob, Grep, NotebookRead, LS: any path they name stays in the project.
            var paths = ["file_path", "notebook_path", "path"].compactMap { input[$0] as? String }
            if let g = input["pattern"] as? String, tool == "Glob" { paths.append(g) }
            let allowed = roots + temp + tools + reads
            for p in paths where !allowed.contains(where: { inside(resolve(p, in: root), $0) }) { return .ask(outsideShell) }
            return .allow
        }
    }

    /// `allowed`: the folders paths in the command may point into.
    private static func shell(_ command: String, root: String, inside allowed: [String]) -> Permission {
        let c = command.lowercased()
        func matches(_ pattern: String) -> Bool { c.range(of: pattern, options: .regularExpression) != nil }
        let words = Self.words(command)
        // git and its options before the subcommand (git -C . push).
        let git = #"\bgit(\s+-[cC]\s+\S+|\s+--?[\w.-]+(=\S+)?)*\s+"#
        if words.contains(where: { ["rm", "rmdir", "unlink", "shred", "-delete"].contains($0.lowercased()) })
            || matches(git + #"clean\b|"# + git + #"reset\s+[^;&|]*--hard|\bmv\b[^;&|>]*\s/dev/null\b"#) {
            return .ask(delete)
        }
        if matches(git + #"push\b|\b(npm|pnpm|yarn|cargo)\s+publish\b|\bgh\s+release\b|\bgh\s+pr\s+merge\b|\b(vercel|netlify|fly|flyctl|firebase)\b[^;&|]*\bdeploy\b|--prod\b"#) {
            return .ask(publish)
        }
        if words.contains("sudo") || matches(#"\bbrew\s+(install|reinstall|upgrade|uninstall|remove)\b"#)
            || matches(#"\b(npm|pnpm|yarn)\s+[^;&|]*(\s-g\b|--global\b)|\byarn\s+global\b"#)
            || matches(#"\b(curl|wget)\b[^;&]*\|\s*(sudo\s+)?(ba|z)?sh\b"#) {
            return .ask(system)
        }
        // No project to keep to (home or `/`), or a bare `cd`, which goes home.
        if !allowed.contains(root) || matches(#"(^|[;&|(]|\bthen|\bdo)\s*cd\s*($|[;&|)])"#) { return .ask(outsideShell) }
        let home = NSHomeDirectory()
        for w in words {
            let w = w.replacing(#/\$(HOME\b|\{HOME\})/#, with: home)
            // ~user is someone's home.
            if w.hasPrefix("~"), w != "~", !w.hasPrefix("~/") { return .ask(outsideShell) }
            // The word when it is a path (relative ones only for `..` or hooks and settings, taken
            // from the project), and paths inside it after =, a quote, a space, a parenthesis or a
            // comma (--out=/x, -c 'open("/x")').
            let parts = w.split(separator: "/")
            var paths = w.hasPrefix("/") || w.hasPrefix("~")
                || parts.contains { ["..", ".claude", ".git"].contains($0) } || parts.last == ".mcp.json" ? [w] : []
            paths += w.matches(of: #/[=\s"'(,](~|/)[^\s"'(),;:]*/#).map { String($0.output.0.dropFirst()) }
            for p in paths where !p.hasPrefix("//") {
                let r = resolve(p, in: root)
                if runsOnItsOwn(r, root: root) { return .ask(system) }
                if !allowed.contains(where: { inside(r, $0) }) { return .ask(outsideShell) }
            }
        }
        return .allow
    }

    /// The command's words with quotes removed (a quoted path keeps its spaces); operators,
    /// redirections and backticks split words.
    private static func words(_ command: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?
        for ch in command {
            if let q = quote {
                if ch == q { quote = nil } else { word.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if " \t\n;&|()<>`".contains(ch) {
                if !word.isEmpty { words.append(word); word = "" }
            } else {
                word.append(ch)
            }
        }
        return word.isEmpty ? words : words + [word]
    }

    static func inside(_ path: String, _ dir: String) -> Bool {
        path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// The real path `path` points to (relative to `base`, `~` = home): symlinks resolved through
    /// the deepest part that exists, the rest (a file about to be written) added lexically.
    static func resolve(_ path: String, in base: String) -> String {
        var p = path
        if p == "~" || p.hasPrefix("~/") { p = NSHomeDirectory() + p.dropFirst() }
        if !p.hasPrefix("/") { p = base + "/" + p }
        var head = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var tail: [String] = []
        while !head.isEmpty, realOrNil("/" + head.joined(separator: "/")) == nil { tail.insert(head.removeLast(), at: 0) }
        let start = realOrNil("/" + head.joined(separator: "/")) ?? "/"
        if tail.isEmpty { return start }
        return URL(fileURLWithPath: start).appendingPathComponent(tail.joined(separator: "/")).standardizedFileURL.path
    }

    static func real(_ path: String) -> String { realOrNil(path) ?? (path as NSString).standardizingPath }

    private static func realOrNil(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
