// Runs render.js diagramConfig() against every colour theme in Resources/themes.json and checks the
// mermaid settings: strict security, no HTML labels, neither overridable from a diagram's
// %%{init}%%; body text at least 4.5:1 on every fill; the monochrome theme stays grey.
// (Mermaid itself needs a DOM, so drawing the hostile sample is a GUI check.) Run: node tools/diagram-test.js
const fs = require("fs"), path = require("path"), R = path.join(__dirname, "../Resources/");
const src = fs.readFileSync(R + "render.js", "utf8"), themes = JSON.parse(fs.readFileSync(R + "themes.json", "utf8"));
let colors = {}, mono = false;
const doc = { documentElement: { hasAttribute: n => n === "data-mono" && mono }, body: {} };
const gcs = el => (el === doc.body ? { fontFamily: '"Pretendard Variable", sans-serif', fontSize: "17px" }
  : { getPropertyValue: n => colors[n.slice(2)] || "" });
const [diagramConfig, contrast, withLightness] = new Function("document", "getComputedStyle",
  src + "\nreturn [diagramConfig, contrast, withLightness];")(doc, gcs);
let bad = 0, n = 0;
const check = (name, ok) => { n++; if (!ok) { bad++; console.log("FAIL", name); } };

colors = themes.light[0].colors; mono = true;
const c = diagramConfig();
check("startOnLoad off", c.startOnLoad === false);
check("strict", c.securityLevel === "strict");
check("no HTML labels", c.htmlLabels === false);
check("error bombs suppressed", c.suppressErrorRendering === true);
for (const k of ["secure", "securityLevel", "startOnLoad", "htmlLabels", "maxTextSize", "suppressErrorRendering", "themeCSS", "themeVariables", "fontFamily", "altFontFamily"]) check("secure " + k, c.secure.includes(k));
// A hostile %%{init}%% directive, through mermaid 12.2's own directive sanitiser (its rule, restated):
// secure keys are dropped, then "__" keys, then strings holding < > or url(data:, at every depth.
const sanitize = (t, secure) => {
  for (const k of ["secure", ...secure]) delete t[k];
  for (const k of Object.keys(t)) if (k.startsWith("__")) delete t[k];
  for (const k of Object.keys(t)) {
    if (typeof t[k] === "string" && /[<>]|url\(data:/.test(t[k])) delete t[k];
    else if (t[k] && typeof t[k] === "object") sanitize(t[k], []);
  }
  return t;
};
const directive = sanitize({ securityLevel: "loose", htmlLabels: true, startOnLoad: true, secure: [],
  themeCSS: "svg { background: url(https://example.com/t.png) }", fontFamily: "url(https://example.com/f)", altFontFamily: "x",
  themeVariables: { primaryColor: "#ff0000", fontFamily: "Evil" }, flowchart: { curve: "basis" } }, c.secure);
check("hostile directive keeps only harmless keys", JSON.stringify(directive) === '{"flowchart":{"curve":"basis"}}');
check("base theme", c.theme === "base");
for (const d of ["flowchart", "sequence", "gantt", "class", "state", "er", "pie", "mindmap", "timeline"]) check("natural size " + d, c[d]?.useMaxWidth === false);
check("reading font", c.themeVariables.fontFamily.includes("Pretendard") && c.themeVariables.fontSize === "15px");

const fills = ["primaryColor", "secondaryColor", "tertiaryColor", "mainBkg", "clusterBkg", "noteBkgColor", "actorBkg", "labelBoxBkgColor",
  "taskBkgColor", "activeTaskBkgColor", "doneTaskBkgColor", "critBkgColor", "sectionBkgColor", "edgeLabelBackground", "background"]
  .concat([...Array(12)].map((_, i) => "pie" + (i + 1)));
let worst = 99;
for (const mode of ["light", "dark"]) for (const t of themes[mode]) {
  colors = t.colors; mono = t.mono;
  const tv = diagramConfig().themeVariables;
  check(t.id + " darkMode", tv.darkMode === (mode === "dark"));
  for (const k of fills) {
    const r = contrast(tv.textColor, tv[k]); worst = Math.min(worst, r);
    if (r < 4.5) check(`${mode} ${t.id}: text on ${k} ${r.toFixed(2)}:1`, false);
  }
  for (let i = 0; i < 12; i++) { // mermaid darkens cScale by 25 (light) or 75 (dark) lightness points
    const r = contrast(tv["cScaleLabel" + i], withLightness(tv["cScale" + i], tv.darkMode ? 0.22 : 0.69)); worst = Math.min(worst, r);
    if (r < 4.5) check(`${mode} ${t.id}: label on cScale${i} ${r.toFixed(2)}:1`, false);
  }
  if (t.mono) { // grey only: every colour's channels within a few steps of each other
    const hexes = Object.values(tv).filter(v => typeof v === "string" && /^#[0-9a-f]{6}$/i.test(v));
    const chroma = h => { const v = [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)); return Math.max(...v) - Math.min(...v); };
    check(`${mode} ${t.id}: monochrome`, hexes.length > 40 && hexes.every(h => chroma(h) <= 12));
  }
  n++;
}
console.log(bad ? `FAILED ${bad} of ${n}` : `diagrams: ${n} checks passed (strict, no HTML labels, text on fills >= ${worst.toFixed(2)}:1 in every theme, Midam grey)`);
process.exit(bad ? 1 : 0);
