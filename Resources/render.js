// Runs in the app's isolated "midam" content world, never in the page.
// The new content is built off-screen and swapped in; a re-render (auto-reload) waits for its
// images and diagrams first, so it keeps the scroll position without a flash or jump. The first
// render shows at once: diagrams show their code until midamDrawDiagrams draws them in place.
// `words` are the localised labels the page shows (alert titles, footnotes, diagram errors).
// Returns "mermaid" (without showing anything) when a re-render has a diagram and mermaid is not
// loaded yet: the app then evaluates mermaid.min.js in this world and calls again (asked once).
// Otherwise it returns the table of contents, {outline: [{level, text, id}], current: id or ""},
// and the finished 읽기 HTML for the app's render cache (html: null when over 10 MB, or when
// diagrams wait for mermaid: diagrams true, the app loads it and calls midamDrawDiagrams).
let renders = 0, askedForMermaid = false;

// A trackpad gesture over a block that scrolls sideways (code, a wide table, diagram or formula)
// moves both ways at once: the block sideways, the page up and down. WebKit would hand the whole
// gesture to the block, which cannot scroll vertically, and drop the vertical part. Pinch (ctrl) stays native.
globalThis.addEventListener?.("wheel", e => { // ?.: the Node tests load this file without a window
  if (e.ctrlKey || !e.deltaY) return;
  let block = e.target instanceof Element ? e.target : e.target.parentElement;
  while (block && block !== document.body && !(block.scrollWidth > block.clientWidth + 1 && /auto|scroll/.test(getComputedStyle(block).overflowX)))
    block = block.parentElement;
  if (!block || block === document.body) return;
  e.preventDefault();
  block.scrollLeft += e.deltaX;
  scrollBy(0, e.deltaY);
}, { passive: false });
function setBase(base) {
  if (!base) return;
  const b = document.querySelector("base") || document.head.appendChild(document.createElement("base"));
  b.href = base;
}
async function midamRender(md, base, words, baseline) {
  const gen = ++renders, t0 = performance.now(), timing = {}; // timing: ms per step, logged by the app (OpenTiming)
  const lap = (name, since) => { timing[name] = Math.round(performance.now() - since); return performance.now(); };
  setBase(base);
  const next = document.createElement("article");
  next.id = "content";
  next.innerHTML = midamParse(md, words);
  const seen = Object.create(null); // no prototype: "constructor" is a heading like any other
  for (const h of next.querySelectorAll("h1,h2,h3,h4,h5,h6")) if (!h.id) h.id = headingId(h.textContent, seen);
  let t = lap("parse", t0);
  // The views by position, never by id: the document may hold an element with id "content" or "source".
  const shown = document.querySelector("body > #content"), first = !shown.hasChildNodes(); // nothing on screen yet
  const diagrams = [...next.querySelectorAll("pre > code.language-mermaid")];
  if (diagrams.length && typeof mermaid === "undefined" && !askedForMermaid) {
    askedForMermaid = true;
    if (!first) return "mermaid";
  }
  // Each diagram a figure holding its code (style.css shows it as code), drawn here before a
  // re-render swaps in, or after the first render shows (midamDrawDiagrams).
  const figs = diagrams.map(code => {
    const fig = document.createElement("figure");
    fig.className = "diagram";
    diagramSource.set(fig, code.textContent);
    for (const a of ["data-src", "data-blk"]) if (code.parentElement.hasAttribute(a)) fig.setAttribute(a, code.parentElement.getAttribute(a));
    code.parentElement.replaceWith(fig);
    fig.appendChild(code.parentElement);
    return fig;
  });
  diagramWords = words || {};
  const drawNow = !first && typeof mermaid !== "undefined";
  if (drawNow) await Promise.all(figs.map(drawDiagram));
  t = lap("diagrams", t);
  // Every table in a scroll box (style.css: wide ones scroll there, never squeezed or the page).
  for (const table of next.querySelectorAll("table")) {
    const wrap = document.createElement("div");
    wrap.className = "table-wrap";
    table.replaceWith(wrap);
    wrap.appendChild(table);
  }
  // Only fences with a known language tag; no auto-detection.
  for (const code of next.querySelectorAll('pre > code[class^="language-"]')) {
    const lang = code.className.slice(9);
    if (hljs.getLanguage(lang)) tint(code, code.textContent, lang);
  }
  // The raw Markdown for the source view, lightly tinted.
  const source = document.createElement("pre");
  source.id = "source";
  tint(source.appendChild(document.createElement("code")), md, "markdown");
  t = lap("highlight", t);
  if (!first) { // a page already on screen: swap in once the images have decoded (the first render shows at once)
    const images = Promise.all([...next.querySelectorAll("img")].map(i => i.decode().catch(() => {})));
    await Promise.race([images, new Promise(r => setTimeout(r, 1000))]);
  }
  t = lap("images", t);
  if (gen !== renders) return; // a newer render (e.g. a quick second save) won
  const html = next.innerHTML;
  let root = next;
  if (cachedHTML !== null && sameRender(cachedHTML, html)) {
    // The cached page on screen is this render: keep its nodes (nothing repaints or moves), and
    // give its diagrams their sources so a theme change can redraw them.
    const fresh = next.querySelectorAll("figure.diagram"), kept = shown.querySelectorAll("figure.diagram");
    fresh.forEach((f, i) => { if (kept[i] && diagramSource.has(f)) diagramSource.set(kept[i], diagramSource.get(f)); });
    root = shown;
  } else {
    // WebKit drops the scroll position when the swap brings in mermaid's SVGs (back to the top on
    // every save): put the reader back where they were.
    const y = scrollY;
    shown.replaceWith(next);
    if (scrollY !== y) scrollTo(0, y);
  }
  cachedHTML = null;
  document.querySelector("body > #source").replaceWith(source);
  startSpy();
  tocHeads = outlineHeads(root);
  const changes = midamMarks(baseline, md); // after the swap: `html` (the cache's) has no marks
  spySent = currentHeading(); // reported with the outline; the spy sends only changes from here
  lap("swap", t);
  lap("total", t0);
  const result = { outline: midamOutline(tocHeads), current: spySent, html: html.length <= 10000000 ? html : null, timing, changes };
  waiting = drawNow ? [] : figs;
  if (!figs.length || drawNow) return result;
  if (typeof mermaid === "undefined") return { ...result, html: null, diagrams: true };
  return { ...result, html: await midamDrawDiagrams() };
}

