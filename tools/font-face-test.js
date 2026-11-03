// Runs render.js midamStyle() with bundled-font faces against a stub document and checks the
// generated @font-face rules: valid faces become one rule each, hostile ones are dropped, and
// the rules are added only once.
const fs = require("fs"), path = require("path");
const src = fs.readFileSync(path.join(__dirname, "../Resources/render.js"), "utf8");
const styles = [];
const doc = {
  documentElement: { style: { setProperty() {}, removeProperty() {} }, toggleAttribute() {} },
  head: { appendChild: el => styles.push(el) },
  createElement: () => ({ textContent: "" }),
};
const midamStyle = new Function("document", src + "\nreturn midamStyle;")(doc);
const url = "midam-font:///";
midamStyle({
  faces: [
    { family: "Pretendard Variable", url: url + "PretendardVariable.woff2", weight: "100 900", style: "normal" },
    { family: "D2Coding", url: url + "D2Coding-Bold.woff2", weight: "700", style: "italic" },
    { family: 'x"; } body { display: none } @font-face { font-family: "y', url: url + "a.woff2", weight: "400" },
    { family: "Evil", url: "https://example.com/a.woff2", weight: "400" },
    { family: "Evil", url: "file:///Applications/Midam.app/Contents/Resources/Fonts/a.woff2", weight: "400" },
    { family: "Evil", url: url + "../../etc/a.woff2", weight: "400" },
    { family: "Evil", url: url + "sub/a.woff2", weight: "400" },
    { family: "Evil", url: url + "..woff2", weight: "400" },
    { family: "Evil", url: "midam-font://host/a.woff2", weight: "400" },
    { family: "Evil", url: url + 'a.woff2") ; } body{color:red} x{ ("', weight: "400" },
    { family: "Evil", url: url + "a.ttf", weight: "400" },
    { family: "Evil", url: url + "a.woff2", weight: "400; color: red" },
    { family: "Evil", url: url + "a.woff2", weight: 400 },
    null, "x",
  ],
});
midamStyle({ faces: [{ family: "Again", url: url + "b.woff2", weight: "400" }] });
const css = styles.map(s => s.textContent).join("\n");
const rules = css.split("\n").filter(Boolean);
const ok = styles.length === 1 && rules.length === 2 && !/Evil|Again|display: none|color: ?red/.test(css) &&
  rules[0] === '@font-face { font-family: "Pretendard Variable"; src: url("' + url + 'PretendardVariable.woff2") format("woff2"); font-weight: 100 900; font-style: normal; font-display: swap; }' &&
  /font-weight: 700; font-style: italic;/.test(rules[1]);
console.log(ok ? "bundled fonts: 2 valid faces become rules once; 13 hostile ones are dropped" : "FAILED\n" + css);
process.exit(ok ? 0 : 1);
