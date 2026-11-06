// Checks the library rules: what counts as written, projects, kinds, language pairs, unread, order. Run:
// swiftc Sources/Midam/Library.swift Sources/Midam/Projects.swift tools/LibraryTest/main.swift -o /tmp/library && /tmp/library
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    .appendingPathComponent("library-test-\(UUID().uuidString)").path
defer { try? fm.removeItem(atPath: root) }
let home = root + "/home"
let now = Date()

func write(_ path: String, _ text: String, age: TimeInterval = 0) {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
}
func tool(_ name: String, _ path: String, cwd: String) -> String {
    #"{"type":"assistant","cwd":"\#(cwd)","message":{"content":[{"type":"tool_use","name":"\#(name)","input":{"file_path":"\#(path)"}}]}}"#
}

// A repo, its worktree, a file outside any repo, a memory file, a ~/.claude rules file.
let repo = home + "/work/app", wt = home + "/work/app-wt", other = home + "/elsewhere/app"
try! fm.createDirectory(atPath: repo + "/.git/worktrees/wt", withIntermediateDirectories: true)
try! fm.createDirectory(atPath: other + "/.git", withIntermediateDirectories: true)
write(wt + "/.git", "gitdir: \(repo)/.git/worktrees/wt\n")
write(repo + "/docs/v1-spec.md", "---\ntitle: x\n---\n# Version one\n")
write(repo + "/docs/notes.md", "---\nkind: ops\n---\n# Release checklist plan\n")
write(repo + "/ENCYCLOPEDIA.md", "# PRD · 명세 · 계획\n")
write(repo + "/x.md", "```\n# not a title\n```\n# Hello\n## 인사\n")
write(repo + "/x.ko.md", "# 안녕\n")
write(repo + "/research/2026.md", "# Numbers\n")
write(repo + "/readonly.md", "# Read only\n")
write(wt + "/docs/deep/a/b/c/handoff.md", "# Hand over\n")
write(home + "/wiki/page.md", "# 배포 순서\n")
write(home + "/.claude/rules/report-design.md", "# Report and Dashboard Design\n")
write(home + "/.claude/projects/-work-app/memory/facts.md", "# Facts\n")
write(home + "/scratchpad/s.md", "# Scratch\n")
write(other + "/old.md", "# Old\n")
write(other + "/README.md", "# Other app\n", age: 3600)