// The figures the last render showed as code, drawn in place once mermaid is loaded (a figure
// above the reading line keeps the text being read where it is; drawDiagram). Returns the
// finished 읽기 HTML for the render cache, or null if a newer render replaced the page meanwhile.
let waiting = [];
async function midamDrawDiagrams() {
  const gen = renders, figs = waiting;
  waiting = [];
  if (typeof mermaid === "undefined" || !figs.length) return null;
  await Promise.all(figs.map(drawDiagram));
  const html = unmarked(document.querySelector("body > #content"));
  return gen === renders && html.length <= 10000000 ? html : null;
}

// A cached render from the app (the last finished 읽기 page of this file, made with the same file,
// settings and build), shown at once while the real render runs; it goes in as an argument, as
// inert as a fresh render (page script is off, CSP blocks scripts). The real render then keeps
// these nodes if it comes out the same (sameRender), or replaces them. Diagram ids are numbered on
// from the cached ones, since mermaid removes any element that already holds the id it draws under.
let cachedHTML = null;
const sameRender = (a, b) => a.replace(/midam-diagram-\d+/g, "") === b.replace(/midam-diagram-\d+/g, "");
function midamShowCached(html, base, md, baseline, words) {
  setBase(base);
  diagramWords = words || {};
  const shown = document.querySelector("body > #content");
  shown.innerHTML = html;
  cachedHTML = html;
  for (const m of html.matchAll(/midam-diagram-(\d+)/g)) diagramCount = Math.max(diagramCount, Number(m[1]));
  startSpy();
  tocHeads = outlineHeads(shown);
  const changes = midamMarks(baseline, md);
  spySent = currentHeading();
  return { outline: midamOutline(tocHeads), current: spySent, changes };
}

// A heading's id from its text, GitHub-style, numbered when repeated. Ids the app uses itself
// (the two views, and its generated midam-… ids) count as taken, so "# Source" becomes "source-1".
const appId = id => id === "content" || id === "source" || /^d?midam-/.test(id);
function headingId(text, seen) {
  const id = text.trim().toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "");
  if (seen[id] === undefined && appId(id)) seen[id] = 0;
  if (seen[id] === undefined) { seen[id] = 0; return id; }
  return id + "-" + ++seen[id];
}

// Table of contents: the reading view's h1-h4 as plain text (the app shows it as SwiftUI Text),
// with ids and sizes bounded. Headings without text or an id are left out.
const outlineText = h => {
  const t = h.textContent.replace(/\s+/g, " ").trim();
  return t.length > 200 ? Array.from(t).slice(0, 200).join("") : t;
};
const outlineHeads = root =>
  [...root.querySelectorAll("h1,h2,h3,h4")].filter(h => h.id && h.id.length <= 512 && outlineText(h)).slice(0, 500);
const midamOutline = heads => heads.map(h => ({ level: Number(h.tagName[1]), text: outlineText(h), id: h.id }));

// The section being read: the last outline heading at or above the line a jump to it lands on
// (scroll-margin-top in style.css), the last one on screen at the very bottom, the first before
// any. Sent to the app (a handler in this world only) at most every 120 ms, and only on change.
let tocHeads = [], spyTimer = 0, spySent = null, spying = false;
function currentHeading() {
  if (document.documentElement.dataset.view === "source" || !tocHeads.length) return "";
  const line = headerInset + 24, bottom = scrollY + innerHeight >= document.documentElement.scrollHeight - 2;
  let id = tocHeads[0].id;
  for (const h of tocHeads) {
    const top = h.getBoundingClientRect().top;
    if (top <= line || (bottom && top < innerHeight)) id = h.id;
    else break;
  }
  return id;
}
function spy(now) {
  if (now) spySent = null;
  if (spyTimer) return;
  spyTimer = setTimeout(() => {
    spyTimer = 0;
    const id = currentHeading();
    if (id !== spySent) { spySent = id; window.webkit?.messageHandlers?.midamToc?.postMessage(id); }
  }, now ? 0 : 120);
}
function startSpy() { // on the first render, so the tests that load this file in node need no DOM
  if (spying) return;
  spying = true;
  for (const e of ["scroll", "resize"]) addEventListener(e, () => spy(false), { passive: true });
}

// Mermaid diagrams, drawn from the fence text with the colour theme's tokens. securityLevel
// "strict" encodes label text and drops click handlers; htmlLabels off keeps labels as SVG text,
// and "secure" stops a diagram's %%{init}%% directive from turning either back on.
const diagramSource = new WeakMap(); // figure -> mermaid source
let diagramCount = 0, diagramKey = "", diagramSVG = new Map(), diagramWords = {};

