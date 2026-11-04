// Checks the V6 reply: Markdown format, draft store, midam:// parsing, delivery to a waiting CLI,
// the CLI installer, and that the `midam` script computes the same document key as the app. Run
// from the repo root:
// swiftc Sources/Midam/Baseline.swift Sources/Midam/Reply.swift Sources/Midam/ReviewRequest.swift Sources/Midam/CLIInstaller.swift tools/ReplyTest/main.swift -o /tmp/reply && /tmp/reply
import Foundation

let fm = FileManager.default
let scratch = URL(fileURLWithPath: DocKey.path(NSTemporaryDirectory())).appendingPathComponent("midam-rt-\(UUID().uuidString.prefix(8))")
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }
let root = scratch.path
func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>" }

// MARK: Markdown

let en = ReplyWords(title: "Review", approve: "Approve", changes: "Request changes")
let ko = ReplyWords(title: "검토", approve: "승인", changes: "변경 요청")
func note(_ s: Int, _ e: Int, _ quote: String, _ text: String, at t: Double = 0, path: String = "/p/docs/plan.md") -> Note {
    Note(quote: quote, path: path, start: s, end: e, text: text, created: Date(timeIntervalSince1970: t))
}

// The spec's example, in Korean.
var r = Reply(notes: [note(40, 52, "캐시 무효화를 같은 PR에서 처리해요", "캐시 무효화는 다음 단계로 미뤄 주세요.")], verdict: .changes)
assert(r.markdown(path: "/p/docs/plan.md", root: "/p", words: ko) == """
## docs/plan.md 검토: 변경 요청

1. `docs/plan.md:L40-L52`
   > 캐시 무효화를 같은 PR에서 처리해요
   캐시 무효화는 다음 단계로 미뤄 주세요.

""")

// Single-line range, English words, summary, document order (start, then created), no root = file name.
r = Reply(notes: [note(40, 44, "b", "second", at: 2), note(40, 52, "a", "first", at: 1), note(7, 7, "c", "top", at: 9)],
          verdict: .approve, summary: "  Looks good overall.  ")
let md = r.markdown(path: "/p/docs/plan.md", words: en)
assert(md == """
## plan.md Review: Approve

Looks good overall.

1. `plan.md:L7`
   > c
   top

2. `plan.md:L40-L52`
   > a
   first

3. `plan.md:L40-L44`
   > b
   second

""", md)

// No verdict, empty summary: heading only plus notes; no notes: heading only.
assert(Reply().markdown(path: "/p/a.md", words: en) == "## a.md Review\n")
r = Reply(notes: [note(1, 1, "q", "t")])
assert(r.markdown(path: "/p/a.md", words: en).hasPrefix("## a.md Review\n\n1. `plan.md:L1`"))

// An empty note (no words, or only spaces) is left out, and the numbering skips it.
r = Reply(notes: [note(1, 1, "q", "  \n"), note(2, 2, "r", "t")])
assert(r.markdown(path: "/p/a.md", words: en) == "## a.md Review\n\n1. `plan.md:L2`\n   > r\n   t\n")

// Send needs words, a summary or a verdict: empty notes alone are nothing to send.
assert(!Reply().canSend && !Reply(notes: [note(1, 1, "q", " \n")], summary: "  ").canSend)
assert(Reply(notes: [note(1, 1, "q", "t")]).canSend && Reply(summary: "s").canSend && Reply(verdict: .approve).canSend)

// Multi-line quote and text keep their lines, indented; blank quote lines stay a bare ">".
r = Reply(notes: [note(3, 6, "line one\n\nline three", "why\nbecause")], verdict: .changes)
assert(r.markdown(path: "/p/a.md", words: en) == """
## a.md Review: Request changes

1. `plan.md:L3-L6`
   > line one
   >
   > line three
   why
   because

""")

// Long quotes are cut at about 200 characters with an ellipsis; short ones are untouched.
let long = String(repeating: "가", count: 450)
let cut = Reply(notes: [note(1, 2, long, "x")]).markdown(path: "/p/a.md", words: en)
assert(cut.contains("> " + String(repeating: "가", count: 200) + "…\n"))
assert(!cut.contains(String(repeating: "가", count: 201)))

// A note in another file inside the root shows its relative path; outside the root, its name.
r = Reply(notes: [note(1, 1, "q", "t", path: "/p/docs/other/x.md"), note(2, 2, "q", "t", path: "/elsewhere/y.md")])
let paths = r.markdown(path: "/p/docs/plan.md", root: "/p", words: en)
assert(paths.contains("`docs/other/x.md:L1`") && paths.contains("`y.md:L2`"))
assert(Reply.display("/pp/a.md", root: "/p") == "a.md") // "/p" must not match "/pp"

