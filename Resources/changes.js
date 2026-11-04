// What changed since the version last read (V3): the blocks of the two sources (markBlocks in
// markdown.js, loaded before this) aligned by their text with whitespace collapsed. Pure, no DOM:
// runs in the page, in node (tools/changes-test.js) and in JavaScriptCore (ChangeCount.swift), so
// the sidebar's count for an unopened document is the page's.

// The blocks of `src` as [{kind, raw, start, end}], numbered as midamParse's data-blk. Block
// lexing only: inline content is not needed to tell blocks apart.
function midamBlocks(src) {
  const fm = begin(src);
  markBlocks(new marked.Lexer(gfm.defaults).blockTokens((fm ? fm.rest : src).replace(/\r\n|\r/g, "\n")));
  return blocks;
}

// {ops, places, count}: ops in the new document's order, each {op: "same" | "changed" | "added" |
// "removed", old?: i, new?: j} (block indexes); a removed op sits where its block was and carries
// {firstWords, lines, raw} for the collapsed line. A place is a run of adjacent ops other than
// "same" (as op indexes); count is the number of places.
function midamDiff(oldSrc, newSrc) {
  const a = midamBlocks(oldSrc), b = midamBlocks(newSrc);
  const ids = new Map(), id = k => ids.get(k) ?? (ids.set(k, ids.size), ids.size - 1);
  const key = blk => id(blk.kind + " " + blk.raw.replace(/\s+/g, " ").trim());
  const x = a.map(key), y = b.map(key), pairs = [], ops = [];
  align(x, y, 0, x.length, 0, y.length, pairs);
  let i = 0, j = 0;
  for (const [pi, pj] of [...pairs, [a.length, b.length]]) {
    unmatched(a, b, i, pi, j, pj, ops);
    if (pi < a.length) ops.push({ op: "same", old: pi, new: pj });
    i = pi + 1;
    j = pj + 1;
  }
  const places = [];
  let run = null;
  ops.forEach((o, k) => {
    if (o.op === "same") run = null;
    else {
      if (!run) places.push(run = []);
      run.push(k);
    }
  });
  return { ops, places, count: places.length };
}

// Gaps up to this many old × new blocks are aligned exactly (LCS table). Larger ones, as when
// every block of a long document moved, are first cut at the blocks found exactly once on each
// side (patience diff), so a 5,000-line document stays within a few milliseconds.
const LCS_CELLS = 250000;

// Appends the matched [old, new] index pairs of x[a0..a1) and y[b0..b1), in order, to `out`.
function align(x, y, a0, a1, b0, b1, out) {
  while (a0 < a1 && b0 < b1 && x[a0] === y[b0]) out.push([a0++, b0++]);
  let tail = 0;
  while (a0 < a1 && b0 < b1 && x[a1 - 1] === y[b1 - 1]) a1--, b1--, tail++;
  if (a0 < a1 && b0 < b1) {
    if ((a1 - a0) * (b1 - b0) <= LCS_CELLS) lcs(x, y, a0, a1, b0, b1, out);
    else {
      // ponytail: a huge gap with no block unique on both sides (thousands of repeats) stays
      // unmatched, so it shows as changed; Myers' diff would match it if that ever matters.
      let i = a0, j = b0;
      for (const [ai, bj] of anchors(x, y, a0, a1, b0, b1)) {
        align(x, y, i, ai, j, bj, out);
        out.push([ai, bj]);
        i = ai + 1;
        j = bj + 1;
      }
      if (i > a0) align(x, y, i, a1, j, b1, out);
    }
  }
  for (let k = 0; k < tail; k++) out.push([a1 + k, b1 + k]);
}

function lcs(x, y, a0, a1, b0, b1, out) {
  const n = a1 - a0, m = b1 - b0, w = m + 1, L = new Uint32Array((n + 1) * w);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      L[i * w + j] = x[a0 + i] === y[b0 + j] ? L[(i + 1) * w + j + 1] + 1 : Math.max(L[(i + 1) * w + j], L[i * w + j + 1]);
    }
  }
  for (let i = 0, j = 0; i < n && j < m;) {
    if (x[a0 + i] === y[b0 + j]) out.push([a0 + i++, b0 + j++]);
    else if (L[(i + 1) * w + j] >= L[i * w + j + 1]) i++;
    else j++;
  }
}