function hexRGB(h) { return [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)); }
const toHex = rgb => "#" + rgb.map(v => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0")).join("");
const mixHex = (a, b, t) => toHex(hexRGB(a).map((v, i) => v + (hexRGB(b)[i] - v) * t)); // a*(1-t) + b*t
function contrast(a, b) { // WCAG ratio
  const lum = h => hexRGB(h).map(v => v / 255).map(v => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
    .reduce((s, v, i) => s + v * [0.2126, 0.7152, 0.0722][i], 0);
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}
function withLightness(h, l) { // h's hue at HSL lightness l (0-1), saturation capped at 60%
  const [r, g, b] = hexRGB(h).map(v => v / 255), max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  const hue = d === 0 ? 0 : (max === r ? ((g - b) / d + 6) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4) * 60;
  const s = Math.min(0.6, d === 0 ? 0 : d / (1 - Math.abs(max + min - 1))), a = s * Math.min(l, 1 - l);
  const f = n => { const k = (n + hue / 30) % 12; return (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))) * 255; };
  return toHex([f(0), f(8), f(4)]);
}

const DIAGRAM_TYPES = ["flowchart", "swimlane", "agentflow", "sequence", "gantt", "journey", "timeline", "class", "state", "er",
  "pie", "quadrantChart", "xyChart", "requirement", "architecture", "mindmap", "ishikawa", "kanban", "gitGraph", "sankey",
  "packet", "block", "eventmodeling", "treeView", "radar", "usecase", "venn", "wardley-beta", "cynefin", "railroad"]; // mermaid 12.2

function diagramConfig() {
  const css = getComputedStyle(document.documentElement), v = n => (css.getPropertyValue("--" + n).trim() || "#808080");
  const bg = v("bg"), text = v("text"), muted = v("muted"), faint = v("faint"), hairline = v("hairline"), codeBg = v("code-bg");
  const dark = hexRGB(bg).reduce((a, c) => a + c, 0) / 765 < 0.5;
  const mono = document.documentElement.hasAttribute("data-mono");
  // The accent ramp: the theme's element colours, or for a monochrome theme, ink at falling strength.
  const accents = mono ? [text, muted, faint] : ["link", "code", "heading", "marker", "tk-type", "tk-meta", "tk-number", "tk-keyword"].map(v);
  // A fill of accent i over the page, at strength t or weaker, so body text on it stays 4.5:1.
  const tint = (i, t) => {
    let c;
    for (t = mono ? t * 0.7 : t; t > 0; t -= 0.04) if (contrast(text, (c = mixHex(bg, accents[i % accents.length], t))) >= 4.5) return c;
    return bg;
  };
  const caution = mono ? text : v("marker"), border = mono ? muted : accents[0];
  const body = getComputedStyle(document.body);
  const tv = {
    darkMode: dark, background: bg, fontFamily: body.fontFamily,
    fontSize: Math.round(parseFloat(body.fontSize) * 0.875) + "px",
    primaryColor: codeBg, primaryTextColor: text, primaryBorderColor: border,
    secondaryColor: tint(1, 0.18), secondaryTextColor: text, secondaryBorderColor: mono ? faint : accents[1],
    tertiaryColor: tint(2, 0.12), tertiaryTextColor: text, tertiaryBorderColor: mono ? hairline : accents[2],
    textColor: text, titleColor: v("heading"), lineColor: muted, arrowheadColor: muted,
    mainBkg: codeBg, nodeBorder: border, nodeTextColor: text, clusterBkg: mixHex(bg, codeBg, 0.5), clusterBorder: faint,
    edgeLabelBackground: bg, noteBkgColor: tint(4, 0.16), noteTextColor: text, noteBorderColor: faint,
    actorBkg: codeBg, actorBorder: border, actorTextColor: text, actorLineColor: faint,
    signalColor: text, signalTextColor: text, labelBoxBkgColor: codeBg, labelBoxBorderColor: border,
    labelTextColor: text, loopTextColor: text, activationBkgColor: hairline, activationBorderColor: muted, sequenceNumberColor: bg,
    sectionBkgColor: tint(0, 0.1), altSectionBkgColor: bg, sectionBkgColor2: codeBg, excludeBkgColor: codeBg,
    taskBkgColor: tint(0, 0.3), taskBorderColor: border, taskTextColor: text, taskTextLightColor: text,
    taskTextDarkColor: text, taskTextOutsideColor: text, activeTaskBkgColor: tint(1, 0.3), activeTaskBorderColor: accents[1 % accents.length],
    doneTaskBkgColor: codeBg, doneTaskBorderColor: faint, critBkgColor: mono ? tint(0, 0.3) : tint(3, 0.3), critBorderColor: caution,
    todayLineColor: caution, gridColor: hairline, vertLineColor: muted,
    pieTitleTextColor: v("heading"), pieSectionTextColor: text, pieLegendTextColor: text,
    pieStrokeColor: bg, pieOuterStrokeColor: hairline, pieOpacity: "1",
    errorBkgColor: codeBg, errorTextColor: text,
  };
  for (let i = 0; i < 12; i++) {
    tv["pie" + (i + 1)] = tint(i, [0.5, 0.3, 0.16, 0.08][Math.floor(i / accents.length) % 4]);
    // Mindmap and timeline sections: mermaid darkens these by 25 (light) or 75 (dark) lightness
    // points itself, hence the high lightness; the label is the text, deepened if it needs to be.
    const fill = withLightness(accents[i % accents.length], dark ? 0.97 : 0.94);
    const shown = withLightness(fill, dark ? 0.22 : 0.69);
    let label = text;
    for (let t = 0.1; contrast(label, shown) < 4.5 && t <= 1; t += 0.1) label = mixHex(text, dark ? "#ffffff" : "#000000", t);
    tv["cScale" + i] = fill;
    tv["cScaleLabel" + i] = label;
  }
  const config = {
    startOnLoad: false, securityLevel: "strict", htmlLabels: false, suppressErrorRendering: true,
    // Nor restyle it: themeCSS could load url(https://…), and the theme and fonts are the reader's.
    secure: ["secure", "securityLevel", "startOnLoad", "maxTextSize", "suppressErrorRendering", "maxEdges", "htmlLabels",
      "themeCSS", "themeVariables", "fontFamily", "altFontFamily"],
    theme: "base", themeVariables: tv, fontFamily: tv.fontFamily,
  };
  // Natural size, never shrunk to the column: style.css lets a wide figure use the window's width
  // and scroll inside itself beyond that, so labels keep the reading size.
  for (const d of DIAGRAM_TYPES) config[d] = { useMaxWidth: false };
  return config;
}