let t1 = home + "/.claude/projects/-work-app/s1.jsonl"
write(t1, [
    #"{"type":"user","cwd":"\#(repo)"}"#,
    tool("Write", repo + "/docs/v1-spec.md", cwd: repo),
    tool("Edit", repo + "/docs/notes.md", cwd: repo),
    tool("Read", repo + "/readonly.md", cwd: repo),
    #"{"type":"tool_use" broken .md" line"#,
    tool("Write", repo + "/ENCYCLOPEDIA.md", cwd: repo),
    tool("Write", repo + "/x.md", cwd: repo),
    tool("MultiEdit", repo + "/x.ko.md", cwd: repo),
    tool("Write", repo + "/research/2026.md", cwd: repo),
    tool("Write", wt + "/docs/deep/a/b/c/handoff.md", cwd: wt),
    tool("Write", home + "/wiki/page.md", cwd: repo),
    tool("Write", home + "/.claude/rules/report-design.md", cwd: repo),
    tool("Write", home + "/.claude/projects/-work-app/memory/facts.md", cwd: repo),
    tool("Write", home + "/scratchpad/s.md", cwd: repo),
    tool("Write", repo + "/gone.md", cwd: repo),
    tool("Write", repo + "/was-here.md", cwd: repo),
].joined(separator: "\n") + "\n")
// A session started in a folder since moved into `repo`: it belongs to repo (the latest cwd).
let moved = home + "/.claude/projects/-moved-app/m.jsonl"
write(moved, [#"{"type":"user","cwd":"/moved/app"}"#, tool("Write", repo + "/docs/MANUAL.md", cwd: repo),
           #"{"type":"user","cwd":"\#(home)/.claude/projects/-moved-app/m/subagents"}"#].joined(separator: "\n") + "\n", age: 3_600)
let t2 = home + "/.claude/projects/-elsewhere-app/old.jsonl"
write(t2, tool("Write", other + "/old.md", cwd: other) + "\n", age: 8 * 86_400)
// Codex: a session in `other` that ran from 2 h ago to 30 min ago; README changed then, old.md now.
let ts = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
let c1 = home + "/.codex/sessions/2026/11/04/rollout-1.jsonl"
write(c1, [
    #"{"timestamp":"\#(now.addingTimeInterval(-7200).formatted(ts))","type":"session_meta","payload":{"cwd":"\#(other)"}}"#,
    #"{"timestamp":"\#(now.addingTimeInterval(-1800).formatted(ts))","type":"event"}"#,
].joined(separator: "\n") + "\n")

let env = ScanEnv(home: home, excluded: ["/private/tmp/never/", "scratchpad"], now: now)
let scan = LibraryScanner(env: env)

// Sources: registered projects only, any age.
assert(scan.claudeTranscripts(registered: []).isEmpty)
assert(scan.claudeTranscripts(registered: [repo]) == [t1, moved]) // moved by its latest cwd
assert(scan.claudeTranscripts(registered: [repo, other]) == [t1, moved, t2]) // the 8-day-old one counts too
assert(scan.codexSessions(registered: [other]) == [c1] && scan.codexSessions(registered: [repo]).isEmpty)
let claude = scan.claudeHits(t1)
let codex = scan.codexHits(c1)
assert(!claude.contains { $0.path.hasSuffix("readonly.md") })     // Read does not count
assert(!claude.contains { $0.path.contains("scratchpad") })       // excluded
assert(claude.count == 12)                                        // broken line skipped, the rest kept
assert(codex.map(\.path) == [other + "/README.md"])               // changed during the session only

// Projects.
func project(_ suffix: String) -> String? { (claude + codex).first { $0.path.hasSuffix(suffix) }?.project }
assert(project("handoff.md") == repo)                             // worktree → main repo
assert(project("wiki/page.md") == repo)                           // outside any repo → writing session's project
assert(project("report-design.md") == repo)                       // ~/.claude is never a repo
assert(project("memory/facts.md") == repo)
assert(project("README.md") == other)

// Incremental: read once with a line still being written and no cwd yet, then appended to. The
// next scan reads only the new bytes and finds what a full read finds (the late cwd applies to
// the earlier relative path too); unchanged, it reads nothing; rewritten shorter, it reads all.
let t3 = home + "/.claude/projects/-work-app/s3.jsonl"
let noCwd = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"docs/notes.md"}}]}}"#
let late = tool("Edit", repo + "/x.md", cwd: repo), next = tool("Write", "research/2026.md", cwd: repo)
write(t3, noCwd + "\n" + late)                                    // the last line whole but not yet ended
let s0 = LibraryScanner(env: env), s0b = LibraryScanner(env: env)
assert(s0.claudeHits(t3).map(\.path) == [repo + "/docs/notes.md", repo + "/x.md"])
s0b.previous = s0.marks
assert(s0b.claudeHits(t3).map(\.path) == [repo + "/docs/notes.md", repo + "/x.md"])
write(t3, noCwd + "\n" + late.prefix(40))
let s1 = LibraryScanner(env: env)
assert(s1.claudeHits(t3).isEmpty && s1.marks.transcripts[t3]?.offset == noCwd.utf8.count + 1) // no cwd: nothing yet
let h = FileHandle(forWritingAtPath: t3)!
h.seekToEndOfFile()
h.write(Data((late.dropFirst(40) + "\n" + next + "\n").utf8))
h.closeFile()
let s2 = LibraryScanner(env: env)
s2.previous = s1.marks
let incremental = s2.claudeHits(t3), full = LibraryScanner(env: env).claudeHits(t3)
assert(incremental == full && full.map(\.path) == [repo + "/docs/notes.md", repo + "/x.md", repo + "/research/2026.md"])
assert(s2.marks.transcripts[t3]?.offset == LibraryScanner.stamp(t3)?.size)
let s3 = LibraryScanner(env: env)
s3.previous = s2.marks
assert(s3.claudeHits(t3) == full && s3.marks == s2.marks)       // unchanged: the marks as they were
write(t3, late + "\n", age: -5)
let s4 = LibraryScanner(env: env)
s4.previous = s2.marks
assert(s4.claudeHits(t3) == LibraryScanner(env: env).claudeHits(t3) && s4.claudeHits(t3).map(\.path) == [repo + "/x.md"])
let s5 = LibraryScanner(env: env)
s5.previous = s4.marks
assert(s5.codexSession(c1) == scan.codexSession(c1) && s5.marks.sessions[c1]?.run != nil)
try! fm.removeItem(atPath: t3)