// MARK: Store

let store = scratch.appendingPathComponent("Replies")
let docPath = scratch.appendingPathComponent("my doc 한글 & more.md").path
try "# doc\n".write(toFile: docPath, atomically: true, encoding: .utf8)
assert(ReplyStore.load(docPath, in: store) == Reply())
let draft = Reply(notes: [note(5, 6, "q", "t", at: 100, path: docPath)], verdict: .changes, summary: "s")
try ReplyStore.save(draft, for: docPath, in: store)
assert(ReplyStore.load(docPath, in: store) == draft)
assert(fm.fileExists(atPath: store.appendingPathComponent(DocKey.hash(docPath) + ".json").path))
// Another path has its own draft; the document itself is untouched.
assert(ReplyStore.load(docPath + "x", in: store) == Reply())
assert(read(docPath) == "# doc\n")
// Corrupt file reads as an empty draft and can be saved over.
try "{ not json".write(to: ReplyStore.file(for: docPath, in: store), atomically: true, encoding: .utf8)
assert(ReplyStore.load(docPath, in: store) == Reply())
try ReplyStore.save(draft, for: docPath, in: store)
assert(ReplyStore.load(docPath, in: store) == draft)
ReplyStore.clear(docPath, in: store)
assert(ReplyStore.load(docPath, in: store) == Reply())
assert(!fm.fileExists(atPath: ReplyStore.file(for: docPath, in: store).path))
// Saving an empty draft removes the file.
try ReplyStore.save(draft, for: docPath, in: store)
try ReplyStore.save(Reply(), for: docPath, in: store)
assert(!fm.fileExists(atPath: ReplyStore.file(for: docPath, in: store).path))

// A symlinked document shares its target's draft (the key is the realpath).
let linkPath = scratch.appendingPathComponent("link.md").path
try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: docPath)
assert(DocKey.hash(linkPath) == DocKey.hash(docPath))

// MARK: URL parsing