// Draws one figure from its source; a failure shows the code and a one-line error.
async function drawDiagram(fig) {
  const src = diagramSource.get(fig);
  const config = diagramConfig(), key = JSON.stringify(config);
  if (key !== diagramKey) { diagramKey = key; diagramSVG = new Map(); mermaid.initialize(config); }
  let svg = diagramSVG.get(src);
  if (!svg) {
    const id = "midam-diagram-" + ++diagramCount;
    try {
      await document.fonts.ready; // mermaid measures its labels in the reading font
      svg = (await mermaid.render(id, src)).svg;
      if (diagramSVG.size > 100) diagramSVG.clear();
      diagramSVG.set(src, svg);
    } catch (e) {
      for (const x of [id, "d" + id]) document.getElementById(x)?.remove(); // mermaid's scratch nodes
      const pre = document.createElement("pre"), note = document.createElement("p");
      pre.appendChild(document.createElement("code")).textContent = src;
      note.className = "diagram-error";
      const label = typeof diagramWords.diagram === "string" ? diagramWords.diagram : "Diagram could not be drawn";
      note.textContent = label + ": " + (String(e?.message || e).split("\n").find(l => l.trim()) || "").slice(0, 160);
      keepPlace(fig, () => fig.replaceChildren(pre, note));
      return;
    }
  }
  keepPlace(fig, () => { fig.innerHTML = svg; }); // mermaid's output, sanitised by it under securityLevel "strict"; page script is off
}

// Changes a figure; one on screen that starts above the reading line scrolls the page by its
// change in height, so the text being read stays put (unless the browser's scroll anchoring did).
function keepPlace(fig, change) {
  const on = fig.isConnected, top = on ? fig.getBoundingClientRect().top : 0, height = on ? fig.offsetHeight : 0, y = scrollY;
  change();
  const grown = on ? fig.offsetHeight - height : 0; // the layout, and any anchoring, happen here
  if (grown && top < headerInset && scrollY === y) scrollBy(0, grown);
}

// After a theme or font change, redraw the diagrams on screen in the new colours.
function redrawDiagrams() {
  if (typeof mermaid === "undefined") return;
  const figs = [...document.querySelectorAll("body > #content figure.diagram")];
  if (figs.length && JSON.stringify(diagramConfig()) !== diagramKey) for (const f of figs) drawDiagram(f);
}

// Sets el to text with highlight.js colour spans. The highlighted markup is parsed inert and
// accepted only if it is nothing but class-only <span>s whose text is exactly the input;
// otherwise the plain text is used. Either way the text goes in as text, never as HTML.
function tint(el, text, language) {
  const t = document.createElement("template");
  t.innerHTML = hljs.highlight(text, { language, ignoreIllegals: true }).value;
  const spansOnly = [...t.content.querySelectorAll("*")].every(
    e => e.tagName === "SPAN" && [...e.attributes].every(a => a.name === "class"));
  if (spansOnly && t.content.textContent === text) el.replaceChildren(t.content);
  else el.textContent = text;
  el.classList.add("hljs");
}

// Vim-style page keys (d u e f b): a fraction of the page visible below the header, less a line
// of overlap so the reader keeps their place; smooth unless Reduce Motion is on. Both views.
const pageStep = (height, header, fraction) => Math.max(40, Math.round((height - header - 40) * fraction));
function midamScrollPage(fraction) {
  const smooth = !matchMedia("(prefers-reduced-motion: reduce)").matches;
  scrollBy({ top: Math.sign(fraction) * pageStep(innerHeight, headerInset, Math.abs(fraction)), behavior: smooth ? "smooth" : "auto" });
}

// Switches between the reading and source views, keeping the reading position by proportion.
function midamSetView(source) {
  const room = () => Math.max(1, document.documentElement.scrollHeight - innerHeight);
  const ratio = scrollY / room();
  document.documentElement.dataset.view = source ? "source" : "reading";
  scrollTo(0, Math.round(ratio * room()));
  spy(true);
}