// The cache file: read back as written; corrupt or another version is ignored.
let cacheURL = URL(fileURLWithPath: root + "/support/Midam/library.plist")
LibraryCache(infos: [], agents: FoundAgents(claudeProjects: 1, codexSessions: 2), marks: s2.marks).write(cacheURL)
assert(LibraryCache.read(cacheURL)?.marks == s2.marks && LibraryCache.read(cacheURL)?.agents.codexSessions == 2)
var older = LibraryCache(infos: [], agents: FoundAgents(claudeProjects: 0, codexSessions: 0), marks: ScanMarks())
older.version = 0
older.write(cacheURL)
assert(LibraryCache.read(cacheURL) == nil)
try! Data("not a plist".utf8).write(to: cacheURL)
assert(LibraryCache.read(cacheURL) == nil)

// Deleted: gone.md was never seen, was-here.md was.
let wasHere = repo + "/was-here.md"
let known = [wasHere: KnownDoc(title: "Was here", modified: now.addingTimeInterval(-60), kind: .plan)]
let infos = scan.docs(claude + codex, known: known)
func info(_ suffix: String) -> DocInfo { infos.first { $0.id.hasSuffix(suffix) }! }
assert(!infos.contains { $0.id.hasSuffix("gone.md") })
assert(info("was-here.md").deleted && info("was-here.md").title == "Was here")
LibraryCache(infos: infos, agents: FoundAgents(claudeProjects: 1, codexSessions: 1), marks: ScanMarks()).write(cacheURL)
assert(LibraryCache.read(cacheURL)?.infos == infos.map { var i = $0; i.excerpt = ""; return i }) // dates exact: unread is decided the same
assert(LibraryCache.read(cacheURL)!.infos.allSatisfy { $0.excerpt.isEmpty }) // no document text in the cache

// Kinds without a model answer.
var state = LibraryState(known: known)
func kind(_ suffix: String) -> DocKind { Library.kind(info(suffix), state: state) }
assert(kind("v1-spec.md") == .design)
assert(kind("docs/notes.md") == .ops)                             // frontmatter wins
assert(kind("ENCYCLOPEDIA.md") == .guide)                         // file name beats "PRD · 명세 · 계획"
assert(kind("report-design.md") == .notes)                        // location beats file name
assert(kind("memory/facts.md") == .memory)
assert(kind("research/2026.md") == .research)                     // folder convention
assert(kind("wiki/page.md") == .ops)                              // Korean heading word
assert(kind("handoff.md") == .handoff)
assert(kind("README.md") == .guide)
assert(Library.ruleKind(stem: "deploy-plan", relDir: "", title: "", headings: []) == .plan)
assert(Library.ruleKind(stem: "notes", relDir: "", title: "Benchmark of parsers", headings: []) == .research)
assert(Library.ruleKind(stem: "x", relDir: "", title: "Hello", headings: []) == .other)
// The model only sees docs no fixed rule decided, and its cached answer beats the rules.
let pending = Library.pendingModel(infos, state: state)
assert(pending.contains { $0.id.hasSuffix("v1-spec.md") } && !pending.contains { $0.id.hasSuffix("docs/notes.md") })
state.modelKinds[info("v1-spec.md").modelKey!] = "plan"
assert(kind("v1-spec.md") == .plan)
state.overrides[info("v1-spec.md").id] = .research
assert(kind("v1-spec.md") == .research)                           // the user's choice beats everything
state = LibraryState(known: known)

// Language pair: one doc, base first, title from the base, code fence skipped.
let x = info("/x.md")
assert(x.variants.map(\.lang) == [nil, "ko"] && Library.langLabel(x.variants) == "EN · KO" && x.title == "Hello")
assert(Library.split("/a/b.zh-CN.md") == ("/a/b.md", "zh-CN"))
assert(Library.split("/a/v1.0.md").lang == nil && Library.split("/a/config.zzz.md").lang == nil)

// Folder line.
assert(info("v1-spec.md").folder == "")                           // docs/ dropped
assert(info("handoff.md").folder == "~/…/c")                      // worktree path is outside the main root
assert(Library.folderLine(dir: repo + "/docs/a/b/c/d", root: repo, home: home) == "a/…/d")
assert(info("report-design.md").folder == "~/.claude/rules")

