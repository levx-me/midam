// Runs the real page (template, KaTeX + Midam CSS, the renderer scripts and mermaid) in headless
// WebKit through Playwright, and checks: the two views survive headings and raw HTML named
// "source"/"content"; hostile mermaid stays inert (no script, links, HTML labels, themeCSS, network);
// diagrams use the theme; wide ones never scroll the page sideways.
// Run: NODE_PATH=$(npm root -g) node tools/webkit-test.js   (skips, exit 0, without Playwright)
// The scripts run as page scripts here (CSP bypassed); in the app they run in the "midam" world.
const fs = require("fs"), path = require("path"), R = path.join(__dirname, "../Resources/");
let webkit;
try { ({ webkit } = require("playwright")); } catch { console.log("webkit test: skipped (no playwright module)"); process.exit(0); }
const read = f => fs.readFileSync(R + f, "utf8");

(async () => {
  const browser = await webkit.launch(process.env.PW_WEBKIT ? { executablePath: process.env.PW_WEBKIT } : {}); // PW_WEBKIT: a cached pw_run.sh
  const page = await (await browser.newContext({ bypassCSP: true, viewport: { width: 1000, height: 800 } })).newPage();
  const requests = [];
  page.on("request", r => { if (!r.url().startsWith("data:") && !r.url().startsWith("about:")) requests.push(r.url()); });
  await page.setContent(read("template.html").replace("/*STYLE*/", read("katex.min.css") + "\n" + read("style.css")));
  await page.addScriptTag({ content: ["marked.umd.js", "highlight.min.js", "katex.min.js", "emoji.js", "markdown.js", "render.js"].map(read).join("\n;\n") });
  const midam = JSON.parse(read("themes.json")).light[0];
  await page.evaluate(c => midamStyle({ colors: c.colors, monochrome: c.mono }), midam);
  let bad = 0, n = 0;
  const check = (name, ok, info) => { n++; if (!ok) { bad++; console.log("FAIL", name, info ?? ""); } };

  // 1. App ids: headings and raw HTML named like the views.
  const md = "# Source\n\n# Content\n\n## midam-fn-1\n\n<pre id=source>raw pre</pre>\n\n<div id=content>raw div</div>\n\nText[^1]\n\n[^1]: Note.";
  for (const round of [1, 2]) { // a second render is an auto-reload
    const r = await page.evaluate(async md => {
      await midamRender(md, "", {});
      const c = document.querySelector("body > #content"), s = document.querySelector("body > #source");
      const shown = el => getComputedStyle(el).display !== "none";
      const reading = [shown(c), shown(s), shown(c.querySelector("pre#source"))];
      midamSetView(true);
      const source = [shown(c), shown(s)];
      midamSetView(false);
      return { tag: c?.tagName, ids: [...c.querySelectorAll("h1,h2")].map(h => h.id), src: s?.tagName + ":" + s?.textContent.slice(0, 8),
        reading, source, views: document.querySelectorAll("body > #content, body > #source").length,
        fn: c.querySelector("sup a")?.getAttribute("href"), fnTarget: !!c.querySelector('li[id="midam-fn-1"]') };
    }, md);
    check(`round ${round}: views are the app's`, r.tag === "ARTICLE" && r.src === "PRE:# Source" && r.views === 2, r);
    check(`round ${round}: heading ids avoid app ids`, JSON.stringify(r.ids.slice(0, 3)) === '["source-1","content-1","midam-fn-1-1"]', r.ids);
    check(`round ${round}: reading view`, JSON.stringify(r.reading) === "[true,false,true]", r.reading);
    check(`round ${round}: source view`, JSON.stringify(r.source) === "[false,true]", r.source);
    check(`round ${round}: footnote ids prefixed`, r.fn === "#midam-fn-1" && r.fnTarget, r);
  }

  // 2. Mermaid: hostile input inert, theme colours, natural size, no sideways page scroll.
  await page.addScriptTag({ content: read("mermaid.min.js") });
  const hostile = '%%{init: {"securityLevel": "loose", "htmlLabels": true, "flowchart": {"htmlLabels": true}, ' +
    '"themeCSS": "svg { background: url(https://example.com/t.png) }", "fontFamily": "url(https://example.com/f)", ' +
    '"themeVariables": {"primaryColor": "#ff0000", "fontFamily": "Evil"}}}%%\n' +
    'flowchart LR\n  A["<img src=x onerror=alert(1)><b>bold</b>"] --> B["<a href=\'javascript:alert(1)\'>link</a>"]\n' +
    '  click A "javascript:alert(1)" "tip"\n  click B call alert(1)\n  C["<script>alert(1)</script>"]\n  style C fill:#00ff00';
  const wide = "flowchart LR\n" + Array.from({ length: 24 }, (_, i) => `  N${i}[긴 이름의 단계 ${i}] --> N${i + 1}`).join("\n");
  const out = await page.evaluate(async ([hostile, wide]) => {
    // Anything mermaid adds to <body> while it draws (its scratch nodes) must never be visible.
    const shownScratch = [];
    const watch = new MutationObserver(ms => { for (const m of ms) for (const n of m.addedNodes) {
      if (n.nodeType === 1 && n.parentElement === document.body && n.checkVisibility({ visibilityProperty: true })) shownScratch.push(n.tagName + "#" + n.id);
    } });
    watch.observe(document.body, { childList: true });
    await midamRender("Narrow:\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\n```mermaid\n" + hostile + "\n```\n\n```mermaid\n" + wide + "\n```\n\n```mermaid\nflowchart LR\n  A -->\n```", "", { diagram: "X" });
    const figs = [...document.querySelectorAll("body > #content figure.diagram")];
    const col = document.querySelector("body > #content").getBoundingClientRect();
    return {
      count: figs.length, svgs: figs.map(f => !!f.querySelector("svg")), hostile: figs[1]?.innerHTML || "",
      narrow: (() => { const b = figs[0].querySelector("svg").getBoundingClientRect(); return b.left >= col.left - 1 && b.right <= col.right + 1 && Math.abs((b.left + b.right) / 2 - (col.left + col.right) / 2) < 2; })(),
      wide: { fig: figs[2].clientWidth, scroll: figs[2].scrollWidth, svgW: figs[2].querySelector("svg").getAttribute("width"), body: document.body.clientWidth - 80 },
      page: [document.documentElement.scrollWidth, innerWidth],
      error: figs[3]?.querySelector(".diagram-error")?.textContent || "", errorPre: !!figs[3]?.querySelector("pre"),
      fill: figs[0].innerHTML.includes("#f2f0eb"),
      shownScratch: (watch.disconnect(), shownScratch.filter(t => t !== "ARTICLE#content" && t !== "PRE#source")),
    };
  }, [hostile, wide]);
  check("four figures, three drawn", out.count === 4 && JSON.stringify(out.svgs) === "[true,true,true,false]", out.svgs);
  const h = out.hostile.toLowerCase();
  for (const bit of ["javascript:", "onerror", "<script", "<img", "<b>", "foreignobject", "example.com", "evil", "#ff0000"]) check("hostile diagram has no " + bit, !h.includes(bit), h.slice(Math.max(0, h.indexOf(bit) - 200), h.indexOf(bit) + 300));
  check("hostile click leaves only an anchor without a link", !/<a\b[^>]*href/.test(h), h.match(/<a\b[^>]*>/g));
  check("hostile style statement still applies (it is plain CSS colour)", h.includes("#00ff00"));
  check("no network", requests.length === 0, requests);
  check("narrow diagram centred in the column", out.narrow);
  check("wide diagram: natural size, figure is the window less padding, scrolls inside", out.wide.svgW !== "100%" && out.wide.fig === out.wide.body && out.wide.scroll > out.wide.fig, out.wide);
  check("page never scrolls sideways", out.page[0] <= out.page[1], out.page);
  check("failed diagram: code and one line", out.errorPre && out.error.startsWith("X: "), out.error);
  check("diagram wears the theme (code-bg fill)", out.fill);
  check("mermaid's scratch nodes never show while it draws", out.shownScratch.length === 0, out.shownScratch);

  // 3. Wide diagrams nested in lists (1-3 levels), a quote and an alert stay in their box, and no
  // window width scrolls the page sideways. Rendered once, then resized: the layout is CSS only.
  const fence = (pad, q = "") => ["```mermaid", ...wide.split("\n"), "```"].map(l => q + pad + l).join("\n");
  const nested = ["Top:", "", fence(""), "", "- one", "", fence("  "), "", "- a", "  - two", "", fence("    "), "",
    "- a", "  - b", "    - three", "", fence("      "), "", "> quote", ">", fence("", "> "), "", "> [!NOTE]", ">", fence("", "> "), "",
    "```mermaid\nflowchart LR\n  A --> B\n```"].join("\n");
  await page.evaluate(md => midamRender(md, "", {}), nested);
  for (const width of [420, 500, 800, 1000]) {
    await page.setViewportSize({ width, height: 800 });
    const r = await page.evaluate(() => {
      const figs = [...document.querySelectorAll("body > #content figure.diagram")];
      const pad = parseFloat(getComputedStyle(document.body).paddingLeft);
      return {
        page: [document.documentElement.scrollWidth, document.documentElement.clientWidth],
        count: figs.length, drawn: figs.every(f => f.querySelector("svg")),
        top: Math.round(figs[0].getBoundingClientRect().width) === document.body.clientWidth - 2 * pad,
        inside: figs.slice(1, 6).map(f => { const a = f.getBoundingClientRect(), b = f.parentElement.getBoundingClientRect(); return a.left >= b.left - 0.5 && a.right <= b.right + 0.5; }),
        scrolls: figs.slice(0, 6).every(f => f.scrollWidth > f.clientWidth),
      };
    });
    check(`${width}px: no page-level sideways scroll`, r.page[0] <= r.page[1], r.page);
    check(`${width}px: seven diagrams drawn`, r.count === 7 && r.drawn, r);
    check(`${width}px: top-level figure spans the window less padding`, r.top, r);
    check(`${width}px: nested figures stay in their box`, r.inside.every(Boolean), r.inside);
    check(`${width}px: wide figures scroll inside themselves`, r.scrolls, r);
  }

  // 3a. Tables: wide ones (Korean, English) keep readable cells and scroll in their own box, a
  // nested one stays in its list item, a small one sits in the column as before, all at four widths.
  const row = cells => "| " + cells.join(" | ") + " |";
  const table = (head, body) => [row(head), row(head.map(() => "---")), ...body.map(row)].join("\n");
  const ko = table(["항목", "설명", "비고", "상태", "담당", "기한"], [1, 2, 3].map(i =>
    ["읽기 " + i, "한글은 어절 단위로 줄을 바꾸고 아주 긴 설명도 읽기 좋은 문단이 되도록 칸의 최대 너비 안에서 감싸집니다", "글꼴과 크기", "진행 중", "김하늘", "2026년 11월 3일"]));
  const en = table(["Name", "Description", "Notes", "Status", "Link", "Code"], [1, 2, 3].map(i =>
    ["Row " + i, "A long description that should wrap into a readable paragraph at word boundaries instead of one word per line", "fine", "done",
      "https://example.com/a/very/long/path/that/keeps/going/and/going/without/any/spaces/at/all/" + "x".repeat(60), "`" + "y".repeat(90) + "`"]));
  const tmd = ["Korean:", "", ko, "", "English:", "", en, "", "- in a list", "", ...en.split("\n").map(l => "  " + l), "", "Small:", "", "| a | b |\n|:-:|--:|\n| 1 | 2 |"].join("\n");
  await page.evaluate(md => midamRender(md, "", {}), tmd);
  for (const width of [420, 500, 800, 1000]) {
    await page.setViewportSize({ width, height: 800 });
    const r = await page.evaluate(() => {
      const content = document.querySelector("body > #content"), col = content.getBoundingClientRect();
      const wraps = [...content.querySelectorAll(".table-wrap")], em = parseFloat(getComputedStyle(content).fontSize);
      const pad = parseFloat(getComputedStyle(document.body).paddingLeft);
      const cells = wraps.slice(0, 3).flatMap(w => [...w.querySelectorAll("th, td")]);
      const narrow = cells.filter(c => c.textContent.trim().length >= 6 && c.getBoundingClientRect().width < 4 * em).map(c => c.textContent.slice(0, 12));
      const small = wraps[3].querySelector("table"), cellsSmall = [...small.querySelectorAll("td, th")];
      const line = parseFloat(getComputedStyle(cellsSmall[0]).lineHeight);
      return {
        page: [document.documentElement.scrollWidth, document.documentElement.clientWidth], count: wraps.length, narrow,
        top: wraps.slice(0, 2).every(w => Math.round(w.getBoundingClientRect().width) === document.body.clientWidth - 2 * pad),
        scrolls: wraps.slice(0, 2).every(w => w.scrollWidth > w.clientWidth),
        nested: (() => { const a = wraps[2].getBoundingClientRect(), b = wraps[2].parentElement.getBoundingClientRect(); return a.left >= b.left - 0.5 && a.right <= b.right + 0.5 && wraps[2].scrollWidth > wraps[2].clientWidth; })(),
        maxCell: Math.max(...cells.map(c => c.getBoundingClientRect().width)) <= 33.5 * em, // 32em plus padding
        small: Math.abs(small.querySelector("tr").getBoundingClientRect().left - col.left) < 1 && cellsSmall.every(c => c.getBoundingClientRect().height < 2 * line + 16),
        align: [...small.querySelectorAll("th")].map(th => getComputedStyle(th).textAlign).join(","),
      };
    });
    check(`${width}px tables: no page-level sideways scroll`, r.page[0] <= r.page[1], r.page);
    check(`${width}px tables: four wrapped tables`, r.count === 4, r.count);
    check(`${width}px tables: no cell squeezed below 4em`, r.narrow.length === 0, r.narrow);
    check(`${width}px tables: cells at most 32em`, r.maxCell, r);
    check(`${width}px tables: wide top-level ones span the window less padding and scroll inside`, r.top && r.scrolls, r);
    check(`${width}px tables: a nested one stays in its box and scrolls`, r.nested, r);
    check(`${width}px tables: a small one starts at the column, one line per cell, aligned`, r.small && /^(-webkit-)?center,(-webkit-)?right$/.test(r.align), r);
  }

  // 3. Render cache: a cached page shown first, then the same fresh render, keeps its nodes (no
  // repaint); a changed document replaces them; adopted diagrams still redraw for a new theme.
  const fresh = async () => {
    const p = await (await browser.newContext({ bypassCSP: true, viewport: { width: 1000, height: 800 } })).newPage();
    await p.setContent(read("template.html").replace("/*STYLE*/", read("katex.min.css") + "\n" + read("style.css")));
    await p.addScriptTag({ content: ["marked.umd.js", "highlight.min.js", "katex.min.js", "emoji.js", "markdown.js", "render.js", "mermaid.min.js"].map(read).join("\n;\n") });
    await p.evaluate(c => midamStyle({ colors: c.colors, monochrome: c.mono }), midam);
    return p;
  };
  const cmd = "# Cached\n\n## Part\n\nText $x^2$\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\n```js\nlet a = 1\n```";
  const first = await fresh();
  const cached = (await first.evaluate(async md => midamRender(md, "", {}), cmd)).html;
  const relaunch = await fresh();
  const c = await relaunch.evaluate(async ([md, html]) => {
    const shown = midamShowCached(html, "");
    const before = document.querySelector("body > #content");
    const visible = getComputedStyle(before).visibility === "visible" && !!before.querySelector("figure.diagram svg");
    const r = await midamRender(md, "", {});
    const kept = document.querySelector("body > #content") === before;
    const fill = before.querySelector("figure.diagram svg").innerHTML;
    midamStyle({ colors: { "code-bg": "#123456" } }); // a theme change redraws the kept diagram
    await new Promise(r => setTimeout(r, 300));
    const redrawn = before.querySelector("figure.diagram svg").innerHTML !== fill && before.querySelector("figure.diagram svg").innerHTML.includes("#123456");
    await midamRender(md + "\n\nMore.", "", {});
    const replaced = document.querySelector("body > #content") !== before;
    return { shown: shown.outline.map(h => h.id), visible, kept, outline: r.outline.map(h => h.id), html: typeof r.html, redrawn, replaced,
      ids: [...document.querySelectorAll("svg[id^=midam-diagram]")].map(e => e.id) };
  }, [cmd, cached]);
  check("cache: cached page shows at once with its diagram and outline", c.visible && JSON.stringify(c.shown) === '["cached","part"]', c);
  check("cache: the same fresh render keeps the cached nodes", c.kept, c);
  check("cache: the render returns its outline and HTML", JSON.stringify(c.outline) === '["cached","part"]' && c.html === "string", c);
  check("cache: kept diagrams redraw for a new theme", c.redrawn, c);
  check("cache: a changed document replaces the cached page", c.replaced, c);
  check("cache: diagram ids stay unique", new Set(c.ids).size === c.ids.length && c.ids.length === 1, c.ids);

  // 5. A diagonal wheel over a block that scrolls sideways moves both: the block sideways, the page down.
  await page.evaluate(async () => {
    const wide = "x".repeat(600);
    await midamRender("```\n" + (wide + "\n").repeat(40) + "```\n\n" + "Text.\n\n".repeat(200), "", {});
    scrollTo(0, 0);
  });
  const box = await page.evaluate(() => { const b = document.querySelector("#content pre").getBoundingClientRect(); return { x: b.x + 40, y: b.y + b.height / 2 }; });
  await page.mouse.move(box.x, box.y);
  for (let i = 0; i < 5; i++) await page.mouse.wheel(20, 30);
  await page.waitForTimeout(300);
  const d = await page.evaluate(() => ({ y: scrollY, x: document.querySelector("#content pre").scrollLeft }));
  check("diagonal wheel over a code block scrolls the page down", d.y >= 100, d);
  check("diagonal wheel over a code block scrolls it sideways", d.x >= 60, d);

  await browser.close();
  console.log(bad ? `FAILED ${bad} of ${n}` : `webkit: ${n} checks passed (views, app ids, hostile mermaid inert, theme, wide layout, diagonal wheel)`);
  process.exit(bad ? 1 : 0);
})().catch(e => { console.log("FAILED", e); process.exit(1); });