// Reading settings, as CSS custom properties on <html>. Values arrive as call arguments, never
// as source: numbers are clamped, and font names (already checked against the installed
// families) are written as quoted CSS strings, so a name can never end the value.
function cssString(s) {
  return '"' + String(s).replace(/[\\"\x00-\x1f\x7f]/g, c => "\\" + c.charCodeAt(0).toString(16) + " ") + '"';
}

// The page runs under the window's floating header; its height keeps the first line and
// find results clear of it.
let headerInset = 40;

function midamStyle(s) {
  const st = document.documentElement.style;
  const num = (v, lo, hi, d) => (Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d);
  st.setProperty("--scale", String(num(s.size, 0.7, 2, 1)));
  st.setProperty("--tracking", num(s.tracking, -0.03, 0.08, 0) + "em");
  st.setProperty("--leading", String(num(s.leading, 1.3, 2.4, 2.05)));
  st.setProperty("--para", num(s.paragraph, 0.4, 2.2, 1.15) + "em");
  st.setProperty("--measure", num(s.measure, 26, 60, 36) + "em");
  const inset = num(s.header, 0, 120, 40), shift = inset - headerInset;
  headerInset = inset;
  st.setProperty("--header", inset + "px");
  // The header hidden or shown (immersive mode): the text moves by the change, so a page read
  // partway down scrolls with it and the line being read stays put.
  if (shift && scrollY > 0) scrollBy(0, shift);
  for (const [prop, name] of [["--font", s.font], ["--code-font", s.mono]]) {
    if (typeof name === "string" && name) st.setProperty(prop, cssString(name) + ",");
    else st.removeProperty(prop);
  }
  // The colour theme that applies now (the app picks the light or the dark one): token names
  // and #rrggbb values only; anything else is dropped. The monochrome theme marks keywords by weight.
  for (const [k, v] of Object.entries(s.colors || {})) {
    if (/^[a-z]+(-[a-z]+)*$/.test(k) && /^#[0-9a-f]{6}$/i.test(v)) st.setProperty("--" + k, v);
  }
  document.documentElement.toggleAttribute("data-mono", s.monochrome === true);
  if (!fontFaces && Array.isArray(s.faces)) addFaces(s.faces);
  redrawDiagrams();
  findLayout();
}

// The fonts bundled in the app, as @font-face rules in one <style>, added once. WebKit renders
// in its own process, which the app's font registration does not reach; the app serves the files
// as midam-font:///<name>.woff2 (CSP font-src midam-font:). Every part is checked (family name,
// a plain midam-font file name, weight, style) and the strings go in as quoted CSS strings.
let fontFaces = null;

function addFaces(list) {
  const rules = [];
  for (const f of list) {
    if (!f || typeof f.family !== "string" || !/^[A-Za-z0-9 ._-]{1,64}$/.test(f.family)) continue;
    if (typeof f.url !== "string" || !/^midam-font:\/\/\/[A-Za-z0-9._-]+\.woff2$/.test(f.url) || f.url.includes("..")) continue;
    if (typeof f.weight !== "string" || !/^\d{1,3}( \d{1,3})?$/.test(f.weight)) continue;
    const style = f.style === "italic" ? "italic" : "normal";
    rules.push("@font-face { font-family: " + cssString(f.family) + "; src: url(" + cssString(f.url) +
      ') format("woff2"); font-weight: ' + f.weight + "; font-style: " + style + "; font-display: swap; }");
  }
  fontFaces = document.createElement("style");
  fontFaces.textContent = rules.join("\n");
  document.head.appendChild(fontFaces);
}

// Find: each match gets a box in a layer over the page, built from the match's line boxes. The
// layer is a child of <html>, outside both views, so the page's DOM, selection, copy and the render
// cache never see it, and closing find removes it: nothing stays painted. (The CSS Custom Highlight
// API painted the boxes offset upward and left them on screen after closing in the system WebKit.)
// ponytail: matches within one text node only; a query spanning e.g. **bold** edges is not found.
let finds = [], current = -1, findLayer = null, findFrame = 0, findBand = [0, 0];

function midamFind(q, keep) {
  finds = [];
  if (q) {
    const re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "giu");
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, visibleText); // whichever view shows
    for (let n; (n = walk.nextNode()); ) {
      for (const m of n.data.matchAll(re)) {
        const r = new Range();
        r.setStart(n, m.index);
        r.setEnd(n, m.index + m[0].length);
        finds.push(r);
      }
    }
  }
  // Start at the first match on screen; after a reload keep the same match number.
  current = !finds.length ? -1 : keep > 0 ? Math.min(keep, finds.length) - 1 : firstBelow(0) % finds.length;
  return { ...midamFindPaint(keep <= 0), matches: findList() };
}

function midamFindStep(d) {
  if (finds.length) current = (current + d + finds.length) % finds.length;
  return midamFindPaint(true);
}

// A row of the app's find list was clicked: match i (0-based) becomes current, scrolled to.
function midamFindGo(i) {
  if (i >= 0 && i < finds.length) current = i;
  return midamFindPaint(true);
}

function midamFindPaint(reveal) {
  drawFinds();
  if (current >= 0) {
    const b = finds[current].getBoundingClientRect();
    if (reveal && (b.top < headerInset + 48 || b.bottom > innerHeight - 24)) scrollBy(0, b.top - innerHeight / 3);
  }
  return { index: current + 1, count: finds.length };
}

const visibleText = { acceptNode: n => (n.parentElement.checkVisibility() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT) };

// The app's find list: the first FIND_LIST matches, each {before, hit, after, path}: the line around
// it (whitespace collapsed, about 80 characters, one line of code in a code block) and the texts of
// the headings it sits under, outermost first. In 원본 the headings are the Markdown's # lines.
const FIND_LIST = 500;
function findList() {
  const pre = document.documentElement.dataset.view === "source" && document.querySelector("body > #source");
  let heads, after;
  if (pre) { // positions as character offsets into the source
    heads = sourceHeads(pre.textContent);
    const starts = new Map();
    let n = 0;
    for (const w = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT); w.nextNode(); n += w.currentNode.data.length) starts.set(w.currentNode, n);
    after = (head, r) => head.at <= starts.get(r.startContainer) + r.startOffset;
  } else {
    heads = [...document.querySelectorAll("body > #content :is(h1,h2,h3,h4,h5,h6)")]
      .map(h => ({ h, level: Number(h.tagName[1]), text: outlineText(h) })).filter(x => x.text);
    after = (head, r) => head.h.compareDocumentPosition(r.startContainer) & Node.DOCUMENT_POSITION_FOLLOWING;
  }
  const path = [];
  let next = 0;
  return finds.slice(0, FIND_LIST).map(r => {
    for (; next < heads.length && after(heads[next], r); next++) {
      while (path.length && path.at(-1).level >= heads[next].level) path.pop();
      path.push(heads[next]);
    }
    return { ...around(r), path: path.map(x => x.text) };
  });
}

