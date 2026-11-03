// Runs render.js midamStyle() against a stub <html> and checks theme colours: only token names
// with #rrggbb values become custom properties; hostile keys and values are dropped.
const fs = require("fs"), path = require("path");
const src = fs.readFileSync(path.join(__dirname, "../Resources/render.js"), "utf8");
const set = {}, attrs = {};
const root = {
  style: { setProperty: (k, v) => (set[k] = v), removeProperty: k => delete set[k] },
  toggleAttribute: (n, on) => (attrs[n] = on),
};
const midamStyle = new Function("document", src + "\nreturn midamStyle;")({ documentElement: root });
midamStyle({
  monochrome: true,
  colors: {
    bg: "#fbfaf7", "code-bg": "#F2F0EB", "tk-keyword": "#2b2a27",
    text: "red", link: "#123", quote: "#12345678", heading: "#2b2a27; color: red", code: "var(--bg)",
    "x;y": "#000000", "--bg": "#000000", "a b": "#000000", "Bg": "#000000", "-x": "#000000",
  },
});
const want = { "--bg": "#fbfaf7", "--code-bg": "#F2F0EB", "--tk-keyword": "#2b2a27" };
const colours = Object.fromEntries(Object.entries(set).filter(([k]) => k in want || !/^--(scale|tracking|leading|para|measure|header)$/.test(k)));
const ok = JSON.stringify(colours) === JSON.stringify(want) && attrs["data-mono"] === true;
midamStyle({ colors: "nope" });
const ok2 = attrs["data-mono"] === false;
console.log(ok && ok2 ? "theme colours: only valid tokens with #rrggbb values are set" : "FAILED " + JSON.stringify(colours));
process.exit(ok && ok2 ? 0 : 1);