// Unread: never opened, opened after the change, changed after the open.
let spec = info("v1-spec.md")
assert(Library.unread(spec.variants, modified: spec.modified, opened: [:]))
assert(!Library.unread(spec.variants, modified: spec.modified, opened: [spec.id: spec.modified.addingTimeInterval(5)]))
assert(Library.unread(spec.variants, modified: spec.modified, opened: [spec.id: spec.modified.addingTimeInterval(-5)]))
assert(!Library.unread(x.variants, modified: x.modified, opened: [repo + "/x.ko.md": now.addingTimeInterval(5)])) // any variant

// Grouping and order.
var projects = Library.projects(infos, state: state)
assert(projects.map(\.id) == [repo, other])                       // never read: by last change
let app = projects[0]
assert(app.groups.map(\.kind) == [.design, .plan, .research, .ops, .guide, .handoff, .memory, .notes, .other])
assert(app.docCount == 10 && app.unread == 9)                     // the deleted doc is not unread
assert(app.groups.first { $0.kind == .ops }!.docs.count == 2)
assert(projects[0].parent == "work" && projects[1].parent == "elsewhere") // two projects named "app"
state.opened[other + "/README.md"] = now
projects = Library.projects(infos, state: state)
assert(projects.map(\.id) == [other, repo])                       // last read first
assert(projects[0].unread == 0)
// First run: everything found is read as of now; a later change is unread.
var fresh = LibraryState()
fresh.opened = Library.baseline(infos)
let seen = Library.projects(infos, state: fresh)
assert(seen.allSatisfy { $0.unread == 0 })
let later = infos[0]
assert(Library.unread(later.variants, modified: later.modified.addingTimeInterval(60), opened: fresh.opened))
state.opened[repo + "/x.md"] = now.addingTimeInterval(10)
assert(Library.projects(infos, state: state).map(\.id) == [repo, other]) // read again later: first
state.dismissed = [wasHere]
assert(Library.projects(infos, state: state).first { $0.id == repo }!.docCount == 9) // dismissed deleted doc hidden
assert(Library.known(infos, state: state)[wasHere] == nil)

// Sections and pins: pinned ones in the user's order leave All; new pins go to the bottom.
let a = "/p/a", b = "/p/b", c = "/p/c", d = "/p/d"
func proj(_ id: String, _ docs: [LibraryDoc] = []) -> LibraryProject {
    LibraryProject(id: id, name: id, parent: nil, groups: docs.isEmpty ? [] : [KindGroup(kind: .plan, docs: docs, unread: docs.filter(\.unread).count)],
                   docCount: docs.count, unread: docs.filter(\.unread).count, lastModified: now)
}
let four = [a, b, c, d].map { proj($0) }
var pins = Library.pin(c, in: [])
pins = Library.pin(a, in: pins)
assert(pins == [c, a] && Library.pin(a, in: pins) == [c, a])     // bottom; pinning again changes nothing
let parts = Library.sections(four, pinned: pins + ["/gone"])
assert(parts.pinned.map(\.id) == [c, a] && parts.all.map(\.id) == [b, d]) // All keeps its order; unknown ids skipped
assert(Library.pin(a, onto: c, in: [c, a]) == [a, c])             // moving up: before the target
assert(Library.pin(c, onto: a, in: [c, a, b]) == [a, c, b])       // moving down: after the target
assert(Library.pin(d, onto: a, in: [c, a, b]) == [c, d, a, b])    // a new pin dropped on a row: before it
assert(Library.pin(a, onto: a, in: [c, a]) == [c, a])
let listed = Set([a, b, c, d])
assert(Library.movePinned(a, by: -1, in: [c, a], listed: listed) == [a, c] && Library.movePinned(c, by: -1, in: [c, a], listed: listed) == [c, a])
assert(Library.movePinned(a, by: -1, in: [c, "/gone", a], listed: listed) == [a, "/gone", c]) // past a pin not listed now
assert(Library.sections(four, pinned: Library.movePinned(a, by: -1, in: pins, listed: listed)).pinned.map(\.id) == [a, c])

