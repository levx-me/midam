#!/usr/bin/env python3
"""Checks Resources/themes.json: every variant has the same tokens as Midam, all #rrggbb, Midam
first in both lists, unique ids, and every text token at least 4.5:1 (WCAG AA) on the variant's
background and on its code background. Run: python3 tools/theme-contrast.py   (exit 1 on any fail)"""
import json, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
data = json.loads((root / "Resources/themes.json").read_text())
GROUNDS = ["bg", "code-bg"]
NON_TEXT = {"bg", "code-bg", "hairline", "find"}

def lum(h):
    f = lambda v: v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (f(int(h[i:i + 2], 16) / 255) for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def ratio(a, b):
    x, y = sorted([lum(a), lum(b)], reverse=True)
    return (x + 0.05) / (y + 0.05)

problems, pairs, worst = [], 0, (99, "")
keys = set(data["light"][0]["colors"])
for mode in ("light", "dark"):
    themes = data[mode]
    if themes[0]["id"] != "midam": problems.append(f"{mode}: Midam must come first (the fallback)")
    ids = [t["id"] for t in themes]
    if len(ids) != len(set(ids)): problems.append(f"{mode}: duplicate ids")
    for t in themes:
        c = t["colors"]
        if set(c) != keys: problems.append(f"{mode} {t['id']}: tokens differ from Midam: {sorted(set(c) ^ keys)}")
        bad = [k for k, v in c.items() if not re.fullmatch(r"#[0-9a-f]{6}", v)]
        if bad: problems.append(f"{mode} {t['id']}: not #rrggbb: {bad}"); continue
        dark = lum(c["bg"]) < 0.18
        if dark != (mode == "dark"): problems.append(f"{mode} {t['id']}: background is not a {mode} one")
        for k in sorted(set(c) - NON_TEXT):
            for g in GROUNDS:
                r = ratio(c[k], c[g]); pairs += 1
                worst = min(worst, (r, f"{mode} {t['id']} {k} on {g}"))
                if r < 4.5: problems.append(f"{mode} {t['id']}: {k} {c[k]} on {g} {c[g]} is {r:.2f}:1")

n = len(data["light"]) + len(data["dark"])
print(f"{n} variants, {pairs} text/ground pairs; lowest {worst[0]:.2f}:1 ({worst[1]})")
print("\n".join(problems) or "all pairs reach WCAG AA 4.5:1")
sys.exit(1 if problems else 0)
