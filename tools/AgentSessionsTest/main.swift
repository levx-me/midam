// Checks the agent-tab logic: launch command lines and id validation, writing sessions from
// transcript names, process matching, running agents, ⌘-click paths, paste bytes. Run:
// swiftc Sources/Midam/Library.swift Sources/Midam/AgentSessions.swift tools/AgentSessionsTest/main.swift -o /tmp/agentsessions && /tmp/agentsessions
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    .appendingPathComponent("agentsessions-test-\(UUID().uuidString)")
defer { try? fm.removeItem(at: root) }
let project = root.appendingPathComponent("dperp")
func touch(_ rel: String, in base: URL = project) {
    let url = base.appendingPathComponent(rel)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("# x\n".utf8).write(to: url)
}

// MARK: Session ids and launch argv

let uuid = "0b9c6a1e-3f2d-4c55-9e7a-1a2b3c4d5e6f"
assert(WritingSession.isValidID(uuid) && WritingSession.isValidID("abcDEF012"))
for bad in ["", "-rf", "--help", "a b", "a;rm -rf ~", "$(id)", "a'b", "x\ny", "é", String(repeating: "a", count: 129)] {
    assert(!WritingSession.isValidID(bad), bad)
}
assert(AgentLaunch(agent: .claude, project: project, sessionID: "$(touch /tmp/pwned)") == nil) // never reaches a command line
assert(AgentLaunch(agent: .codex, project: project, sessionID: "--dangerously-bypass") == nil)

let claude = AgentLaunch(agent: .claude, project: project, sessionID: uuid)!
assert(claude.argv(shell: "/bin/zsh") == ["/bin/zsh", "-l", "-i", "-c", "exec 'claude' '--resume' '\(uuid)'"])
assert(AgentLaunch(agent: .codex, project: project, sessionID: uuid)!.argv(shell: "/bin/bash")
       == ["/bin/bash", "-l", "-i", "-c", "exec 'codex' 'resume' '\(uuid)'"])