// Unread filter: a doc read while it is on keeps its row until it is turned off and on again.
func doc(_ id: String, _ title: String, unread: Bool, path: String? = nil) -> LibraryDoc {
    LibraryDoc(id: id, variants: [DocVariant(lang: nil, path: path ?? id)], langLabel: nil, title: title, folder: "",
               modified: now, kind: .plan, deleted: false, unread: unread)
}
var tree = [proj(a, [doc("/p/a/1.md", "One", unread: true), doc("/p/a/2.md", "Two", unread: false)]), proj(b, [doc("/p/b/3.md", "Three", unread: false)])]
let kept = Library.unreadIds(tree)                                 // turned on
assert(Library.unreadFilter(tree, kept: kept).map(\.id) == [a])  // empty projects go
assert(Library.unreadFilter(tree, kept: kept)[0].groups[0].docs.map(\.id) == ["/p/a/1.md"])
tree[0].groups[0].docs[0].unread = false                           // read while on
tree[1].groups[0].docs[0].unread = true                            // a new change arrives
assert(Library.unreadFilter(tree, kept: kept).map(\.id) == [a, b]) // the read one stays, the new one joins
assert(Library.unreadFilter(tree, kept: kept)[0].unread == 0)       // its dot is gone
assert(Library.unreadFilter(tree, kept: Library.unreadIds(tree)).map(\.id) == [b]) // off and on: gone
assert(Library.groupKeys([tree[0]]) == [a, a + "\u{1F}plan"])