// The # headings of Markdown source, outside code fences and front matter: {at (offset of the
// line), level, text}. (highlight.js's own sections lose their way after a fence nested in a list.)
function sourceHeads(text) {
  const heads = [], front = /^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(text);
  let at = front ? front[0].length : 0, fence = "";
  for (const line of text.slice(at).split("\n")) {
    const f = /^ {0,3}(`{3,}|~{3,})/.exec(line), h = !fence && !f && /^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/.exec(line);
    if (f && !fence) fence = f[1][0];
    else if (f && f[1][0] === fence) fence = "";
    const t = h ? h[2].replace(/\s+/g, " ").trim() : "";
    if (t) heads.push({ at, level: h[1].length, text: Array.from(t).slice(0, 200).join("") });
    at += line.length + 1;
  }
  return heads;
}

// The text either side of a match within its block, read from the text nodes next to it only as
// far as needed (a long code block or table costs no more than a short paragraph).
const blockOf = el => el.closest("p,li,dt,dd,td,th,h1,h2,h3,h4,h5,h6,pre,blockquote,figcaption,summary") || el;
function around(r) {
  const node = r.startContainer, block = blockOf(node.parentElement), code = block.tagName === "PRE";
  const walk = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, visibleText);
  let before = node.data.slice(Math.max(0, r.startOffset - 200), r.startOffset), after = node.data.slice(r.endOffset, r.endOffset + 200);
  walk.currentNode = node;
  for (let t; before.length < 120 && !(code && before.includes("\n")) && (t = walk.previousNode()); ) before = t.data + before;
  walk.currentNode = node;
  for (let t; after.length < 120 && !(code && after.includes("\n")) && (t = walk.nextNode()); ) after += t.data;
  if (code) { before = before.slice(before.lastIndexOf("\n") + 1); after = after.split("\n")[0]; }
  const squash = s => s.replace(/\s+/g, " ");
  const hit = squash(r.toString()).slice(0, 80);
  before = squash(before).trimStart();
  after = squash(after).trimEnd();
  const rest = Math.max(30, 80 - hit.length); // what the line keeps either side, mostly after the match
  const keepBefore = Math.min(before.length, Math.max(Math.floor(rest * 0.4), rest - after.length)), keepAfter = rest - keepBefore;
  if (before.length > keepBefore) before = "…" + before.slice(-keepBefore).trimStart();
  if (after.length > keepAfter) after = after.slice(0, keepAfter).trimEnd() + "…";
  return { before, hit, after };
}

function midamFindClear() {
  finds = [];
  current = -1;
  drawFinds();
}

// The first match whose bottom is below y (window px), by bisection: matches run down the page.
function firstBelow(y) {
  let lo = 0, hi = finds.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (finds[mid].getBoundingClientRect().bottom > y) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

// The boxes in page coordinates (they scroll with the page), each cut to the blocks that scroll
// sideways around it (code, wide tables, diagrams, formulas), so a match scrolled out of its block
// shows no box. Only the matches from a screen above to a screen below the window get boxes (a
// one-letter query in a long page has thousands); scrolling near the band's edge draws a new one.
// Rebuilt whole: on a query or step, and when the layout moves the text (findLayout).
// ponytail: assumes matches run down the page in document order (one column); a match out of
// order more than a screen away from its neighbours gets no box.
function drawFinds() {
  findLayer?.remove();
  findLayer = null;
  if (!finds.length) return;
  const layer = document.documentElement.appendChild(document.createElement("div"));
  layer.className = "midam-find";
  const o = layer.getBoundingClientRect(), clips = new Map(), boxes = document.createDocumentFragment();
  findBand = [scrollY - innerHeight, scrollY + 2 * innerHeight];
  for (let i = firstBelow(-innerHeight); i < finds.length; i++) {
    const r = finds[i], rects = r.getClientRects();
    if (rects.length && rects[0].top > 2 * innerHeight) break;
    const c = clipOf(r.startContainer.parentElement, clips);
    for (const b of rects) {
      const left = Math.max(b.left, c.left), right = Math.min(b.right, c.right);
      const top = Math.max(b.top, c.top), bottom = Math.min(b.bottom, c.bottom);
      if (right - left < 0.5 || bottom - top < 0.5) continue; // cut away, or a match whose text is gone (re-render)
      const box = boxes.appendChild(document.createElement("div"));
      if (i === current) box.className = "current";
      box.style.cssText = `left:${left - o.left}px;top:${top - o.top}px;width:${right - left}px;height:${bottom - top}px`;
    }
  }
  layer.appendChild(boxes);
  findLayer = layer;
}

// The visible area of el's clipping HTML ancestors (SVG parts have no client box), cached per element.
function clipOf(el, cache) {
  if (!el || el === document.body) return { left: -Infinity, top: -Infinity, right: Infinity, bottom: Infinity };
  let c = cache.get(el);
  if (c) return c;
  c = clipOf(el.parentElement, cache);
  const s = el instanceof HTMLElement && getComputedStyle(el);
  if (s && (s.overflowX !== "visible" || s.overflowY !== "visible")) {
    const b = el.getBoundingClientRect(), x = b.left + el.clientLeft, y = b.top + el.clientTop;
    c = { left: Math.max(c.left, x), top: Math.max(c.top, y), right: Math.min(c.right, x + el.clientWidth), bottom: Math.min(c.bottom, y + el.clientHeight) };
  }
  cache.set(el, c);
  return c;
}

// Text moves without a find call when the window or a block resizes, images load, a diagram is
// drawn, fonts arrive, reading settings change (midamStyle) or a block scrolls sideways, and when
// the page scrolls within half a screen of the drawn band: redraw once per frame then. (A
// re-render or view switch calls midamFind again from the app.)
function findLayout() {
  if (finds.length && !findFrame) findFrame = requestAnimationFrame(() => { findFrame = 0; drawFinds(); });
}
if (globalThis.ResizeObserver) { // the Node tests load this file without a page
  new ResizeObserver(findLayout).observe(document.body);
  document.fonts.addEventListener("loadingdone", findLayout);
  document.addEventListener("scroll", e => {
    if (e.target !== document || scrollY - innerHeight / 2 < findBand[0] || scrollY + 1.5 * innerHeight > findBand[1]) findLayout();
  }, { capture: true, passive: true });
}

// MARK: Changes since last read (V3). The reading view's blocks that differ from the version last
// read (the app's baseline) are marked by their data-blk (markdown.js): a changed block gets a bar
// at its left, an added one the bar and a faint tint (style.css), and each removed run of blocks
// one collapsed line in its place that opens to show the removed text. Marks are made after a
// render swaps in and never reach the render cache (unmarked). Returns the number of places.
let marked_ = { baseline: null, md: "" }, changePlaces = [];
function midamMarks(baseline, md) {
  if (md !== undefined) marked_ = { baseline, md };
  else marked_.baseline = baseline; // the app's "read now": same text, new baseline
  const root = document.querySelector("body > #content");
  clearMarks(root);
  changePlaces = [];
  if (marked_.baseline == null || marked_.baseline === marked_.md) return 0;
  let diff;
  try { diff = midamDiff(marked_.baseline, marked_.md); } catch { return 0; }
  const el = j => {
    const e = root.querySelector('[data-blk="' + j + '"]');
    return e && e.parentElement.classList.contains("table-wrap") ? e.parentElement : e;
  };
  const shown = diff.ops.map(o => (o.new === undefined ? null : el(o.new))); // per op: its element on screen
  for (const place of diff.places) {
    let first = null;
    for (let k = 0; k < place.length; k++) {
      const o = diff.ops[place[k]];
      if (o.op === "removed") {
        // A run of removed blocks: one line, before the next block on screen (or after the last).
        let n = k;
        while (n + 1 < place.length && diff.ops[place[n + 1]].op === "removed") n++;
        const run = place.slice(k, n + 1).map(i => diff.ops[i]);
        const after = shown.slice(place[n] + 1).find(Boolean), before = shown.slice(0, place[k]).reverse().find(Boolean);
        const line = removedLine(run, (after || before)?.tagName === "LI");
        if (after) after.before(line); else if (before) before.after(line); else root.append(line);
        first ||= line;
        k = n;
      } else if (shown[place[k]]) {
        shown[place[k]].classList.add(o.op === "added" ? "midam-added" : "midam-changed");
        first ||= shown[place[k]];
      }
    }
    if (first) changePlaces.push(first);
  }
  return diff.count;
}

function clearMarks(root) {
  for (const e of root.querySelectorAll(".midam-removed")) e.remove();
  for (const e of root.querySelectorAll(".midam-changed, .midam-added")) e.classList.remove("midam-changed", "midam-added");
}

// The content's HTML without the marks, for the render cache.
function unmarked(root) {
  const copy = root.cloneNode(true);
  clearMarks(copy);
  return copy.innerHTML;
}

// "Deleted: <first words>, N lines" (the app's words); Return or a click shows the removed text.
function removedLine(run, inList) {
  const w = diagramWords, lines = run.reduce((n, o) => n + o.lines, 0);
  const line = document.createElement(inList ? "li" : "div");
  line.className = "midam-removed";
  const head = line.appendChild(document.createElement("span"));
  head.className = "midam-removed-head";
  head.tabIndex = 0;
  head.setAttribute("role", "button");
  head.setAttribute("aria-expanded", "false");
  head.textContent = (w.deleted || "Deleted: {words}, {n}").replace("{words}", run[0].firstWords)
    .replace("{n}", (lines === 1 ? w.line || "1 line" : w.lines || "{n} lines").replace("{n}", lines));
  const body = line.appendChild(document.createElement("div"));
  body.className = "midam-removed-body";
  body.hidden = true;
  body.textContent = run.map(o => o.raw.trimEnd()).join("\n\n");
  return line;
}

function toggleRemoved(head) {
  const body = head.nextElementSibling, open = body.hidden;
  body.hidden = !open;
  head.setAttribute("aria-expanded", String(open));
}
globalThis.addEventListener?.("click", e => {
  const head = e.target instanceof Element && e.target.closest(".midam-removed-head");
  if (head) toggleRemoved(head);
});
globalThis.addEventListener?.("keydown", e => {
  if (e.key === "Enter" && e.target instanceof Element && e.target.matches(".midam-removed-head")) { e.preventDefault(); toggleRemoved(e.target); }
});

// n / N: the next or previous place below or above the reading line (wrapping), scrolled under
// the header and flashed. Returns {index, count} (1-based; 0 when there are none).
function midamChangeStep(d) {
  const places = changePlaces.filter(e => e.isConnected);
  if (!places.length || document.documentElement.dataset.view === "source") return { index: 0, count: places.length };
  const line = headerInset + 24;
  const tops = places.map(e => e.getBoundingClientRect().top);
  let i = d > 0 ? tops.findIndex(t => t > line + 4) : tops.findLastIndex(t => t < line - 4);
  if (i < 0) i = d > 0 ? 0 : places.length - 1;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  scrollBy({ top: tops[i] - line, behavior: reduce ? "auto" : "smooth" });
  flash(places[i]);
  return { index: i + 1, count: places.length };
}
function flash(e) {
  e.classList.remove("midam-flash");
  void e.offsetWidth; // restart the animation
  e.classList.add("midam-flash");
  setTimeout(() => e.classList.remove("midam-flash"), 1200);
}

// V6 reply. The source lines an element came from: its nearest data-src (markdown.js), [first, last].
function srcLines(node) {
  const el = (node?.nodeType === 1 ? node : node?.parentElement)?.closest("[data-src]");
  const m = el && /^(\d+)-(\d+)$/.exec(el.getAttribute("data-src"));
  return m ? [Number(m[1]), Number(m[2])] : null;
}

// The selected passage in the reading view, for a note: {quote, start, end} (source lines of the
// blocks the selection starts and ends in), or null.
function midamSelection() {
  const sel = getSelection();
  if (!sel || sel.isCollapsed || !sel.rangeCount || document.documentElement.dataset.view === "source") return null;
  const r = sel.getRangeAt(0), content = document.querySelector("body > #content");
  if (!content?.contains(r.commonAncestorContainer)) return null;
  // A triple click ends at the start of the next block: that block is not part of it.
  const endNode = r.endOffset === 0 && r.endContainer !== r.startContainer
    ? (r.endContainer.previousSibling ?? r.endContainer.parentElement?.previousElementSibling ?? r.endContainer) : r.endContainer;
  const quote = sel.toString().trim(), a = srcLines(r.startContainer), b = srcLines(endNode) ?? a;
  if (!quote || !a) return null;
  return { quote, start: Math.min(a[0], b[0]), end: Math.max(a[1], b[1]) };
}

// The 메모 / Note button by a selection; a click asks the app for a note (as the m key does).
let noteButton = null, noteTimer = 0;
function placeNoteButton() {
  const s = midamSelection();
  if (!s) { if (noteButton) noteButton.hidden = true; return; }
  if (!noteButton) {
    noteButton = document.createElement("button");
    noteButton.id = "midam-note";
    noteButton.type = "button";
    noteButton.addEventListener("mousedown", e => e.preventDefault()); // keeps the selection
    noteButton.addEventListener("click", () => {
      noteButton.hidden = true;
      window.webkit?.messageHandlers?.midamToc?.postMessage({ note: true });
    });
    document.body.appendChild(noteButton);
  }
  noteButton.textContent = diagramWords.memo || "Note";
  const rects = getSelection().getRangeAt(0).getClientRects(), last = rects[rects.length - 1];
  if (!last) return;
  noteButton.hidden = false;
  noteButton.style.top = `${last.bottom + scrollY + 6}px`;
  noteButton.style.left = `${Math.max(8, Math.min(last.right - noteButton.offsetWidth, innerWidth - noteButton.offsetWidth - 16)) + scrollX}px`;
}
globalThis.document?.addEventListener("selectionchange", () => {
  clearTimeout(noteTimer);
  noteTimer = setTimeout(placeNoteButton, 120);
});

// Scrolls source line n under the header and flashes it: the innermost block holding it, else the
// first one after it. For a note's row and midam://open?line=.
function midamGoLine(n, smooth) {
  let best = null, span = Infinity, after = null;
  for (const el of document.querySelectorAll("body > #content [data-src]")) {
    const l = srcLines(el);
    if (!l) continue;
    if (l[0] <= n && n <= l[1] && l[1] - l[0] <= span) { best = el; span = l[1] - l[0]; }
    else if (!after && l[0] > n) after = el;
  }
  const el = best || after;
  if (!el) return false;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  scrollBy({ top: el.getBoundingClientRect().top - (headerInset + 24), behavior: smooth && !reduce ? "smooth" : "auto" });
  flash(el);
  return true;
}

// A link's #fragment, or midam-line-<n> for a source line (Store.handle).
function midamScrollTo(id) {
  const m = /^midam-line-(\d+)$/.exec(id);
  if (m) return midamGoLine(Number(m[1]), false);
  document.getElementById(id)?.scrollIntoView();
}
