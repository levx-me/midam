// Runs Resources/markdown.js with the bundled KaTeX and checks GitHub's $ rules and that hostile
// TeX (\href, \url, \html*, \includegraphics) stays inert under trust: false. Run: node tools/math-test.js
const fs = require("fs"), path = require("path"), R = path.join(__dirname, "../Resources/");
const parse = new Function("marked", "katex", fs.readFileSync(R + "emoji.js", "utf8") + fs.readFileSync(R + "markdown.js", "utf8") +
  "\nreturn midamParse;")(require(R + "marked.umd.js"), require(R + "katex.min.js"));
let bad = 0, n = 0;
const math = h => (h.match(/class="katex"/g) || []).length;
const count = (md, want) => { n++; const h = parse(md, {}); if (math(h) !== want) { bad++; console.log("FAIL", JSON.stringify(md), "math:", math(h), "want", want, "\n" + h); } return h; };

// Inline $…$: open not followed by space, close not after a space nor before a digit, not digits only.
count("$x^2$", 1);
count("a $x$ b $y$ c", 2);
count("It costs $5 and $10.", 0);
count("$20,000 and $30,000", 0);
count("$5$", 0);
count("$ x$", 0);
count("$x $", 0);
count("$x$1", 0);
count("\\$x$", 0);
count("`$x$`", 0);
count("```\n$x$\n```", 0);
count("$\\$5$", 1);
count("한글 $\\text{넓이} = \\pi r^2$ 수식", 1);
count("$$", 0);
// Display: $$ on its own lines, $$…$$ in a paragraph, and ```math fences.
count("$$\n\\int_0^1 x\\,dx\n$$", 1);
count("$$ a = b $$", 1);
count("Inline $$a+b$$ display", 1);
count("```math\na = b\n```", 1);
count("$$\nnot closed\n\nnew paragraph $$", 0);
count("Para\n$$\nx\n$$\nafter", 1); // $$ interrupts a paragraph
count("Para\n$$ not closed\nmore", 0);
// Linear in the document: 50 KB of $$ lines with no blank line (each a false block start).
for (const md of ["$$ x\n".repeat(10000), "$$ x\n[^a] y\n".repeat(5000), "$".repeat(50000)]) {
  const t = Date.now(); parse(md, {}); const ms = Date.now() - t;
  n++; if (ms > 800) { bad++; console.log("FAIL slow:", JSON.stringify(md.slice(0, 12)), ms + " ms"); }
}
let h = parse("$$\nx\n$$", {});
n++; if (!h.includes('class="math-display"') || !h.includes("katex-display")) { bad++; console.log("FAIL display wrapper", h); }
h = parse("```mathx\nx\n```", {});
n++; if (math(h) || !h.includes("language-mathx")) { bad++; console.log("FAIL other fence", h); }
// Errors render quietly as source, never throw.
h = parse("$\\frac{1}{$", {});
n++; if (!h.includes("katex-error")) { bad++; console.log("FAIL error", h); }

// Hostile TeX: no link, no class/id/style/data from the document, no image.
const hostile = ["\\href{javascript:alert(1)}{x}", "\\url{javascript:alert(1)}", "\\htmlClass{evil}{x}", "\\htmlId{content}{x}",
  "\\htmlStyle{color:red;background:url(https://example.com/t)}{x}", "\\htmlData{foo=bar}{x}", "\\includegraphics{https://example.com/x.png}",
  "\\href{https://example.com}{x}", "\\textcolor{red\" onmouseover=\"alert(1)}{x}", "\\def\\a{\\a}\\a", "\\char\"3C\\char\"62"];
for (const t of hostile) for (const md of ["$" + t + "$", "$$\n" + t + "\n$$", "```math\n" + t + "\n```"]) {
  n++;
  const out = parse(md, {});
  const leaked = /<a\b|href=|<img|evil|id="content"|data-foo|onmouseover="|url\(https|<b>/i.test(out.replace(/<annotation[^>]*>[^]*?<\/annotation>/g, "").replace(/title="[^"]*"/g, ""));
  if (leaked) { bad++; console.log("FAIL hostile", JSON.stringify(md), "\n" + out); }
}

console.log(bad ? `FAILED ${bad} of ${n}` : `math: ${n} checks passed ($ rules, display, fences, ${hostile.length} hostile commands inert)`);
process.exit(bad ? 1 : 0);