// Search: title and file name, case and accents ignored; content only gives a snippet.
assert(Library.match("one", title: "One", name: "1.md") { nil } == DocMatch(title: true))
assert(Library.match("1.MD", title: "One", name: "1.md") { nil } == DocMatch(name: true))
assert(Library.match("cafe", title: "Café notes", name: "x.md") { nil }?.title == true)
assert(Library.match("zzz", title: "One", name: "1.md") { "nothing here" } == nil)
let body = "# Title\n\nIntro line.\n- The **deploy** step runs after the build finishes and the tests pass on every platform we ship\n"
let hit = Library.match("deploy", title: "Title", name: "t.md") { body }
assert(hit?.title == false && hit?.snippet?.hasPrefix("The **deploy** step") == true && hit?.snippet?.hasSuffix("…") == true)
assert(Library.snippet("platform", in: body)!.hasPrefix("…") && Library.snippet("platform", in: body)!.contains("platform"))
assert(Library.ranges(of: "o", in: "foo boo").count == 4 && Library.ranges(of: "  ", in: "a b").isEmpty)
assert(Library.terms(#"deploy  "test plan" run"#) == ["deploy", "test plan", "run"])            // words, a quoted phrase whole
assert(Library.match("plan deploy", title: "Deploy plan", name: "x.md", text: { nil }) != nil)  // any order
assert(Library.match("deploy runbook", title: "Deploy", name: "x.md", text: { "the runbook here" })?.snippet?.contains("runbook") == true) // rest from the text
assert(Library.match("deploy missing", title: "Deploy", name: "x.md", text: { "nothing" }) == nil) // every term must occur
assert(Library.match(#""plan deploy""#, title: "Deploy plan", name: "x.md", text: { nil }) == nil) // a phrase keeps its order
write(root + "/s/1.md", "# One\nThe secret word is lantern.\n")
var sdoc = doc(root + "/s/1.md", "One", unread: false)
let texts = DocTexts()
let found = await texts.search("LANTERN", in: [sdoc])
assert(found[sdoc.id]?.snippet == "The secret word is lantern.")
write(root + "/s/1.md", "# One\nNow it says candle.\n", age: -5)  // a newer mtime: read again
let stale = await texts.search("lantern", in: [sdoc]), renewed = await texts.search("candle", in: [sdoc])
assert(stale.isEmpty && renewed.count == 1)
sdoc.deleted = true
let none = await texts.search("candle", in: [sdoc])
assert(none.isEmpty)                                               // a deleted doc has no text

// Add Project: every project in any agent's history, with its documents on disk.
let cands = scan.candidates()
let old = cands.first { $0.agent == .claude && $0.root == other }!
assert(old.sources == [t2] && cands.contains { $0.agent == .claude && $0.root == repo } && cands.contains { $0.agent == .codex && $0.root == other })
assert(scan.docCount(old) == 1)                                    // old.md
assert(scan.docCount(cands.first { $0.agent == .claude && $0.root == repo }!) >= 9)

// Session → docs: every session that wrote a doc keeps it, newest first.
let sa = WritingSession(agent: .claude, id: "sa", cwd: repo), sb = WritingSession(agent: .claude, id: "sb", cwd: repo)
write(repo + "/s1.md", "# S1\n", age: 100)
write(repo + "/s2.md", "# S2\n", age: 50)
let multi = LibraryScanner(env: env).docs([Hit(path: repo + "/s1.md", project: repo, session: sa), Hit(path: repo + "/s2.md", project: repo, session: sa),
                                           Hit(path: repo + "/s1.md", project: repo, session: sb)], known: [:])
assert(Library.docs(ofSession: "sa", in: multi).map(\.id) == [repo + "/s2.md", repo + "/s1.md"])
assert(Library.docs(ofSession: "sb", in: multi).map(\.id) == [repo + "/s1.md"] && Library.docs(ofSession: "zz", in: multi).isEmpty)
assert(multi.first { $0.id == repo + "/s1.md" }!.session == sa)    // the doc's own session is still the newest

// Registry: migration and membership.
assert(Registry.migrate(added: ["/a"], pinned: ["/b", "/h"], hidden: ["/h", "/x"]) == ["/a", "/b"])
assert(Registry.contains(repo + "/docs/x.md", in: [repo]) && !Registry.contains(repo + "-wt/x.md", in: [repo]) && !Registry.contains("/", in: []))

// Recent sessions: topic is the ai-title, else the first real prompt; cut lines are skipped.
let user = #"{"type":"user","cwd":"/w/app","message":{"role":"user","content":"Fix the parser\nthen more"}}"#
let meta = #"{"type":"user","isMeta":true,"cwd":"/w/app","message":{"role":"user","content":"caveat"}}"#
let cmd = #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#
let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#
let partsLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Parts prompt"}]}}"#
let title = #"{"type":"ai-title","aiTitle":"Parser fixes"}"#
assert(RecentSessions.parse([meta, cmd, toolResult, user, title].joined(separator: "\n")) == ("/w/app", "Parser fixes"))
assert(RecentSessions.parse([meta, cmd, toolResult, user].joined(separator: "\n")) == ("/w/app", "Fix the parser"))
assert(RecentSessions.parse([user, toolResult, partsLine].joined(separator: "\n") + "\n{\"type\":\"ai-ti") == ("/w/app", "Fix the parser"))
assert(RecentSessions.parse([toolResult, partsLine].joined(separator: "\n")).1 == "Parts prompt")
let uid = "11111111-2222-3333-4444-555555555555", uid2 = "11111111-2222-3333-4444-666666666666"
write(home + "/.claude/projects/-w-app/\(uid).jsonl", [user, title].joined(separator: "\n") + "\n", age: 10)
write(home + "/.claude/projects/-w-app/\(uid2).jsonl", user + "\n", age: 5)
let recent = RecentSessions.load(home: home)
let mine = recent.filter { $0.projectRoot == "/w/app" }
assert(mine.map(\.sessionID) == [uid2, uid] && mine.map(\.topic) == ["Fix the parser", "Parser fixes"] && mine[0].projectName == "app")
assert(RecentSessions.load(home: home, limit: 1).count == 1 && recent.map(\.lastActive) == recent.map(\.lastActive).sorted(by: >))
assert(mine[1].matches("PARSER app") && mine[1].matches("") && !mine[1].matches("parser zzz"))
assert(RecentSession(agent: .claude, sessionID: "s", projectRoot: "/w/café", topic: "x", lastActive: now).matches("cafe"))

// New project: name rules, the folder is made as a repository, an existing one is refused.
let h2 = root + "/home2"
for bad in ["", "  ", "a/b", ".hidden", String(repeating: "x", count: 101)] {
    do { _ = try Projects.create(name: bad, home: h2); assertionFailure("accepted \(bad)") } catch { assert(error as? ProjectError == .invalidName) }
}
assert(!fm.fileExists(atPath: h2))                                 // refused names touch nothing
let made = try! Projects.create(name: " demo ", home: h2)
assert(made.path == h2 + "/workspace/demo" && fm.fileExists(atPath: made.path + "/.git"))
do { _ = try Projects.create(name: "demo", home: h2); assertionFailure("exists") } catch { assert(error as? ProjectError == .exists) }
let conv = AgentConversation(root: made.path)
assert(try! JSONDecoder().decode(AgentConversation.self, from: JSONEncoder().encode(conv)) == conv)

// A session that moved folders belongs to the latest cwd.
assert(RecentSessions.parse(["{\"type\":\"user\",\"cwd\":\"/w/old\",\"message\":{\"content\":\"Hi\"}}", "{\"type\":\"user\",\"cwd\":\"/w/new\",\"message\":{\"content\":\"Again\"}}"].joined(separator: "\n")) == ("/w/new", "Hi"))

print("library rules: checks passed")
