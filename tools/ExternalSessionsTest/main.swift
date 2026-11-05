// Checks the external sessions' rules: project matching (equal, inside, sibling prefix, nested
// owner), the 7-day window, managed sessions left out, newest first, the running rule, and the
// scan's mtime cache over synthetic transcripts in a temp home. Run from the repo root:
// swiftc Sources/Midam/Library.swift Sources/Midam/Projects.swift Sources/Midam/ExternalSessions.swift tools/ExternalSessionsTest/main.swift -o /tmp/extsessions && /tmp/extsessions
import Foundation

// Project matching.
assert(ExternalSessions.inProject("/a/b", root: "/a/b"))
assert(ExternalSessions.inProject("/a/b/c/d", root: "/a/b"))
assert(ExternalSessions.inProject("/a/b/c", root: "/a/b/"))
assert(!ExternalSessions.inProject("/a/bc", root: "/a/b")) // a sibling with the same prefix
assert(!ExternalSessions.inProject("/a", root: "/a/b"))
assert(ExternalSessions.owner(of: "/a/b/c", roots: ["/a", "/a/b", "/x"]) == "/a/b") // the deepest
assert(ExternalSessions.owner(of: "/a/bc", roots: ["/a/b"]) == nil)

// Visible: window, managed, nested, order.
let now = Date(timeIntervalSince1970: 2_000_000_000), day = 86_400.0
func s(_ id: String, _ cwd: String, _ age: TimeInterval) -> RecentSession {
    RecentSession(agent: .claude, sessionID: id, projectRoot: cwd, topic: "t" + id, lastActive: now.addingTimeInterval(-age))
}
let all = [s("old", "/a", 7 * day + 1), s("edge", "/a", 7 * day), s("new", "/a/x", 10), s("mid", "/a", day),
           s("mine", "/a", 5), s("sib", "/ab", 5), s("inner", "/a/b/c", 5), s("future", "/a", -3)]
let shown = ExternalSessions.visible(root: "/a", roots: ["/a", "/a/b"], all: all, managed: ["mine"], now: now)
assert(shown.map(\.sessionID) == ["future", "new", "mid", "edge"], "\(shown.map(\.sessionID))") // newest first; not capped
assert(ExternalSessions.visible(root: "/a/b", roots: ["/a", "/a/b"], all: all, managed: [], now: now).map(\.sessionID) == ["inner"])
let many = (0..<40).map { s("m\($0)", "/a", Double($0)) }
assert(ExternalSessions.visible(root: "/a", roots: ["/a"], all: many, managed: [], now: now).count == 40)
let dup = [s("same", "/a", 9), s("same", "/a", 3)]
assert(Set(ExternalSessions.visible(root: "/a", roots: ["/a"], all: dup, managed: ["same"], now: now)).isEmpty)

// Running: within 120 s.
assert(ExternalSessions.running(lastActive: now.addingTimeInterval(-119), now: now))
assert(ExternalSessions.running(lastActive: now.addingTimeInterval(-120), now: now))
assert(!ExternalSessions.running(lastActive: now.addingTimeInterval(-121), now: now))

// Scan with the cache, over a temp home.
let home = NSTemporaryDirectory() + "extsessions-" + UUID().uuidString
let dir = home + "/.claude/projects/-a"
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func write(_ id: String, cwd: String, at date: Date) {
    let path = dir + "/" + id + ".jsonl"
    let line = #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":"hello \#(id)"}}"# + "\n"
    try! line.write(toFile: path, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}
let real = Date()
let (a, b, c) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased(), UUID().uuidString.lowercased())
write(a, cwd: "/p/one", at: real.addingTimeInterval(-60))
write(b, cwd: "/p/two", at: real.addingTimeInterval(-3600))
write(c, cwd: "/p/old", at: real.addingTimeInterval(-8 * day)) // outside the window: never read
var reads: [String] = [], cache: [String: ExternalSessions.Cached] = [:]
let since = real.addingTimeInterval(-7 * day)
func scan() -> [RecentSession] {
    ExternalSessions.scan(home: home, since: since, cache: &cache) { reads.append(($0 as NSString).lastPathComponent); return RecentSessions.read($0) }
}
var found = scan()
assert(found.map(\.sessionID) == [a, b], "\(found.map(\.sessionID))")
assert(found.map(\.projectRoot) == ["/p/one", "/p/two"] && found[0].topic == "hello " + a)
assert(reads.count == 2 && !reads.contains(c + ".jsonl"), "\(reads)")
found = scan()
assert(reads.count == 2, "an unchanged file is not read again") // second scan: cache hit
assert(found.map(\.sessionID) == [a, b])
write(b, cwd: "/p/two", at: real.addingTimeInterval(-30)) // changed: read again, now newest
found = scan()
assert(reads.count == 3 && reads.last == b + ".jsonl")
assert(found.map(\.sessionID) == [b, a])
try! FileManager.default.removeItem(atPath: dir + "/" + a + ".jsonl")
found = scan()
assert(found.map(\.sessionID) == [b] && cache.count == 1, "a deleted file leaves the cache")
try? FileManager.default.removeItem(atPath: home)
print("ExternalSessionsTest ok")
