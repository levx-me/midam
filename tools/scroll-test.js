// Checks the Vim page-key distance from render.js: the page below the header less a line, by
// fraction, never under one line. Run: node tools/scroll-test.js
const src = require("fs").readFileSync(require("path").join(__dirname, "../Resources/render.js"), "utf8");
const pageStep = new Function(src.match(/const pageStep = [^\n]+\n/)[0] + "return pageStep;")();
const cases = [[800, 32, 1, 728], [800, 32, 0.5, 364], [800, 50, 1, 710], [100, 32, 0.5, 40], [60, 32, 1, 40], [1201, 32, 0.5, 565]];
let bad = 0;
for (const [h, top, f, want] of cases) { const got = pageStep(h, top, f); if (got !== want) { bad++; console.log("FAIL", { h, top, f, want, got }); } }
console.log(bad ? `FAILED ${bad} of ${cases.length}` : `page step: ${cases.length} checks passed`);
process.exit(bad ? 1 : 0);
