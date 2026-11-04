// Run: swiftc Sources/Midam/ChatParse.swift Sources/Midam/Team.swift tools/TeamTest/main.swift -o /tmp/teamtest && /tmp/teamtest
import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-test-\(UUID().uuidString)")
let sessionDir = root.appendingPathComponent("sess"), subs = sessionDir.appendingPathComponent("subagents")
try! FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
let mainFile = root.appendingPathComponent("sess.jsonl")
defer { try? FileManager.default.removeItem(at: root) }

func ts(_ s: Int) -> String { String(format: "2026-11-05T10:%02d:%02d.000Z", s / 60, s % 60) }
func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
func use(_ t: Int, _ id: String, _ name: String, _ input: [String: Any]) -> String {
    json(["type": "assistant", "timestamp": ts(t), "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
}
func result(_ t: Int, _ id: String, error: Bool = false, extra: [String: Any]? = nil) -> String {
    var o: [String: Any] = ["type": "user", "timestamp": ts(t),
        "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "x", "is_error": error]]]]
    if let extra { o["toolUseResult"] = extra }
    return json(o)
}
func note(_ t: Int, _ agent: String, _ status: String) -> String {
    json(["type": "queue-operation", "timestamp": ts(t), "content": "<task-notification>\n<task-id>\(agent)</task-id>\n<status>\(status)</status>\n</task-notification>"])
}
func meta(_ agent: String, _ type: String, _ desc: String, _ toolUse: String, finished: Bool = false) {
    let o: [String: Any] = ["agentType": type, "description": desc, "toolUseId": toolUse, "spawnDepth": 1, "finished": finished]
    try! json(o).write(to: subs.appendingPathComponent("agent-\(agent).meta.json"), atomically: true, encoding: .utf8)
}
func append(_ file: URL, _ lines: [String]) {
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try! data.write(to: file) }
}
func sub(_ a: String) -> URL { subs.appendingPathComponent("agent-\(a).jsonl") }
func find(_ n: TeamNode, _ id: String) -> TeamNode? {
    n.id == id ? n : n.children.lazy.compactMap { find($0, id) }.first
}
nonisolated(unsafe) var checks = 0
func expect<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    checks += 1
    if a != b { print("FAIL \(what): got \(a), want \(b)"); exit(1) }
}

// main spawns the PM (sync) and a background scout; the PM spawns a builder and a checker (checker fails)
append(mainFile, [
    use(0, "tPM", "Agent", ["subagent_type": "wanjang:wanjang", "description": "Run the build", "prompt": "Build it\nmore"]),
    use(1, "tSC", "Agent", ["subagent_type": "wanjang:scout", "description": "Look up docs", "run_in_background": true, "prompt": "p"]),
    result(2, "tSC", extra: ["isAsync": true, "status": "async_launched", "agentId": "aSC"]),
])
meta("aPM", "wanjang:wanjang", "Run the build", "tPM")
meta("aSC", "wanjang:scout", "Look up docs", "tSC")
meta("aB", "wanjang:builder", "Write plan", "tB")
meta("aC", "wanjang:checker", "Check it", "tC")
append(sub("aPM"), [
    use(3, "tB", "Agent", ["subagent_type": "wanjang:builder", "description": "Write plan", "prompt": "p"]),
    use(4, "tC", "Agent", ["subagent_type": "wanjang:checker", "description": "Check it", "prompt": "p"]),
])
append(sub("aB"), [use(5, "w1", "Write", ["file_path": "/p/docs/plan.md", "content": "x"])])
append(sub("aC"), [use(6, "r1", "Read", ["file_path": "/p/Sources/App.swift"])])
append(sub("aSC"), [use(7, "ws", "WebSearch", ["query": "q"])])

let reader = TeamReader(transcript: mainFile)
var tree = reader.refresh()
let now = Date(timeIntervalSince1970: 0)
expect(tree.role, "Team lead", "root role")
expect(tree.children.map(\.id), ["aPM", "aSC"], "root children")
expect(find(tree, "aPM")?.role, "Team lead", "PM role")
expect(find(tree, "aPM")?.children.map(\.id), ["aB", "aC"], "grandchildren under PM")
expect(find(tree, "aB")?.role, "Builder", "builder role")
expect(find(tree, "aB")?.doing, "Writing a document… plan.md", "builder doing")
expect(find(tree, "aC")?.doing, "Reading…", "checker doing")
expect(find(tree, "aSC")?.doing, "Looking things up…", "background agent doing")
expect(find(tree, "aSC")?.state, .working, "background agent still working")
expect(find(tree, "aB")?.elapsed(now: tree.started!.addingTimeInterval(63)), 60, "elapsed = now - started")

// checker fails, background agent finishes later (notification), builder's result arrives
append(sub("aPM"), [result(8, "tC", error: true), result(9, "tB", extra: ["status": "completed", "agentId": "aB"])])
append(mainFile, [note(20, "aSC", "completed")])
tree = reader.refresh()
expect(find(tree, "aC")?.state, .failed, "failed subagent")
expect(find(tree, "aB")?.state, .done, "sync result marks done")
expect(find(tree, "aB")?.doing, "Write plan", "done node shows its description")
expect(find(tree, "aB")?.elapsed(now: now), 6, "elapsed uses end time (spawn 3s -> result 9s)")
expect(find(tree, "aSC")?.state, .done, "background agent done after notification")
expect(find(tree, "aSC")?.elapsed(now: now), 19, "background elapsed: spawn 1s -> notification 20s")

// a blocked agent: waiting on AskUserQuestion with no answer yet
meta("aQ", "wanjang:designer", "Pick a look", "tQ")
append(sub("aPM"), [use(10, "tQ", "Agent", ["subagent_type": "wanjang:designer", "description": "Pick a look", "prompt": "p"])])
append(sub("aQ"), [use(11, "q1", "AskUserQuestion", ["questions": []])])
tree = reader.refresh()
expect(find(tree, "aQ")?.state, .blocked, "blocked on a question")
expect(find(tree, "aQ")?.doing, "Waiting for you", "blocked wording")
expect(find(tree, "aQ")?.role, "Designer", "designer role")
append(sub("aQ"), [result(12, "q1"), use(13, "e1", "Edit", ["file_path": "/p/a.css"])])
tree = reader.refresh()
expect(find(tree, "aQ")?.state, .working, "answered question unblocks")

// incremental: a half-written line is kept back until it is complete
let half = use(14, "g1", "Grep", ["pattern": "x"])
let h = try! FileHandle(forWritingTo: sub("aQ")); h.seekToEndOfFile()
h.write(Data(half.prefix(20).utf8)); try? h.close()
expect(reader.refresh().children.count, 2, "partial line does not break the read")
expect(find(reader.refresh(), "aQ")?.doing, "Changing the app…", "partial line ignored")
let h2 = try! FileHandle(forWritingTo: sub("aQ")); h2.seekToEndOfFile()
h2.write(Data((half.dropFirst(20) + "\n").utf8)); try? h2.close()
expect(find(reader.refresh(), "aQ")?.doing, "Reading…", "completed line read")

// run log: labels a generic agent and marks it done
meta("a1b2c3d4e5f6a7b8", "general-purpose", "Odd job", "tG")
append(sub("aPM"), [use(15, "tG", "Agent", ["subagent_type": "general-purpose", "description": "Odd job", "prompt": "p"])])
append(sub("a1b2c3d4e5f6a7b8"), [use(16, "x", "Bash", ["command": "swift test"])])
let log = root.appendingPathComponent("log.md")
try! "| # | task | worker / model | owns | status | result |\n|---|---|---|---|---|---|\n| 9 | Test it | tester opus (a1b2c3d4e5f6a7b8) | tests | done | ok |\n".write(to: log, atomically: true, encoding: .utf8)
tree = TeamReader(transcript: mainFile, runLog: log).refresh()
expect(find(tree, "a1b2c3d4e5f6a7b8")?.role, "Tester", "run log labels a generic agent")
expect(find(tree, "a1b2c3d4e5f6a7b8")?.state, .done, "run log marks done")
expect(TeamReader(transcript: mainFile).refresh().children.count, 2, "fresh reader reads the same tree")
expect(find(TeamReader(transcript: mainFile, words: .ko).refresh(), "aB")?.role, "개발자", "ko words")

print("team: \(checks) checks passed")