// The longest in-order run of blocks that occur exactly once in each range, as [old, new] pairs.
function anchors(x, y, a0, a1, b0, b1) {
  const seen = new Map(); // id -> [count in x, index in x, count in y, index in y]
  for (let i = a0; i < a1; i++) {
    const c = seen.get(x[i]);
    if (c) c[0]++;
    else seen.set(x[i], [1, i, 0, 0]);
  }
  for (let j = b0; j < b1; j++) {
    const c = seen.get(y[j]);
    if (c) c[2]++, c[3] = j;
  }
  const once = [...seen.values()].filter(c => c[0] === 1 && c[2] === 1); // in x order
  const tails = [], prev = [];
  once.forEach((c, k) => {
    let lo = 0, hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (once[tails[mid]][3] < c[3]) lo = mid + 1;
      else hi = mid;
    }
    prev[k] = lo ? tails[lo - 1] : -1;
    tails[lo] = k;
  });
  const out = [];
  for (let k = tails.length ? tails[tails.length - 1] : -1; k >= 0; k = prev[k]) out.push([once[k][1], once[k][3]]);
  return out.reverse();
}

// Ops for the unmatched old blocks a[i0..i1) and new blocks b[j0..j1) between two matches. A new
// block pairs with a later unpaired old one of its kind sharing at least half its words
// ("changed"); one block replaced by one of its kind is an edit whatever its words. Removed
// blocks come before the new ones around them.
function unmatched(a, b, i0, i1, j0, j1, ops) {
  const pair = [];
  if (i1 - i0 === 1 && j1 - j0 === 1 && a[i0].kind === b[j0].kind) pair[0] = i0;
  else {
    for (let j = j0, i = i0; j < j1; j++) {
      // ponytail: looks at most 50 blocks ahead, so a huge rewritten gap stays linear
      for (let c = i; c < i1 && c < i + 50; c++) {
        if (a[c].kind === b[j].kind && similar(a[c].raw, b[j].raw)) {
          pair[j - j0] = c;
          i = c + 1;
          break;
        }
      }
    }
  }
  const upTo = []; // per new block: the removed blocks before the next pair's old one go first
  for (let j = j1 - 1, up = i1; j >= j0; j--) upTo[j - j0] = up = pair[j - j0] ?? up;
  let i = i0;
  for (let j = j0; j < j1; j++) {
    const k = pair[j - j0];
    for (; i < upTo[j - j0]; i++) ops.push(removed(a[i], i));
    if (k === undefined) ops.push({ op: "added", new: j });
    else {
      ops.push({ op: "changed", old: k, new: j });
      i = k + 1;
    }
  }
  for (; i < i1; i++) ops.push(removed(a[i], i));
}

// Words, with each Han or kana character a word of its own (those scripts have no spaces).
const WORDS = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]|[\p{L}\p{N}_]+/gu;

function similar(p, q) {
  const x = p.toLowerCase().match(WORDS) || [], y = q.toLowerCase().match(WORDS) || [];
  if (!x.length || !y.length) return x.length === y.length;
  const bag = new Map();
  for (const w of x) bag.set(w, (bag.get(w) || 0) + 1);
  let common = 0;
  for (const w of y) {
    const c = bag.get(w);
    if (c) common++, bag.set(w, c - 1);
  }
  return 2 * common >= (x.length + y.length) / 2;
}

// A removed op: its first words as plain text (Markdown marks and tags dropped, roughly) and its
// line count, for "Deleted: …, N lines".
function removed(blk, i) {
  const words = blk.raw.replace(/<[^>]*>/g, " ").replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/^\[[ xX]\] /, "")
    .replace(/[*`~]+/g, "").split(/\s+/).filter(w => /[\p{L}\p{N}]/u.test(w));
  return { op: "removed", old: i, firstWords: words.slice(0, 8).join(" ") + (words.length > 8 ? "…" : ""),
    lines: newlines(blk.raw.trimEnd()) + 1, raw: blk.raw };
}
