// Checks the source lines on rendered blocks (data-src, data-blk from Resources/markdown.js) and
// the block diff behind "N changes" (Resources/changes.js). Run: node tools/changes-test.js
const fs = require("fs"), path = require("path"), assert = require("assert"), R = path.join(__dirname, "../Resources/");
const { midamParse, midamBlocks, midamDiff } = new Function("marked", "katex", fs.readFileSync(R + "emoji.js", "utf8") +
  fs.readFileSync(R + "markdown.js", "utf8") + fs.readFileSync(R + "changes.js", "utf8") +
  "\nreturn { midamParse, midamBlocks, midamDiff };")(require(R + "marked.umd.js"), require(R + "katex.min.js"));
let n = 0;
const check = (name, fn) => { n++; try { fn(); } catch (e) { console.log("FAIL", name, "\n" + e.message); process.exitCode = 1; } };

// Tagged elements in document order: "tag src" or "tag src #blk".
const tags = md => [...midamParse(md, {}).matchAll(/<([a-z0-9]+)[^>]*? data-src="([^"]*)"(?: data-blk="(\d+)")?/g)]
  .map(m => m[1] + " " + m[2] + (m[3] === undefined ? "" : " #" + m[3]));

// MARK: Source lines, hand-counted.
check("front matter, heading, wrapped paragraph", () => assert.deepStrictEqual(
  tags("---\ntitle: x\n---\n# Head\n\nPara one\ncontinues\n"), ["table 1-3 #0", "h1 4-4 #1", "p 6-7 #2"]));
check("front matter shown as YAML code", () => assert.deepStrictEqual(
  tags("---\na:\n  b: c\n---\nbody"), ["pre 1-4 #0", "p 5-5 #1"]));
check("blank-line runs, leading blanks, no final newline", () => assert.deepStrictEqual(
  tags("\n\n# H\nA\n\n\n\nB"), ["h1 3-3 #0", "p 4-4 #1", "p 8-8 #2"]));
check("CRLF", () => assert.deepStrictEqual(tags("a\r\nb\r\n\r\n# H\r\n"), ["p 1-2 #0", "h1 4-4 #1"]));
check("CRLF front matter", () => assert.deepStrictEqual(tags("---\r\na: 1\r\n---\r\nbody\r\n"), ["table 1-3 #0", "p 4-4 #1"]));
check("tab-indented code", () => assert.deepStrictEqual(tags("\tcode\n\tmore\n\npara"), ["pre 1-2 #0", "p 4-4 #1"]));
check("setext headings", () => assert.deepStrictEqual(tags("Title\n=====\n\nSub\n---\ntext"), ["h1 1-2 #0", "h2 4-5 #1", "p 6-6 #2"]));
check("fence with blank lines", () => assert.deepStrictEqual(tags("```js\na\n\n\nb\n```\nafter"), ["pre 1-6 #0", "p 7-7 #1"]));
check("html block; a comment is no block", () => {
  assert.deepStrictEqual(tags("<div>\nx\n</div>\n\n<!-- note -->\n\npara"), ["div 1-3 #0", "p 7-7 #1"]);
  assert(midamParse("<!-- note -->\n\npara", {}).startsWith("<!-- note -->"));
});
check("table", () => assert.deepStrictEqual(tags("| a | b |\n|---|---|\n| 1 | 2 |\n\nx"), ["table 1-3 #0", "p 5-5 #1"]));
check("nested list: the list has lines only, each item its own block", () => assert.deepStrictEqual(
  tags("- a\n  - b\n  - c\n- d\n"), ["ul 1-4", "li 1-3 #0", "li 2-2 #1", "li 3-3 #2", "li 4-4 #3"]));
check("deeper nesting after a loose item", () => assert.deepStrictEqual(
  tags("* a\n\n    * b\n        * c\n* d"), ["ul 1-5", "li 1-4 #0", "li 3-4 #1", "li 4-4 #2", "li 5-5 #3"]));
check("loose ordered list", () => assert.deepStrictEqual(
  tags("1. one\n\n2. two\n   more\n\n   para\n3. three"), ["ol 1-7", "li 1-1 #0", "li 3-6 #1", "li 7-7 #2"]));
