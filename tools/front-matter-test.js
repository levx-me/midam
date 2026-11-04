// Checks the YAML front-matter table and its code-block fallback (Resources/markdown.js), and the
// light/dark image rule (#gh-dark-mode-only / #gh-light-mode-only in Resources/style.css).
// Run: node tools/front-matter-test.js
const fs = require("fs"), path = require("path"), R = path.join(__dirname, "../Resources/");
const midamParse = new Function("marked", "katex", fs.readFileSync(R + "emoji.js", "utf8") + fs.readFileSync(R + "markdown.js", "utf8") +
  "\nreturn midamParse;")(require(R + "marked.umd.js"), require(R + "katex.min.js"));
// Source positions (data-src, data-blk) are checked by tools/changes-test.js.
const parse = (md, words) => midamParse(md, words).replace(/ data-(?:src|blk)="[^"]*"/g, "");
let bad = 0, n = 0;
const check = (name, ok, out) => { n++; if (!ok) { bad++; console.log("FAIL", name, "\n" + out); } };
const has = (md, ...want) => { const h = parse(md, {}); check(JSON.stringify(md), want.every(w => h.includes(w)), h); return h; };

// Simple scalars and lists become a two-column table; the rest of the document follows.
let h = has("---\ntitle: Hello\n제목: 안녕\nquoted: \"a: b\"\nsingle: 'it''s'\ncomment: x # note\ntags: [a, b]\nlist:\n  - one\n  - \"two, three\"\nempty:\n---\n# Doc",
  '<table class="front-matter">', '<th scope="row">title</th><td>Hello</td>', '<th scope="row">제목</th><td>안녕</td>',
  "<td>a: b</td>", "<td>it&#39;s</td>", "<td>x</td>", '<span class="fm-item">a</span> <span class="fm-item">b</span>',
  '<span class="fm-item">one</span> <span class="fm-item">two, three</span>', '<th scope="row">empty</th><td></td>', "<h1>Doc</h1>");
check("no stray hr", !h.includes("<hr>"), h);
has("\uFEFF---\na: 1\n...\nbody", '<td>1</td>', "<p>body</p>");
has("---\r\na: 1\r\n---\r\nbody", "<td>1</td>", "<p>body</p>");
// Values are text, never markup.
h = has("---\nx: <img src=x onerror=alert(1)>\n\"<b>\": y\n---\n", "&lt;img src=x onerror=alert(1)&gt;");
check("no raw img", !h.includes("<img"), h);
// Anything a real YAML parser would be needed for falls back to a YAML code block.
for (const fm of ["a:\n  b: nested", "a: |\n  block", "a: &x 1\nb: *x", "a: !tag x", "a: {b: c}", "- top list", "a: [b, [c]]",
  "a:\n  - b: c", "a: x\n  continued"]) {
  h = parse("---\n" + fm + "\n---\nbody", {});
  const plain = fm.startsWith("- "); // not a mapping at all: plain Markdown
  check("fallback " + JSON.stringify(fm), (plain ? !h.includes("front-matter") : h.includes('<pre class="front-matter"><code class="language-yaml">')) &&
    !h.includes("<table") && h.includes("<p>body</p>"), h);
}
h = parse("---\na: <b>x</b>\nb:\n  c: d\n---\n", {});
check("fallback escapes", h.includes("&lt;b&gt;x&lt;/b&gt;") && !h.includes("<b>"), h);
// Not front matter: plain Markdown as before.
has("Intro\n---\ntitle: x\n---\n", "<h2>Intro</h2>");
has("---\nJust a heading\n---\n", "<hr>", "<h2>Just a heading</h2>");
has("---\n\n---\n", "<hr>");

// Light/dark images: the fragment survives into src, and style.css hides each variant in the other appearance.
h = parse("![l](a.png#gh-light-mode-only) ![d](b.png#gh-dark-mode-only) ![p](c.png)", {});
const srcs = [...h.matchAll(/src="([^"]*)"/g)].map(m => m[1]);
check("srcs keep the fragment", JSON.stringify(srcs) === '["a.png#gh-light-mode-only","b.png#gh-dark-mode-only","c.png"]', h);
const css = fs.readFileSync(R + "style.css", "utf8");
const hidden = scheme => {
  const re = new RegExp("@media \\(prefers-color-scheme: " + scheme + "\\) \\{([^{}]*\\{[^}]*\\}[^{}]*)*\\}", "g");
  return [...css.matchAll(re)].flatMap(m => [...m[0].matchAll(/img\[src\$="([^"]+)" i\] \{ display: none; \}/g)].map(x => x[1]));
};
const shown = (src, scheme) => !hidden(scheme).some(suffix => src.toLowerCase().endsWith(suffix.toLowerCase()));
check("light shows light, hides dark", shown(srcs[0], "light") && !shown(srcs[1], "light") && shown(srcs[2], "light"), hidden("light"));
check("dark shows dark, hides light", !shown(srcs[0], "dark") && shown(srcs[1], "dark") && shown(srcs[2], "dark"), hidden("dark"));
check("case-insensitive", !shown("X.PNG#GH-DARK-MODE-ONLY", "light"), "");

console.log(bad ? `FAILED ${bad} of ${n}` : `front matter and image variants: ${n} checks passed`);
process.exit(bad ? 1 : 0);
