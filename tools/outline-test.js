// Checks the table of contents outline from render.js (headingId, outlineHeads, midamOutline) on
// stand-in heading elements: levels h1-h3 only, ids (repeats, app ids, prototype names), plain
// text with hostile HTML kept as text, and the size bounds. Run: node tools/outline-test.js
const fs = require("fs"), path = require("path");
const src = fs.readFileSync(path.join(__dirname, "../Resources/render.js"), "utf8");
const cut = (from, to) => src.slice(src.indexOf(from), src.indexOf(to, src.indexOf(from)));
const { headingId, outlineHeads, midamOutline } = new Function(
  cut("const appId", "// Table of contents") + cut("// Table of contents", "// The section being read") +
  "return { headingId, outlineHeads, midamOutline };")();

let bad = 0, n = 0;
const check = (name, ok, info) => { n++; if (!ok) { bad++; console.log("FAIL", name, JSON.stringify(info)); } };

// Headings as render.js leaves them: every one gets an id from its text, in document order,
// counted in the same kind of table midamRender makes (a plain {} numbers "constructor" NaN).
const newSeen = new Function("return " + src.match(/const seen = ([^;]+);/)[1]);
function doc(list) {
  const seen = newSeen(), all = list.map(([tag, text, id]) => ({ tagName: tag, textContent: text, id: id ?? headingId(text, seen) }));
  return { querySelectorAll: sel => (check("selector", sel === "h1,h2,h3", sel), all.filter(h => /^H[123]$/.test(h.tagName))) };
}
const outline = list => midamOutline(outlineHeads(doc(list)));

const o = outline([["H1", "Midam"], ["H2", "Intro"], ["H3", "Detail"], ["H4", "Too deep"], ["H2", "Intro"], ["H2", "Intro"],
  ["H2", "Source"], ["H3", "constructor"], ["H3", "toString"], ["H3", "constructor"], ["H2", "__proto__"]]);
check("levels, h4 skipped", JSON.stringify(o.map(h => h.level)) === "[1,2,3,2,2,2,3,3,3,2]", o);
check("ids: repeats numbered, app id taken, prototype names plain",
  JSON.stringify(o.map(h => h.id)) === '["midam","intro","detail","intro-1","intro-2","source-1","constructor","tostring","constructor-1","proto"]', o.map(h => h.id));
check("only level, text and id, as number and strings",
  o.every(h => JSON.stringify(Object.keys(h)) === '["level","text","id"]' && typeof h.level === "number" && typeof h.text === "string" && typeof h.id === "string"), o);

// Hostile text: textContent is text, so markup in it stays characters for SwiftUI Text to show.
const evil = '<img src=x onerror=alert(1)><script>alert("x")</script>&amp;';
const e = outline([["H2", "  " + evil + "\n\t tail "]]);
check("hostile heading text kept verbatim as text, whitespace folded", e.length === 1 && e[0].text === evil + " tail", e);
check("hostile heading id has no markup", /^[\p{L}\p{N}-]+$/u.test(e[0].id), e[0].id);

// Bounds: no empty headings or ids, long text cut on a character boundary, long ids dropped, at most 500.
const b = outline([["H2", "   "], ["H2", "No id", ""], ["H2", "x", "i".repeat(513)], ["H2", "ok", "i".repeat(512)], ["H1", "가😀".repeat(150)]]);
check("empty text and id left out, 512-unit id kept, 513 dropped", b.length === 2 && b[0].text === "ok", b.map(h => h.text.slice(0, 9)));
check("text cut to 200 characters without splitting a pair", Array.from(b[1].text).length === 200 && !/[\ud800-\udbff]$/.test(b[1].text), b[1].text.length);
check("at most 500 entries", outline(Array.from({ length: 600 }, (_, i) => ["H2", "h" + i])).length === 500);

console.log(bad ? `FAILED ${bad} of ${n}` : `outline: ${n} checks passed (levels, ids, hostile text, bounds)`);
process.exit(bad ? 1 : 0);
