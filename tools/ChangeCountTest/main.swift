// Checks that JavaScriptCore runs the page's diff (marked, markdown.js, changes.js from Resources)
// and gives the counts tools/changes-test.js expects. Run from the repo root:
// swiftc Sources/Midam/ChangeCount.swift tools/ChangeCountTest/main.swift -o /tmp/cc && /tmp/cc
import Foundation
import JavaScriptCore

let ctx = ChangeCount.context(resources: URL(fileURLWithPath: "Resources"))!
let base = "# Title\n\nIntro paragraph with several words here.\n\n- apple\n- banana\n- cherry\n\n## Setup\n\nRun the installer and wait.\n\nFinal words.\n"
let count = { (old: String, new: String) in ChangeCount.count(old: old, new: new, in: ctx) }

assert(count(base, base) == 0)
assert(count(base, base.replacingOccurrences(of: "Intro paragraph with", with: "Intro   paragraph\nwith")) == 0) // whitespace only
assert(count(base, base.replacingOccurrences(of: "and wait.", with: "and wait patiently.")) == 1)
assert(count(base, base.replacingOccurrences(of: "several", with: "many").replacingOccurrences(of: "Final", with: "Last")) == 2)
assert(count("", base) == 1 && count(base, "") == 1)
assert(count("---\ntitle: a\n---\n캐시 무효화를 같은 PR에서 처리해요.\n", "---\ntitle: b\n---\n캐시 무효화를 같은 PR에서 처리해요.\n") == 1)
assert(count("a\r\nb\r\n", "a\nb\n") == 0)

// A failed call leaves no exception behind for the next one.
ctx.evaluateScript("var saved = midamDiff; midamDiff = () => { throw new Error('x') };")
assert(count(base, "") == 0)
ctx.evaluateScript("midamDiff = saved;")
assert(count(base, "") == 1)

// Missing scripts: no context; outside an app bundle the async count is 0, not a crash.
assert(ChangeCount.context(resources: URL(fileURLWithPath: "/nonexistent")) == nil)
let outside = await ChangeCount.count(old: base, new: "")
assert(outside == 0)

// Speed: a 5,000-line document with a few edits.
let big = (0..<1250).map { "## Section \($0)\n\nParagraph \($0) says something about item \($0).\n" }.joined(separator: "\n")
let edited = big.replacingOccurrences(of: "Paragraph 10 says", with: "Paragraph 10 now says").replacingOccurrences(of: "## Section 1249", with: "## Last section")
_ = count(big, edited)
let t0 = Date()
assert(count(big, edited) == 2)
let ms = Date().timeIntervalSince(t0) * 1000
assert(ms < 400, "\(ms) ms") // no JIT here (see ChangeCount.anchored); the page takes ~10 ms
print("change count: checks passed (5,000 lines in \(Int(ms)) ms)")