func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
func url(_ host: String, _ q: [(String, String)], scheme: String = "midam") -> URL {
    URL(string: "\(scheme)://\(host)?" + q.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&"))!
}
let roots = [root]
func parse(_ u: URL) -> Result<ReviewRequest, ReviewError> { ReviewRequest.parse(u, tempRoots: roots) }
func fails(_ u: URL, _ e: ReviewError, _ line: Int = #line) {
    if case .failure(let got) = parse(u) { assert(got == e, "line \(line): \(got) != \(e)") } else { assertionFailure("line \(line): accepted \(u)") }
}
let real = DocKey.path(docPath)

// open
assert(parse(url("open", [("path", docPath)])) == .success(.open(path: real, line: nil)))
assert(parse(url("open", [("path", docPath), ("line", "40")])) == .success(.open(path: real, line: 40)))
assert(parse(url("OPEN", [("path", docPath)], scheme: "MIDAM")) == .success(.open(path: real, line: nil)))
fails(url("open", [("path", docPath), ("line", "0")]), .line)
fails(url("open", [("path", docPath), ("line", "-3")]), .line)
fails(url("open", [("path", docPath), ("line", "+3")]), .line)
fails(url("open", [("path", docPath), ("line", "3x")]), .line)
fails(url("open", [("path", docPath), ("line", "")]), .line)
fails(url("open", [("path", docPath), ("line", "99999999999999999999")]), .line)
fails(url("open", []), .path)
fails(URL(string: "midam://open")!, .path)
fails(url("open", [("line", "3")]), .path)
fails(url("open", [("path", "docs/plan.md")]), .path)
fails(url("open", [("path", "")]), .path)
fails(url("open", [("path", scratch.appendingPathComponent("nope.md").path)]), .notFound)
fails(url("open", [("path", scratch.path + ".md")]), .notFound)
fails(url("open", [("path", "/etc/hosts")]), .notMarkdown)
fails(url("open", [("path", docPath), ("path", docPath)]), .query)
fails(url("delete", [("path", docPath)]), .action)
fails(url("open", [("path", docPath)], scheme: "https"), .scheme)
// A directory named like a document is not a document.
let dirMd = scratch.appendingPathComponent("dir.md")
try fm.createDirectory(at: dirMd, withIntermediateDirectories: true)
fails(url("open", [("path", dirMd.path)]), .notFound)

// review: the CLI's dir, `<root>/midam-review.XXXXXX`, mode 700, ours.
func reviewDir(_ name: String = "midam-review.abc123", mode: mode_t = 0o700) throws -> String {
    let d = scratch.appendingPathComponent(name).path
    try fm.createDirectory(atPath: d, withIntermediateDirectories: false, attributes: [.posixPermissions: Int(mode)])
    return d
}
let dir = try reviewDir()
let replyFile = dir + "/reply.md"
assert(parse(url("review", [("path", docPath)])) == .success(.review(path: real, reply: nil)))
assert(parse(url("review", [("path", docPath), ("reply", replyFile)])) == .success(.review(path: real, reply: URL(fileURLWithPath: replyFile))))
// Same directory reached through a symlinked parent resolves to the real one.
let viaParent = scratch.appendingPathComponent("up")
try fm.createSymbolicLink(atPath: viaParent.path, withDestinationPath: root)
assert(parse(url("review", [("path", docPath), ("reply", viaParent.path + "/midam-review.abc123/reply.md")])) == .success(.review(path: real, reply: URL(fileURLWithPath: replyFile))))

func replyFails(_ reply: String, _ e: ReviewError = .reply, tempRoots: [String]? = nil, _ line: Int = #line) {
    let u = url("review", [("path", docPath), ("reply", reply)])
    if case .failure(let got) = ReviewRequest.parse(u, tempRoots: tempRoots ?? roots) { assert(got == e, "line \(line): \(got) != \(e)") }
    else { assertionFailure("line \(line): accepted \(reply)") }
}
replyFails("relative/midam-review.abc123/reply.md")
replyFails("\(root)/midam-review.abc123/../../etc/reply.md")
replyFails("\(root)/midam-review.abc123/../midam-review.abc123/reply.md")
replyFails("/tmp/midam-review.x/../../etc/reply.md")
replyFails("\(dir)/other.md")
replyFails("\(dir)/sub/reply.md")
replyFails("\(root)/reply.md")
replyFails("\(root)/notreview.abc123/reply.md")
replyFails("\(root)/midam-review./reply.md")
replyFails("\(root)/midam-review.a b/reply.md")
replyFails("\(root)/nested/midam-review.abc123/reply.md", .replyGone)
replyFails("\(root)/midam-review.gone42/reply.md", .replyGone)
replyFails(replyFile, tempRoots: [scratch.path + "/elsewhere"]) // a foreign temp dir
replyFails(replyFile, tempRoots: [])
// Symlinked review dir (even to a good one) and group-writable dir are refused.
try fm.createSymbolicLink(atPath: root + "/midam-review.link01", withDestinationPath: dir)
replyFails(root + "/midam-review.link01/reply.md")
let loose = try reviewDir("midam-review.loose1", mode: 0o770)
replyFails(loose + "/reply.md")
let other = try reviewDir("midam-review.other1", mode: 0o707)
replyFails(other + "/reply.md")
// A reply.md that is already a symlink is refused.
let bait = scratch.appendingPathComponent("bait.txt").path
try "keep".write(toFile: bait, atomically: true, encoding: .utf8)
let trap = try reviewDir("midam-review.trap01")
try fm.createSymbolicLink(atPath: trap + "/reply.md", withDestinationPath: bait)
replyFails(trap + "/reply.md")

// MARK: Delivery

let target = URL(fileURLWithPath: replyFile)
try ReviewRequest.deliver(reply: "## a.md Review: Approve\n", verdict: .approve, to: target, tempRoots: roots)
assert(read(dir + "/reply.md") == "## a.md Review: Approve\n")
assert(read(dir + "/verdict") == "approve")
assert(((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() == ["reply.md", "verdict"], "no temp files left")
// Again (a second send) replaces both.
try ReviewRequest.deliver(reply: "second", verdict: .changes, to: target, tempRoots: roots)
assert(read(dir + "/reply.md") == "second")
assert(read(dir + "/verdict") == "changes")
// A symlinked reply.md is never written through, and no verdict is written.
func deliverFails(_ file: String, _ e: ReviewError, tempRoots: [String]? = nil, _ line: Int = #line) {
    do {
        try ReviewRequest.deliver(reply: "x", verdict: .approve, to: URL(fileURLWithPath: file), tempRoots: tempRoots ?? roots)
        assertionFailure("line \(line): delivered to \(file)")
    } catch { assert(error as? ReviewError == e, "line \(line): \(error) != \(e)") }
}
deliverFails(trap + "/reply.md", .reply)
assert(read(bait) == "keep")
assert(!fm.fileExists(atPath: trap + "/verdict"))
// A verdict that is a symlink is refused too; reply.md was written, the symlink target is intact.
let trap2 = try reviewDir("midam-review.trap02")
try fm.createSymbolicLink(atPath: trap2 + "/verdict", withDestinationPath: bait)
deliverFails(trap2 + "/reply.md", .reply)
assert(read(bait) == "keep")
// Symlinked dir, foreign temp, and a dir that is gone (the CLI timed out): the last one is its own error.
deliverFails(root + "/midam-review.link01/reply.md", .reply)
deliverFails(replyFile, .reply, tempRoots: [scratch.path + "/elsewhere"])
try fm.removeItem(atPath: dir)
deliverFails(replyFile, .replyGone)

// MARK: Installer

let script = scratch.appendingPathComponent("Midam.app/Contents/Resources/midam")
try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
let bin = scratch.appendingPathComponent("home/.local/bin")
var res = try CLIInstaller.install(script: script, bin: bin, path: "/usr/bin:\(bin.path)")
assert(res.link == bin.appendingPathComponent("midam") && res.onPath)
assert((try? fm.destinationOfSymbolicLink(atPath: res.link.path)) == script.path)
res = try CLIInstaller.install(script: script, bin: bin, path: "/usr/bin") // again: idempotent
assert(!res.onPath)
// An older install from another copy of the app is replaced.
try fm.removeItem(at: res.link)
try fm.createSymbolicLink(atPath: res.link.path, withDestinationPath: "/Applications/Midam.app/Contents/Resources/midam")
_ = try CLIInstaller.install(script: script, bin: bin, path: "")
assert((try? fm.destinationOfSymbolicLink(atPath: res.link.path)) == script.path)
// Another tool's symlink or a regular file is never replaced.
try fm.removeItem(at: res.link)
try fm.createSymbolicLink(atPath: res.link.path, withDestinationPath: "/usr/local/bin/midam-other")
do { _ = try CLIInstaller.install(script: script, bin: bin, path: ""); assertionFailure("replaced a foreign link") } catch { assert(error as? CLIInstallError == .occupied("/usr/local/bin/midam-other")) }
try fm.removeItem(at: res.link)
try "mine".write(to: res.link, atomically: true, encoding: .utf8)
do { _ = try CLIInstaller.install(script: script, bin: bin, path: ""); assertionFailure("replaced a file") } catch { assert(error as? CLIInstallError == .occupied(res.link.path)) }
assert(read(res.link.path) == "mine")
do { _ = try CLIInstaller.install(script: scratch.appendingPathComponent("none"), bin: bin, path: ""); assertionFailure() } catch { assert(error as? CLIInstallError == .missingScript) }
assert(CLIInstaller.onPath("/a/b", in: "/x:/a/b/:/y") && !CLIInstaller.onPath("/a/b", in: "/a/bc:/a"))

// MARK: The script and the app agree on the document key

// Draft and baseline are filed under the app's key; `midam status` must find both for a path with
// spaces, non-ASCII and shell-special characters.
let support = scratch.appendingPathComponent("Support")
try fm.createDirectory(at: support.appendingPathComponent("Baselines"), withIntermediateDirectories: true)
try ReplyStore.save(Reply(notes: [note(1, 1, "q", "a", path: docPath), note(2, 2, "q", "b", path: docPath)], verdict: .changes),
                    for: docPath, in: support.appendingPathComponent("Replies"))
let baseline = support.appendingPathComponent("Baselines/" + DocKey.hash(docPath))
try "old".write(to: baseline, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: baseline.path)
let p = Process()
p.executableURL = URL(fileURLWithPath: "Resources/midam")
p.arguments = ["status", linkPath, "--json"] // through a symlink: same key as the target
p.environment = ["MIDAM_SUPPORT": support.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
let pipe = Pipe()
p.standardOutput = pipe
try p.run()
let outData = pipe.fileHandleForReading.readDataToEndOfFile()
p.waitUntilExit()
let status = try JSONSerialization.jsonObject(with: outData) as! [String: Any]
assert(p.terminationStatus == 0)
assert(status["path"] as? String == real && status["exists"] as? Bool == true, "\(status)")
assert(status["notes"] as? Int == 2 && status["verdict"] as? String == "changes", "\(status)")
assert(status["lastRead"] as? String == "2023-11-14T22:13:20Z", "\(status)")

print("ReplyTest: ok")
