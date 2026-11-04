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
async function midamRender(md, base, words) {
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
  } else shown.replaceWith(next);
  cachedHTML = null;
  document.querySelector("body > #source").replaceWith(source);
  startSpy();
  tocHeads = outlineHeads(root);
  spySent = currentHeading(); // reported with the outline; the spy sends only changes from here
  lap("swap", t);
  lap("total", t0);
  const result = { outline: midamOutline(tocHeads), current: spySent, html: html.length <= 10000000 ? html : null, timing };
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
  const html = document.querySelector("body > #content").innerHTML;
  return gen === renders && html.length <= 10000000 ? html : null;
}

// A cached render from the app (the last finished 읽기 page of this file, made with the same file,
// settings and build), shown at once while the real render runs; it goes in as an argument, as
// inert as a fresh render (page script is off, CSP blocks scripts). The real render then keeps
// these nodes if it comes out the same (sameRender), or replaces them. Diagram ids are numbered on
// from the cached ones, since mermaid removes any element that already holds the id it draws under.
let cachedHTML = null;
const sameRender = (a, b) => a.replace(/midam-diagram-\d+/g, "") === b.replace(/midam-diagram-\d+/g, "");
function midamShowCached(html, base) {
  setBase(base);
  const shown = document.querySelector("body > #content");
  shown.innerHTML = html;
  cachedHTML = html;
  for (const m of html.matchAll(/midam-diagram-(\d+)/g)) diagramCount = Math.max(diagramCount, Number(m[1]));
  startSpy();
  tocHeads = outlineHeads(shown);
  spySent = currentHeading();
  return { outline: midamOutline(tocHeads), current: spySent };
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

// Table of contents: the reading view's h1-h3 as plain text (the app shows it as SwiftUI Text),
// with ids and sizes bounded. Headings without text or an id are left out.
const outlineText = h => {
  const t = h.textContent.replace(/\s+/g, " ").trim();
  return t.length > 200 ? Array.from(t).slice(0, 200).join("") : t;
};
const outlineHeads = root =>
  [...root.querySelectorAll("h1,h2,h3")].filter(h => h.id && h.id.length <= 512 && outlineText(h)).slice(0, 500);
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

// Find: matches are painted with the CSS Custom Highlight API, so the DOM is never touched.
// ponytail: matches within one text node only; a query spanning e.g. **bold** edges is not found.
let finds = [], current = -1;

function midamFind(q, keep) {
  finds = [];
  if (q) {
    const re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "giu");
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { // whichever view shows
      acceptNode: n => (n.parentElement.checkVisibility() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT),
    });
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
  current = keep > 0 ? Math.min(keep, finds.length) - 1 : finds.findIndex(r => r.getBoundingClientRect().bottom > 0);
  if (current < 0 && finds.length) current = 0;
  return midamFindPaint(keep <= 0);
}

function midamFindStep(d) {
  if (finds.length) current = (current + d + finds.length) % finds.length;
  return midamFindPaint(true);
}

// Clear, then set under fresh names: the system WebKit (before 319154@main, webkit.org/b/321567)
// repaints nothing when set() replaces a registered highlight, so the last query's boxes stayed
// painted (and later half-repainted) after the query changed or find closed. clear() repaints the
// old ranges; a new name repaints the new ones.
function midamFindPaint(reveal) {
  CSS.highlights.clear();
  CSS.highlights.set("midam-find", new Highlight(...finds));
  if (current >= 0) {
    CSS.highlights.set("midam-current", new Highlight(finds[current]));
    const b = finds[current].getBoundingClientRect();
    if (reveal && (b.top < headerInset + 48 || b.bottom > innerHeight - 24)) scrollBy(0, b.top - innerHeight / 3);
  }
  return [current + 1, finds.length];
}

function midamFindClear() {
  finds = [];
  current = -1;
  CSS.highlights.clear();
}
