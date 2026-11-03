// Runs Resources/markdown.js (with the bundled marked, KaTeX and emoji map) and checks alerts,
// footnotes and :emoji:. Run: node tools/gfm-test.js
const fs = require("fs"), path = require("path"), R = path.join(__dirname, "../Resources/");
const parse = new Function("marked", "katex", fs.readFileSync(R + "emoji.js", "utf8") + fs.readFileSync(R + "markdown.js", "utf8") +
  "\nreturn midamParse;")(require(R + "marked.umd.js"), require(R + "katex.min.js"));
let bad = 0, n = 0;
const check = (name, ok, out) => { n++; if (!ok) { bad++; console.log("FAIL", name, "\n" + out); } };
const has = (md, ...want) => { const h = parse(md, {}); check(JSON.stringify(md), want.every(w => (w instanceof RegExp ? w.test(h) : h.includes(w))), h); return h; };
const lacks = (md, ...not) => { const h = parse(md, {}); check(JSON.stringify(md), not.every(w => (w instanceof RegExp ? !w.test(h) : !h.includes(w))), h); return h; };

// Alerts: the five kinds, any case, marker alone on the first line, top level only.
for (const k of ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]) has("> [!" + k + "]\n> Body *em*", 'class="alert alert-' + k.toLowerCase() + '"', "<p>Body <em>em</em></p>", '<svg class="alert-icon"');
has("> [!warning]\n> x", "alert-warning", ">Warning</p>");
lacks("> [!NOTE]\n> Body", "[!NOTE]");
has("> [!NOTE] same line", "<blockquote>", "[!NOTE] same line");
has("> [!NOTE]\n>\n> Second paragraph", "alert-note", "<p>Second paragraph</p>");
lacks("> [!NOTE]\n>\n> Second paragraph", "<p></p>");
has("> [!NOTE]  \n> hard break", "alert-note", "<p>hard break</p>");
has("> [!FOO]\n> x", "<blockquote>", "[!FOO]");
has("> \\[!NOTE]\n> x", "<blockquote>");
has("- > [!NOTE]\n  > nested", "<blockquote>", "[!NOTE]");
has("> > [!NOTE]\n> > inner", "[!NOTE]");
has("> `[!NOTE]`\n> x", "<blockquote>", "<code>[!NOTE]</code>");
check("localised title", parse("> [!TIP]\n> x", { tip: "팁" }).includes(">팁</p>"), parse("> [!TIP]\n> x", { tip: "팁" }));
check("title is escaped", parse("> [!TIP]\n> x", { tip: '<img src=x onerror=alert(1)>"' }).includes("&lt;img src=x onerror=alert(1)&gt;&quot;</p>"), "");

// Footnotes: numbered by first reference, back-links per reference, unknown refs stay text.
let h = has("A[^b] B[^a] C[^b].\n\n[^a]: Note a.\n[^b]: Note b.\n[^unused]: Never cited.",
  '<a href="#midam-fn-1" id="midam-fnref-1" aria-describedby="midam-footnote-label">1</a>', '<a href="#midam-fn-2" id="midam-fnref-2" aria-describedby="midam-footnote-label">2</a>', '<a href="#midam-fn-1" id="midam-fnref-1-2" aria-describedby="midam-footnote-label">1</a>',
  '<li id="midam-fn-1"><p>Note b. <a href="#midam-fnref-1"', 'href="#midam-fnref-1-2"', '<li id="midam-fn-2"><p>Note a.', '<section class="footnotes">');
check("unused note dropped", !h.includes("Never cited"), h);
check("order", h.indexOf('id="midam-fn-1"') < h.indexOf('id="midam-fn-2"'), h);
has("Ref [^nope] here.", "[^nope]");
lacks("Ref [^nope] here.", "footnotes");
has("X[^1]\n\n[^1]: First.\n\n    Indented continuation.\n\nAfter.", "<p>Indented continuation. <a href=\"#midam-fnref-1\"", "<p>After.</p>");
has("X[^Label]\n\n[^label]: Case-insensitive.", 'href="#midam-fn-1"', "Case-insensitive.");
h = lacks('X[^a"onmouseover="alert(1)]\n\n[^a"onmouseover="alert(1)]: hostile', "onmouseover");
check("hostile label still a footnote", h.includes('href="#midam-fn-1"') && h.includes("hostile"), h);
check("back label escaped", parse("X[^1]\n\n[^1]: n", { back: '"><b>x' }).includes('aria-label="&quot;&gt;&lt;b&gt;x 1"'), "");
check("state resets per document", !parse("plain", {}).includes("footnotes"), "");
has("`[^1]`\n\n[^1]: n", "<code>[^1]</code>");

// Emoji: known gemoji names only, never in code, never building HTML.
has("Hi :smile: :+1: :tada:", "Hi 😄 👍 🎉");
has("`:smile:` and :smile:", "<code>:smile:</code> and 😄");
has("```\n:smile:\n```", "<code>:smile:\n</code>");
has("    :smile: indented code", ":smile: indented code");
has(":not_an_emoji: and :constructor: and :toString:", ":not_an_emoji: and :constructor: and :toString:");
has("10:30:00", "10:30:00");
has("<span title=\":smile:\">x</span>", 'title=":smile:"');
has("[a](https://example.com/:smile:/x)", 'href="https://example.com/:smile:/x"');
has("https://example.com/:smile:/x", 'href="https://example.com/:smile:/x"');
const emojiMap = new Function(fs.readFileSync(R + "emoji.js", "utf8") + "\nreturn midamEmoji;")();
check("emoji map holds no markup", Object.entries(emojiMap).every(([k, v]) => /^[a-z0-9_+-]+$/.test(k) && !/[<>&"'\\]/.test(v)), "");

// Heading ids (render.js) never take an id the app uses: the views and its midam-… ids.
const headingId = new Function("document", fs.readFileSync(R + "render.js", "utf8") + "\nreturn headingId;")({});
const seen = {};
const ids = ["Source", "Content", "Source", "midam fn 1", "Intro", "Intro", "dmidam diagram 1"].map(t => headingId(t, seen));
check("heading ids", JSON.stringify(ids) === '["source-1","content-1","source-2","midam-fn-1-1","intro","intro-1","dmidam-diagram-1-1"]', ids);
check("footnote ids are prefixed", !/(?:id|href)="#?(?:fn|fnref)-/.test(parse("A[^1]\n\n[^1]: n", {})), "");

console.log(bad ? `FAILED ${bad} of ${n}` : `alerts, footnotes, emoji: ${n} checks passed`);
process.exit(bad ? 1 : 0);