check("footnote definition: no block, its note has lines", () => {
  assert.deepStrictEqual(tags("Text[^1].\n\n[^1]: Note.\n\nAfter"), ["p 1-1 #0", "p 5-5 #1", "li 3-3"]);
  assert(midamParse("Text[^1].\n\n[^1]: Note.\n\nAfter", {}).includes('<li id="midam-fn-1" data-src="3-3">'));
});
check("reference definition is no block", () => assert.deepStrictEqual(
  tags("See [x].\n\n[x]: https://example.com\n\nEnd"), ["p 1-1 #0", "p 5-5 #1"]));
check("alert, math block, mermaid fence", () => assert.deepStrictEqual(
  tags("> [!NOTE]\n> body\n\n$$\nx^2\n$$\n\n```mermaid\ngraph TD\n```\n"), ["div 1-2 #0", "div 4-6 #1", "pre 8-10 #2"]));
check("blockquote holding a list is one block", () => assert.deepStrictEqual(tags("> - a\n> - b\n\nz"), ["blockquote 1-2 #0", "p 4-4 #1"]));

// data-blk n is midamBlocks(src)[n], from the block-only lexing.
const doc = "---\ntitle: T\n---\n# T\n\n- a\n  1. b\n- [x] c\n\n<p>raw</p>\n\n| h |\n|---|\n| v |\n\nX[^n]\n\n[^n]: note\n";
check("data-blk numbers midamBlocks", () => {
  const blocks = midamBlocks(doc), got = tags(doc).filter(t => t.includes("#"));
  assert.deepStrictEqual(got.map(t => t.split(" ").slice(1).join(" ")), blocks.map((b, i) => b.start + "-" + b.end + " #" + i));
  assert.deepStrictEqual(blocks.map(b => b.kind), ["frontMatter", "heading", "item", "item", "item", "html", "table", "paragraph"]);
  assert.deepStrictEqual(blocks.slice(2, 5).map(b => b.raw), ["a\n", "b", "[x] c"]); // own text: no marker, no nested list
});

// MARK: Diff.
const base = "# Title\n\nIntro paragraph with several words here.\n\n- apple\n- banana\n- cherry\n\n## Setup\n\nRun the installer and wait.\n\nFinal words.\n";
const ops = (o, b) => midamDiff(o, b).ops.map(x => x.op + (x.old === undefined ? "" : " " + x.old) + (x.new === undefined ? "" : ">" + x.new));
const same = k => Array.from({ length: k }, (_, i) => "same " + i + ">" + i);

