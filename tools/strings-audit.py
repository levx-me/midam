#!/usr/bin/env python3
"""Lists every UI string key in the Swift sources and checks it has an entry in both
en.lproj and ko.lproj, and that the two .strings files hold the same keys.
Run: python3 tools/strings-audit.py   (exit 1 on any gap)"""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
src = "\n".join(p.read_text() for p in sorted((root / "Sources/Midam").glob("*.swift")))
src = re.sub(r"//[^\n]*", "", src)  # comments
lit = r'"((?:[^"\\]|\\.)*)"'
calls = r'(?<!\w)(?:Text|Button|Toggle|ShortcutGroup|Shortcut|Picker|Label|LabeledContent|Menu|CommandMenu|TextField|Section|LocalizedStringKey|help|accessibilityLabel|go)\(\s*'
keys = set(re.findall(calls + lit, src))
keys |= set(re.findall(r'(?:label|prompt|hint|gesture): (?:Text\()?' + lit, src))
keys |= set(re.findall(r'named: Text\(' + lit, src))
keys |= set(re.findall(r'String\(localized: ' + lit, src))
keys |= set(re.findall(r'case \.\w+: ' + lit, src))
for group in re.findall(r'names: \[([^\]]*)\]', src):
    keys |= set(re.findall(lit, group))
for a, b in re.findall(r'label: [\w.]+ \? ' + lit + r' : ' + lit, src):
    keys |= {a, b}
# Interpolated keys become format keys.
fmt = {r"Tab \(n)": "Tab %lld", r"\(page.index) of \(page.count) matches": "%lld of %lld matches",
       r"\(r.index) of \(r.count)": "%lld of %lld", r"\(page.index) of \(page.count)": "%lld of %lld",
       r"First \(page.matches.count) listed": "First %lld listed",
       r"\(other) in All Fonts": "%lld in All Fonts", r"\(other) in Recommended": "%lld in Recommended"}
keys = {fmt.get(k, k) for k in keys if k}
def strings(lang):
    t = (root / f"Resources/{lang}.lproj/Localizable.strings").read_text()
    return set(re.findall(r'^' + lit + r' = ', t, re.M))
en, ko = strings("en"), strings("ko")
code_only = set()
problems = [f"missing in en: {k}" for k in sorted(keys - en)] + [f"missing in ko: {k}" for k in sorted(keys - ko)]
problems += [f"only in en: {k}" for k in sorted(en - ko)] + [f"only in ko: {k}" for k in sorted(ko - en)]
unused = sorted(en - keys - code_only)
print(f"{len(keys)} keys in code, {len(en)} in en, {len(ko)} in ko")
if unused: print("in .strings but not found in code (check):", unused)
print("\n".join(problems) or "no gaps: every key has English and Korean")
sys.exit(1 if problems else 0)
