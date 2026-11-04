// GitHub-flavoured extras on top of marked: alerts, footnotes, math (KaTeX), :emoji: and a YAML
// front-matter table. Runs in the app's "midam" content world after marked, katex and emoji.js,
// and in node for tools/*-test.js. Document text reaches the output only through marked's own
// escaping, escapeHTML() below or KaTeX (trust: false); these extensions add no raw HTML of their own.

const ALERT_ICONS = { // Primer Octicons 16px (MIT, octicons.LICENSE.txt): info, light-bulb, report, alert, stop
  note: "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z",
  tip: "M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z",
  important: "M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z",
  warning: "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z",
  caution: "M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z",
};
const ALERT_TITLES = { note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution" };

function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// Per-parse state: the labels the app passed (localised words) and the footnotes seen so far.
let gfm = null, labels = {}, notes = new Map(), noteCount = 0;
// What the document contains at all, so the start() scans below (run by marked for every token,
// each over the rest of the text) are skipped outright when there is nothing to find.
let has = {};
// The document's blocks (see markBlocks) and the source line marked's text starts on.
let blocks = [], firstLine = 1;

// marked's block rules, tried at the start of the rest of the document for every block. The
// system WebKit runs a pattern with a counted group, such as hr's (?:-[\t ]*){3,}, in its regex
// interpreter, which tries an anchored ^ pattern at every position: lexing grew with the square
// of the length (144 KB: 1.7 s). The same patterns made sticky are tried at the start only; ^
// without the m flag matches only there, so the matches are the same.
function anchorBlockRules() {
  const rules = marked.Lexer.rules.block.gfm;
  for (const [k, re] of Object.entries(rules)) {
    if (!(re instanceof RegExp) || !re.source.startsWith("^") || /[gmy]/.test(re.flags)) continue;
    const at = new RegExp(re.source, re.flags + "y");
    at.exec = function (s) { this.lastIndex = 0; return RegExp.prototype.exec.call(this, s); };
    rules[k] = at;
  }
}

// Markdown to HTML. `words` holds the localised alert titles and footnote labels.
function midamParse(src, words) {
  labels = words && typeof words === "object" ? words : {};
  const fm = begin(src);
  const html = gfm.parse(fm ? fm.rest : src);
  return (fm ? tag(fm.html, fm) : "") + html + footnoteSection();
}

// Resets the per-document state for `src` and returns its front matter, or null.
function begin(src) {
  if (!gfm) anchorBlockRules();
  gfm ||= new marked.Marked({ gfm: true }, {
    extensions: [mathBlock, footnoteDef, mathInline, footnoteRef, emoji],
    renderer: { code: mathFence, blockquote: alertBox, listitem: sourceItem },
    hooks: { processAllTokens: tokens => markAlerts(markBlocks(tokens)), provideParser: block => block && parseBlocks },
  });
  notes = new Map();
  noteCount = 0;
  has = { note: src.includes("[^"), dollars: src.includes("$$"), dollar: src.includes("$"), colon: /:[a-z0-9_+-]+:/.test(src) };
  const fm = frontMatter(src);
  blocks = [];
  firstLine = fm ? addBlock(fm, "frontMatter", fm.raw, span(fm.raw, 1)).next : 1;
  return fm;
}

// MARK: Source lines. Every top-level block element gets data-src="<first>-<last>" (1-based lines
// of the whole file, front matter included) and data-blk="<n>", its index in `blocks`: the flat
// list changes.js diffs. Lists are split into their items, nested ones too (the ul/ol itself gets
// data-src only); an item's diff text is its own, without its marker or nested lists. Link and
// footnote definitions (a used note's li gets data-src) and HTML that does not start with an
// element draw nothing in place, so they are no block. marked's raws add up to its text (CRLF
// made LF), so lines are counted along them.

const newlines = s => s.split("\n").length - 1;

// The lines of `raw` starting on `line`, without the blank lines around it, and the line after it.
function span(raw, line) {
  return { start: line + newlines(/^(?:[ \t]*\n)*/.exec(raw)[0]), end: line + newlines(raw.trimEnd()), next: line + newlines(raw) };
}

function addBlock(t, kind, raw, s) {
  t.midamSrc = s.start + "-" + s.end;
  t.midamBlk = blocks.length;
  blocks.push({ kind, raw, start: s.start, end: s.end });
  return s;
}

function markBlocks(tokens) {
  let line = firstLine;
  for (const t of tokens) {
    const s = span(t.raw, line);
    line = s.next;
    if (t.type === "list" || t.type === "footnoteDef") t.midamSrc = s.start + "-" + s.end;
    if (t.type === "list") markItems(t, s.start);
    else if (!["space", "def", "footnoteDef"].includes(t.type) && (t.type !== "html" || /^<[a-z]/i.test(t.raw))) addBlock(t, t.type, t.raw, s);
  }
  return tokens;
}

function markItems(list, line) {
  for (const it of list.items) {
    const s = span(it.raw, line), own = [];
    line = s.next;
    addBlock(it, "item", "", s);
    const b = blocks[it.midamBlk];
    let l = s.start; // an item's tokens start on its marker line
    for (const c of it.tokens) {
      if (c.type === "list") markItems(c, span(c.raw, l).start);
      else own.push(c.raw);
      l += newlines(c.raw);
    }
    b.raw = own.join("");
  }
}

// marked's block parser, one top-level token at a time so each one's HTML can be tagged.
function parseBlocks(tokens, options) {
  const p = new marked.Parser(options);
  return tokens.map(t => tag(p.parse([t]), t)).join("");
}

// marked's own <li>, tagged.
function sourceItem(it) {
  return it.midamSrc ? tag("<li>", it) + this.parser.parse(it.tokens) + "</li>\n" : false;
}

// Adds a token's data-src and data-blk to the first tag of its HTML (none if it starts otherwise).
function tag(html, t) {
  return t.midamSrc ? html.replace(/^<[a-z][\w-]*/i, m => m + ' data-src="' + t.midamSrc + '"' + (t.midamBlk === undefined ? "" : ' data-blk="' + t.midamBlk + '"')) : html;
}

// Where a block extension interrupts the paragraph in hand: just after the \n of the first line
// that matches `re` group 1 and that `block` (the tokenizer's anchored regex) accepts, unless the
// paragraph ends first, at a blank line or a heading, fence or quote. Only real starts are
// returned: each cut makes marked rescan the rest of the paragraph, so a false one per line would
// be quadratic. One forward scan, so the work per paragraph is its own length. marked passes the
// text from the paragraph's second character, so index 0 is never a line start.
function lineStart(src, re, block) {
  re.lastIndex = 0;
  for (let m; (m = re.exec(src)); re.lastIndex = m.index + 1) {
    if (m[1] === undefined) return undefined;
    if (block.test(src.slice(m.index + 1))) return m.index + 1;
  }
}
// \n, then group 1 (the extension's line) or a paragraph end: blank line, heading, fence, quote.
const FOOTNOTE_LINE = /\n(?:( {0,3}\[\^[^\]\s]+\]:)|[ \t]*\n| {0,3}(?:#{1,6}(?:[ \t]|\n)|`{3,}|~{3,}|>))/g;
const MATH_LINE = /\n(?:( {0,3}\$\$)|[ \t]*\n| {0,3}(?:#{1,6}(?:[ \t]|\n)|`{3,}|~{3,}|>))/g;
const FOOTNOTE_DEF = /^ {0,3}\[\^([^\]\s]+)\]:[ \t]*([^\n]*(?:\n(?:[ \t]*\n)*(?: {4}|\t)[^\n]*)*)(?:\n|$)/;
// $$, then anything up to the first $$ (no blank line), which ends its line.
const MATH_BLOCK = /^ {0,3}\$\$((?:[^$\n]|\n(?![ \t]*\n)|\$(?!\$))+)\$\$[ \t]*(?:\n+|$)/;

const word = (key, fallback) => escapeHTML(typeof labels[key] === "string" && labels[key] ? labels[key] : fallback);

// MARK: Alerts. A top-level blockquote whose first line is exactly [!NOTE] (any case), as GitHub.

function markAlerts(tokens) {
  for (const t of tokens) {
    if (t.type !== "blockquote") continue;
    const p = t.tokens[0], first = p?.tokens?.[0];
    const m = p?.type === "paragraph" && /^\[!(note|tip|important|warning|caution)\][ \t]*(?:\n|$)/i.exec(p.raw);
    if (!m || first?.type !== "text" || !/^\[!\w+\]/.test(first.raw)) continue;
    const cut = s => s.replace(/^\[!\w+\][ \t]*\n?/, "");
    first.raw = cut(first.raw);
    first.text = cut(first.text);
    if (!first.text) p.tokens.shift();
    if (p.tokens[0]?.type === "br") p.tokens.shift(); // "[!NOTE]  " ends in a hard break
    if (!p.tokens.length) t.tokens.shift();
    t.alert = m[1].toLowerCase();
  }
  return tokens;
}

function alertBox(t) {
  if (!t.alert) return false; // a plain blockquote
  const icon = '<svg class="alert-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="' + ALERT_ICONS[t.alert] + '"/></svg>';
  return '<div class="alert alert-' + t.alert + '" role="note"><p class="alert-title">' + icon +
    word(t.alert, ALERT_TITLES[t.alert]) + "</p>\n" + this.parser.parse(t.tokens) + "</div>\n";
}

// MARK: Footnotes. [^label] refers to "[^label]: text" (continued by lines indented 4 spaces).
// Notes are numbered by first reference; unreferenced ones are dropped, refs to missing ones stay text.

const footnoteDef = {
  name: "footnoteDef", level: "block",
  start: src => (has.note ? lineStart(src, FOOTNOTE_LINE, FOOTNOTE_DEF) : undefined),
  tokenizer(src) {
    const m = FOOTNOTE_DEF.exec(src);
    if (!m) return;
    const label = m[1].toLowerCase();
    const t = { type: "footnoteDef", raw: m[0], label, tokens: [] };
    this.lexer.blockTokens(m[2].replace(/^(?: {4}|\t)/gm, ""), t.tokens);
    if (!notes.has(label)) notes.set(label, { n: 0, refs: 0, html: "" });
    return t;
  },
  renderer(t) {
    const note = notes.get(t.label);
    if (note && !note.html) {
      note.html = this.parser.parse(t.tokens);
      note.src = t.midamSrc;
    }
    return "";
  },
};

const footnoteRef = {
  name: "footnoteRef", level: "inline",
  start: src => (has.note ? src.indexOf("[^") : -1),
  tokenizer(src) {
    const m = /^\[\^([^\]\s]+)\]/.exec(src), note = m && notes.get(m[1].toLowerCase());
    if (!note) return;
    if (!note.n) note.n = ++noteCount;
    return { type: "footnoteRef", raw: m[0], n: note.n, ref: ++note.refs };
  },
  renderer: t => '<sup class="footnote-ref"><a href="#midam-fn-' + t.n + '" id="midam-fnref-' + t.n + (t.ref > 1 ? "-" + t.ref : "") + '" aria-describedby="midam-footnote-label">' + t.n + "</a></sup>",
};

function footnoteSection() {
  const used = [...notes.values()].filter(n => n.n).sort((a, b) => a.n - b.n);
  if (!used.length) return "";
  const items = used.map(n => {
    let back = "";
    for (let r = 1; r <= n.refs; r++) {
      back += ' <a href="#midam-fnref-' + n.n + (r > 1 ? "-" + r : "") + '" class="footnote-back" aria-label="' +
        word("back", "Back to reference") + " " + n.n + (r > 1 ? "-" + r : "") + '">↩︎' + (r > 1 ? "<sup>" + r + "</sup>" : "") + "</a>";
    }
    const body = n.html.trimEnd();
    return '<li id="midam-fn-' + n.n + '"' + (n.src ? ' data-src="' + n.src + '"' : "") + ">" + (/<\/p>$/.test(body) ? body.slice(0, -4) + back + "</p>" : body + back) + "</li>";
  });
  return '<section class="footnotes"><h2 class="footnotes-title" id="midam-footnote-label">' + word("footnotes", "Footnotes") + "</h2>\n<ol>\n" + items.join("\n") + "\n</ol>\n</section>\n";
}

// MARK: Math, as GitHub: $inline$, $$display$$ and ```math fences. An inline $ must be followed
// by a non-space, the closing $ must follow a non-space and not precede a digit, and digit-only
// content is not math, so "$5 and $10" stays text. \$ is a literal dollar.

function tex(src, display) {
  try {
    return katex.renderToString(src, { displayMode: display, throwOnError: false, trust: false, strict: "ignore",
      maxExpand: 1000, maxSize: 40, errorColor: "var(--marker)" });
  } catch { // throwOnError: false still throws for non-parse errors
    return '<code class="math-error">' + escapeHTML(src) + "</code>";
  }
}

const mathBlock = {
  name: "mathBlock", level: "block",
  start: src => (has.dollars ? lineStart(src, MATH_LINE, MATH_BLOCK) : undefined),
  tokenizer(src) {
    const m = MATH_BLOCK.exec(src);
    if (m) return { type: "mathBlock", raw: m[0], text: m[1].trim() };
  },
  renderer: t => '<div class="math-display">' + tex(t.text, true) + "</div>\n",
};

const mathInline = {
  name: "mathInline", level: "inline",
  start: src => (has.dollar ? src.indexOf("$") : -1),
  tokenizer(src) {
    let m = /^\$\$((?:\\[^]|[^\\$]|\$(?!\$))+?)\$\$/.exec(src);
    if (m) return { type: "mathInline", raw: m[0], text: m[1].trim(), display: true };
    m = /^\$(?=[^\s$])((?:\\[^]|[^\\$])+)\$(?!\d)/.exec(src);
    if (m && !/\s$/.test(m[1]) && !/^[\d.,\s]+$/.test(m[1])) return { type: "mathInline", raw: m[0], text: m[1], display: false };
  },
  renderer: t => tex(t.text, t.display),
};

function mathFence(t) {
  if ((t.lang || "").split(/\s/)[0] !== "math") return false; // any other fence: marked's own
  return '<div class="math-display">' + tex(t.text, true) + "</div>\n";
}

// MARK: :shortcode: emoji (gemoji names). Code spans, code blocks, URLs and HTML tags are lexed
// before this runs at their position, so they are never touched.

const emoji = {
  name: "emoji", level: "inline",
  start: src => (has.colon ? src.search(/:[a-z0-9_+-]+:/) : -1),
  tokenizer(src) {
    const m = /^:([a-z0-9_+-]+):/.exec(src), e = m && midamEmoji[m[1]];
    if (e) return { type: "emoji", raw: m[0], text: e };
  },
  renderer: t => t.text, // from emoji.js: emoji characters only
};

// MARK: Front matter. A leading --- … --- block becomes a key/value table when it holds only
// top-level "key: value" scalars and lists; anything else (nesting, block scalars, anchors, tags,
// flow maps) is shown as a YAML code block. Returns null when the document has none.

function frontMatter(src) {
  const m = /^\uFEFF?---[ \t]*\r?\n([^]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(src);
  if (!m) return null;
  const lines = m[1].split(/\r?\n/), rest = src.slice(m[0].length);
  const meaningful = l => l.trim() && !/^\s*#/.test(l);
  if (!/^[\p{L}\p{N}_][\p{L}\p{N}_ .-]*:(?:\s|$)/u.test(lines.find(meaningful) || "")) return null; // not a mapping: plain Markdown
  const rows = [];
  for (let i = 0; i < lines.length; i++) {
    if (!meaningful(lines[i])) continue;
    const kv = /^([\p{L}\p{N}_][\p{L}\p{N}_ .-]*?)[ \t]*:(?:[ \t]+(.*))?$/u.exec(lines[i]);
    let value = kv ? (kv[2] || "").trim() : null;
    if (value === "") { // a block list, or empty
      const items = [];
      while (i + 1 < lines.length && /^[ \t]*-(?:[ \t]|$)/.test(lines[i + 1])) items.push(scalar(lines[++i].replace(/^[ \t]*-[ \t]*/, "")));
      value = items.length ? items : "";
    } else if (value && /^\[.*\]$/.test(value)) {
      const inner = value.slice(1, -1);
      value = /["'[\]{}]/.test(inner) ? [null] : inner.split(",").map(scalar).filter(s => s !== "");
    } else if (value) value = scalar(value);
    if (value === null || (Array.isArray(value) && value.includes(null))) {
      return { html: '<pre class="front-matter"><code class="language-yaml">' + escapeHTML(m[1]) + "</code></pre>\n", rest, raw: m[0] };
    }
    rows.push("<tr><th scope=\"row\">" + escapeHTML(kv[1]) + "</th><td>" + (Array.isArray(value)
      ? value.map(v => '<span class="fm-item">' + escapeHTML(v) + "</span>").join(" ")
      : escapeHTML(value)) + "</td></tr>");
  }
  return { html: '<table class="front-matter">\n<tbody>\n' + rows.join("\n") + "\n</tbody>\n</table>\n", rest, raw: m[0] };
}

// One YAML scalar as text, or null when it needs a real YAML parser.
function scalar(v) {
  v = v.trim();
  if (/^"(?:[^"\\]|\\.)*"$/.test(v)) { try { return String(JSON.parse(v)); } catch { return null; } }
  if (/^'(?:[^']|'')*'$/.test(v)) return v.slice(1, -1).replace(/''/g, "'");
  v = v.replace(/(?:^|\s+)#.*$/, "");
  if (/^[[\]{}&*!|>%@`"']/.test(v) || /:(?:\s|$)/.test(v)) return null;
  return v;
}