check("no change", () => {
  const d = midamDiff(base, base);
  assert.deepStrictEqual([ops(base, base), d.places, d.count], [same(8), [], 0]);
});
check("one paragraph edited", () => {
  const d = midamDiff(base, base.replace("and wait.", "and wait patiently."));
  assert.deepStrictEqual(d.ops[6], { op: "changed", old: 6, new: 6 });
  assert.deepStrictEqual([d.places, d.count], [[[6]], 1]);
});
check("a block added", () => {
  const d = midamDiff(base, base.replace("here.\n", "here.\n\nA new paragraph.\n"));
  assert.deepStrictEqual(ops(base, base.replace("here.\n", "here.\n\nA new paragraph.\n")).slice(1, 4), ["same 1>1", "added>2", "same 2>3"]);
  assert.strictEqual(d.count, 1);
});
check("a block removed: first words, lines, in place", () => {
  const old = base.replace("Run the installer and wait.", "Run the **installer** and then wait for\nthe [download](https://example.com) to finish, then reboot.");
  const d = midamDiff(old, base.replace("Run the installer and wait.\n\n", ""));
  assert.deepStrictEqual(d.ops.map(o => o.op), ["same", "same", "same", "same", "same", "same", "removed", "same"]);
  const r = d.ops[6];
  assert.deepStrictEqual([r.old, r.firstWords, r.lines], [6, "Run the installer and then wait for the…", 2]);
  assert(r.raw.startsWith("Run the **installer**"));
  assert.strictEqual(d.count, 1);
});
check("a list item inserted mid-list", () => {
  assert.deepStrictEqual(ops(base, base.replace("- banana\n", "- banana\n- blueberry\n")).slice(2, 7),
    ["same 2>2", "same 3>3", "added>4", "same 4>5", "same 5>6"]);
});
check("an ordered list renumbered by an insert changes one place", () => {
  const d = midamDiff("1. one\n2. two\n3. three\n", "1. one\n2. new\n3. two\n4. three\n");
  assert.deepStrictEqual(d.ops.map(o => o.op), ["same", "added", "same", "same"]);
});
check("a heading renamed", () => {
  const d = midamDiff(base, base.replace("## Setup", "## Installation"));
  assert.deepStrictEqual([d.ops[5], d.count], [{ op: "changed", old: 5, new: 5 }, 1]);
});
check("a block moved: removed where it was, added where it is", () => {
  const moved = base.replace("\n\nFinal words.", "").replace("## Setup", "Final words.\n\n## Setup");
  assert.deepStrictEqual(ops(base, moved), [...same(5), "added>5", "same 5>6", "same 6>7", "removed 7"]);
  assert.strictEqual(midamDiff(base, moved).count, 2);
});
check("whitespace only is no change", () => {
  const ws = base.replace("Intro paragraph with", "Intro   paragraph\nwith").replace("# Title\n", "# Title  \n\n\n").replace("- banana", "-   banana");
  assert.deepStrictEqual([midamDiff(base, ws).count, ops(base, ws)], [0, same(8)]);
});
check("old empty: all added, one place", () => {
  const d = midamDiff("", base);
  assert.deepStrictEqual([d.ops.every(o => o.op === "added"), d.ops.length, d.count], [true, 8, 1]);
});
check("new empty: all removed, one place", () => {
  const d = midamDiff(base, "");
  assert.deepStrictEqual([d.ops.map(o => o.old), d.ops.every(o => o.op === "removed"), d.count], [[0, 1, 2, 3, 4, 5, 6, 7], true, 1]);
});
check("two separate edits are two places", () => {
  const d = midamDiff(base, base.replace("several", "many").replace("Final", "Last"));
  assert.deepStrictEqual([d.places, d.count], [[[1], [7]], 2]);
});
check("in one gap: a similar block is changed, an unlike one removed + added", () => {
  const o = "# A\n\nThe cache is cleared in this pull request.\n\n```\ncode\n```\n\n# B\n";
  const b = "# A\n\nThe cache is cleared in the next pull request.\n\nSomething else entirely.\n\n# B\n";
  assert.deepStrictEqual(ops(o, b), ["same 0>0", "changed 1>1", "removed 2", "added>2", "same 3>3"]);
});
check("Korean: an edited paragraph among others pairs up", () => {
  const o = "캐시 무효화를 같은 PR에서 처리해요.\n\n```\nx\n```\n", b = "캐시 무효화를 다음 PR에서 처리해요.\n\n완전히 새 문단이에요.\n";
  assert.deepStrictEqual(ops(o, b), ["changed 0>0", "removed 1", "added>1"]);
});

check("repeated blocks still match between edits at both ends", () => {
  assert.deepStrictEqual(ops("A\n\n- x\n- x\n- x\n\nZ", "B\n\n- x\n- x\n- x\n\nY"), ["changed 0>0", "same 1>1", "same 2>2", "same 3>3", "changed 4>4"]);
});

// MARK: Speed: a 5,000-line document.
const big = Array.from({ length: 1250 }, (_, i) => "## Section " + i + "\n\nParagraph " + i + " says something about item " + i + ".\n").join("\n");
check("5,000 lines", () => {
  assert(big.split("\n").length >= 5000);
  const edited = big.replace("Paragraph 10 says", "Paragraph 10 now says").replace("## Section 900\n", "## Section 900\n\nNew text.\n")
    .replace("Paragraph 600 says", "").replace("## Section 1249", "## Last section");
  const shuffled = big.split("\n\n").reverse().join("\n\n");
  for (const [name, other, places] of [["a few edits", edited, 4], ["every block moved", shuffled, null]]) {
    midamDiff(big, other); // warm up
    const t0 = process.hrtime.bigint(), d = midamDiff(big, other), ms = Number(process.hrtime.bigint() - t0) / 1e6;
    if (places !== null) assert.strictEqual(d.count, places, name);
    assert(ms < 50, name + ": " + ms.toFixed(1) + " ms");
    console.log("  " + name + ": " + ms.toFixed(1) + " ms");
  }
});

console.log(process.exitCode ? "FAILED" : `source lines and block diff: ${n} checks passed`);