assert(AgentLaunch(agent: .cursor, project: project, sessionID: uuid)!.words == ["cursor-agent", "--resume=\(uuid)"])
assert(AgentLaunch(agent: .cursor, project: project)!.argv(shell: "/opt/homebrew/bin/fish").last == "exec 'cursor-agent'")
assert(AgentLaunch(agent: .claude, project: URL(fileURLWithPath: "/Users/me/it's here"))!.shellCommand
       == #"cd '/Users/me/it'\''s here' && 'claude'"#)
// The quoting survives a real shell: the word comes back unchanged.
let odd = #"it's "$HOME" `id` \n; *"#
let echoed = Process()
echoed.executableURL = URL(fileURLWithPath: "/bin/sh")
echoed.arguments = ["-c", "printf %s " + LoginShell.quote(odd)]
let pipe = Pipe()
echoed.standardOutput = pipe
try! echoed.run()
echoed.waitUntilExit()
assert(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == odd)

let env = AgentLaunch.environment(["HOME": "/Users/me", "TERM": "dumb", "CLAUDECODE": "1", "LANG": ""])
assert(env == ["COLORTERM=truecolor", "HOME=/Users/me", "LANG=en_US.UTF-8", "TERM=xterm-256color"])
assert(AgentLaunch.environment(["LANG": "ko_KR.UTF-8"]).contains("LANG=ko_KR.UTF-8"))

let tabState = TerminalTabState(agent: .claude, project: project, sessionID: uuid)
assert(tabState.launch == claude && tabState.title == "claude · dperp")
let stored = try! JSONDecoder().decode(TerminalTabState.self, from: Data(#"{"agent":"codex","project":"file:///w/x/","sessionID":"$(id)"}"#.utf8))
assert(stored.title == "codex · x" && stored.launch == nil) // a tampered state never runs

// MARK: Writing sessions from transcript and rollout names

let slug = "/Users/me/.claude/projects/-Users-me-work-dperp"
assert(WritingSession.claude(transcript: "\(slug)/\(uuid).jsonl", cwd: "/Users/me/work/dperp")
       == WritingSession(agent: .claude, id: uuid, cwd: "/Users/me/work/dperp"))
assert(WritingSession.claude(transcript: "\(slug)/\(uuid)/subagents/agent-a1b2c3.jsonl", cwd: "/w")?.id == uuid) // the parent session
assert(WritingSession.claude(transcript: "\(slug)/\(uuid).jsonl", cwd: nil) == nil)                              // no cwd: cannot resume
assert(WritingSession.claude(transcript: "\(slug)/-weird name.jsonl", cwd: "/w") == nil)
let rollout = "/Users/me/.codex/sessions/2026/10/28/rollout-2026-10-28T03-27-11-01a17e9d-c4a1-7772-8e7e-ff5d567a09ee.jsonl"
assert(WritingSession.codex(rollout: rollout, cwd: "/w") == WritingSession(agent: .codex, id: "01a17e9d-c4a1-7772-8e7e-ff5d567a09ee", cwd: "/w"))
assert(WritingSession.codex(rollout: "/x/rollout-1.jsonl", cwd: "/w") == nil)

// The scan carries the session to the document; a cache from before the field still reads.
let home = root.appendingPathComponent("home").path
let repo = home + "/work/dperp"
try! fm.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
touch("docs/plan.md", in: URL(fileURLWithPath: repo))
let transcript = home + "/.claude/projects/-work-dperp/\(uuid).jsonl"
try! fm.createDirectory(atPath: (transcript as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! (#"{"type":"assistant","cwd":"\#(repo)","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"docs/plan.md"}}]}}"# + "\n")
    .write(toFile: transcript, atomically: true, encoding: .utf8)
let scan = LibraryScanner(env: ScanEnv(home: home, excluded: [], now: Date()))
let docs = scan.docs(scan.claudeHits(transcript), known: [:])
assert(docs.count == 1 && docs[0].session == WritingSession(agent: .claude, id: uuid, cwd: repo))
let cacheURL = root.appendingPathComponent("library.plist")
LibraryCache(infos: docs, agents: FoundAgents(claudeProjects: 1, codexSessions: 0), marks: scan.marks).write(cacheURL)
assert(LibraryCache.read(cacheURL)?.infos.first?.session?.id == uuid)
struct OldInfo: Codable { let id, project: String; let variants: [DocVariant]; let modified: Date; let title, folder: String
    let fixedKind: DocKind?; let ruleKind: DocKind; let modelKey: String?; let excerpt: String; let deleted: Bool }
let old = OldInfo(id: "/a.md", project: "/", variants: [], modified: Date(), title: "a", folder: "", fixedKind: nil,
                  ruleKind: .other, modelKey: nil, excerpt: "", deleted: false)
let decoded = try! PropertyListDecoder().decode(DocInfo.self, from: PropertyListEncoder().encode(old))
assert(decoded.id == "/a.md" && decoded.session == nil)

// MARK: Installed agents and process matching

assert(Agent.found(in: "Welcome back!\n/Users/me/.nvm/versions/node/v24/bin/claude\n/opt/homebrew/bin/cursor-agent\nclaude: aliased\n")
       == [.claude, .cursor])
assert(Agent.found(in: "") == [])
assert(Agent.of(name: "claude", path: "/Users/me/.local/share/claude/versions/2.1.3", argv: ["claude", "--resume", uuid]) == .claude)
assert(Agent.of(name: "claude.exe", path: "/x/claude-code/bin/claude.exe", argv: []) == .claude)
assert(Agent.of(name: "node", path: "/usr/local/bin/node", argv: ["node", "/x/lib/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claude)
assert(Agent.of(name: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex"]) == .codex)
assert(Agent.of(name: "node", path: "/Users/me/.local/share/cursor-agent/versions/1/node", argv: ["node", "/Users/me/.local/share/cursor-agent/versions/1/index.js"]) == .cursor)
assert(Agent.of(name: "node", path: "/usr/local/bin/node", argv: ["node", "/srv/app/main.ts"]) == nil)
assert(Agent.of(name: "zsh", path: "/bin/zsh", argv: ["zsh", "-c", "claude"]) == nil)

// Running agents: a `claude` (a copy of sleep) in a subfolder counts; one started by this process
// (as Midam's own tabs are) and one in another folder do not.
let bin = root.appendingPathComponent("bin")
try! fm.createDirectory(at: bin, withIntermediateDirectories: true)
let sub = project.appendingPathComponent("docs")
let elsewhere = root.appendingPathComponent("elsewhere")
try! fm.createDirectory(at: sub, withIntermediateDirectories: true)
try! fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
func detached(_ cmd: String) { // the shell exits at once, so launchd adopts a job it puts in the background
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    try! p.run()
    p.waitUntilExit()
}
for name in ["claude", "codex"] { // a copied system binary must be signed again to run
    detached("cp /bin/sleep \(LoginShell.quote(bin.path + "/" + name)) && codesign -f -s - \(LoginShell.quote(bin.path + "/" + name)) 2>/dev/null")
}
detached("cd \(LoginShell.quote(sub.path)) && \(LoginShell.quote(bin.path + "/claude")) 30 >/dev/null 2>&1 &")
detached("cd \(LoginShell.quote(elsewhere.path)) && \(LoginShell.quote(bin.path + "/codex")) 30 >/dev/null 2>&1 &")
let child = Process()
child.executableURL = bin.appendingPathComponent("codex")
child.arguments = ["30"]
child.currentDirectoryURL = project
try! child.run()
defer { detached("pkill -f \(LoginShell.quote(bin.path))"); child.terminate() }
var seen: [Agent] = []
for _ in 0..<50 where seen.isEmpty {
    seen = runningAgents(in: project)
    if seen.isEmpty { usleep(100_000) }
}
assert(seen == [.claude], "\(seen)")
assert(runningAgents(in: root.appendingPathComponent("nothing")) == [])

// MARK: ⌘-click paths

touch("docs/plan.md")
touch("README.markdown")
touch("docs/한글 노트.md")
touch("docs/folder.md/inner.md")
let abs = project.appendingPathComponent("docs/plan.md").path
func links(_ line: String) -> [String] {
    TerminalLinks.find(in: line, project: project, home: root.path).map { l in
        "\(line[l.range])→\(l.url.path.replacingOccurrences(of: project.path, with: "P"))\(l.line.map { "@\($0)" } ?? "")"
    }
}
assert(links("Wrote docs/plan.md") == ["docs/plan.md→P/docs/plan.md"])
assert(links("see ./docs/plan.md:40 and docs/plan.md:40:3.") == ["./docs/plan.md:40→P/docs/plan.md@40", "docs/plan.md:40:3→P/docs/plan.md@40"])
assert(links("`docs/plan.md`, (README.markdown)") == ["docs/plan.md→P/docs/plan.md", "README.markdown→P/README.markdown"])
assert(links("open \(abs):7") == ["\(abs):7→P/docs/plan.md@7"])
assert(links("~/dperp/docs/plan.md") == ["~/dperp/docs/plan.md→P/docs/plan.md"])
touch("https:/example.com/notes.md") // so the URL below would also name an existing file
assert(links("https://example.com/notes.md https://example.com/docs/plan.md file://\(abs)") == []) // URLs are not paths
assert(links("docs/missing.md docs/plan.txt docs/folder.md docs/plan.md:x") == [])
assert(links("docs/plan.md:") == ["docs/plan.md→P/docs/plan.md"])
assert(links("") == [] && links("   ") == [])
// A Korean line: the path after wide characters is still found, and the column maps to it.
let korean = "작성함 docs/plan.md"
assert(links(korean) == ["docs/plan.md→P/docs/plan.md"])
let widths = [2, 0, 2, 0, 2, 0, 1] + Array(repeating: 1, count: 12) // 작성함, space, docs/plan.md
let at = TerminalLinks.character(atColumn: 7, cellWidths: widths)
assert(at == 4 && korean[korean.index(korean.startIndex, offsetBy: at)] == "d")
assert(TerminalLinks.character(atColumn: 0, cellWidths: widths) == 0)
assert(TerminalLinks.character(atColumn: 3, cellWidths: widths) == 2) // the second half of 성 is 성
assert(TerminalLinks.character(atColumn: 99, cellWidths: [1, 1]) == 2)

// MARK: Paste bytes

func s(_ b: [UInt8]?) -> String? { b.map { String(decoding: $0, as: UTF8.self) } }
assert(s(BracketedPaste.bytes("hi\r\nthere", bracketed: true)) == "\u{1b}[200~hi\nthere\u{1b}[201~")
assert(s(BracketedPaste.bytes("a\u{1b}[201~rm -rf ~\n\u{1b}[200~", bracketed: true)) == "\u{1b}[200~arm -rf ~\n [200~\u{1b}[201~") // cannot end the paste early
assert(s(BracketedPaste.bytes("tab\there\u{07}\u{03}\u{9b}31m 메모", bracketed: true)) == "\u{1b}[200~tab\there  " + " 31m 메모\u{1b}[201~")
assert(BracketedPaste.bytes("two\nlines", bracketed: false) == nil)
assert(s(BracketedPaste.bytes("one line", bracketed: false)) == "one line")

print("agent sessions: ok")
