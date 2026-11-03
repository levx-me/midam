// Extracts cssString from render.js and checks hostile font names stay one CSS string token.
const fs = require("fs");
const src = fs.readFileSync(process.argv[2] || require("path").join(__dirname, "../Resources/render.js"), "utf8");
const cssString = new Function(src.match(/function cssString[\s\S]*?\n}\n/)[0] + "return cssString;")();
// CSS Syntax 3 "consume a string token", starting after the opening quote.
function parse(t) {
  if (t[0] !== '"') throw "no open quote";
  let i = 1, out = "";
  for (;;) {
    const c = t[i++];
    if (c === undefined) throw "EOF in string";
    if (c === '"') break;
    if (c === "\n" || c === "\r" || c === "\f") throw "bad-string (newline)";
    if (c === "\\") {
      let h = "";
      while (h.length < 6 && /[0-9a-f]/i.test(t[i])) h += t[i++];
      if (!h) throw "non-hex escape (" + t[i] + ")";
      if (/[ \t\n]/.test(t[i])) i++;
      const cp = parseInt(h, 16);
      out += cp === 0 ? "�" : String.fromCodePoint(cp);
    } else out += c;
  }
  if (i !== t.length) throw "trailing after string: " + t.slice(i);
  return out;
}
const hostile = ['Menlo', 'a"; } body { display:none } x{"', 'a\\', '\\"', 'x\ny', 'x\r\f\t', 'a\0b',
  "'single'", 'url(https://example.com/x)', '"', '', '한글 글꼴', '\\22 ', '*/ html{color:red} /*', 'a\u007f', 'emoji 😀'];
let ok = true;
for (const n of hostile) {
  const e = cssString(n);
  try {
    const back = parse(e);
    const want = n.replace(/\0/g, "�");
    if (back !== want) { ok = false; console.log("MISMATCH", JSON.stringify(n), e, JSON.stringify(back)); }
  } catch (err) { ok = false; console.log("FAIL", JSON.stringify(n), e, err); }
}
console.log(ok ? `all ${hostile.length} hostile names stay one string token and round-trip` : "FAILED");
process.exit(ok ? 0 : 1);
