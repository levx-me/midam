<p align="center"><img src="docs/icon.png" width="128" alt="Midam"></p>
<h1 align="center">Midam</h1>

<p align="center">A calm, minimalist Markdown viewer for macOS.</p>

<p align="center">
  <img src="docs/screenshots/light.png" width="49%" alt="Midam in the light Midam theme, with the table of contents open">
  <img src="docs/screenshots/dark.png" width="49%" alt="Midam in the dark Catppuccin Mocha theme, showing a Mermaid diagram and KaTeX math">
</p>

## Features

- Live reload when the file changes on disk
- GitHub Flavored Markdown, syntax highlighting, Mermaid diagrams, math (KaTeX), alerts, footnotes, emoji, front-matter table
- Two views: Reading (rendered) and Source (raw Markdown)
- Single window with tabs
- Liquid Glass header
- Colour themes from 10 families (Catppuccin, Gruvbox, Nord, Tokyo Night, Rosé Pine, Everforest, Kanagawa, One, Solarized, GitHub; Nord is dark-only) plus the monochrome Midam theme, chosen separately for light and dark
- Back / forward through links, anchors and tab switches
- Reading settings and bundled fonts
- English and Korean

<p align="center"><img src="docs/screenshots/live-reload.gif" width="720" alt="A plan.md file growing section by section while Midam redraws each change"></p>
<p align="center"><sub>Live reload: the page follows the file as it changes.</sub></p>

## Install

Download the zip for your Mac from Releases: `Midam-<version>-apple-silicon.zip` (M-series) or `Midam-<version>-intel.zip`. Unzip it in Finder (double-click) or with `ditto -x -k <zip> .`, then move `Midam.app` to `/Applications`. Plain `unzip` drops parts of the app's signature.

The app is ad-hoc signed, not notarized, so macOS blocks the first open. Open it once and click Done, then go to System Settings → Privacy & Security, click Open Anyway next to the Midam message and confirm with your password. You only do this once. On macOS 14, Control-click the app → Open also works. Or clear the quarantine flag in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Midam.app
```

Requires macOS 14 or later.

## Build from source

```sh
./build.sh              # release build, installs to /Applications
./build.sh --no-install # build/Midam.app only
./release.sh            # dist/Midam-<version>-{apple-silicon,intel}.zip, one single-arch app each
```

`release.sh` reads the version from `Info.plist`, verifies each binary's architecture and signature, and prints the zips' SHA-256.

### Tests

```sh
for t in tools/*-test.js; do node "$t"; done   # rendering, math, diagrams, fonts, themes
python3 tools/theme-contrast.py                 # WCAG AA for every theme
python3 tools/strings-audit.py                  # en/ko strings complete
swiftc Sources/Midam/TabOrder.swift tools/TabOrderTest/main.swift -o /tmp/taborder && /tmp/taborder
```

The Swift checks in `tools/FontSchemeTest`, `tools/NavHistoryTest`, `tools/TocTest`, `tools/RenderCacheTest` and `tools/TipTest` build the same way; each file's header has the exact command. `tools/webkit-test.js` renders pages in headless WebKit through Playwright and is skipped when Playwright is not installed.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘O | Open file |
| ⌘W or x | Close tab |
| ⌘1–9 | Go to tab (⌘9: last tab) |
| ⌘[ / ⌘], two-finger swipe | Back / forward |
| ⌃Tab / ⌃⇧Tab, ⇧⌘[ / ⇧⌘] | Next / previous tab; ⇧⌘[ previous, ⇧⌘] next |
| ⌘F or / , ⌘G / ⇧⌘G | Find (the 🔍 button in the header) / next / previous (Esc closes) |
| ⌘+ / ⌘− / ⌘0 | Text size larger / smaller / default |
| ⌘/ | Toggle Reading / Source |
| ⌘T | Toggle the table of contents (also the ☰ button in the header) |
| ⇧⌘F | Immersive mode: hide the header |
| ⌘R | Reload |
| ⌥⌘R | Show in Finder |
| ⌃⌘F | Full screen |
| Space / ⇧Space, ⌘↓ / ⌘↑ | Page down / up, bottom / top |
| j / k, G / g | Line down / up, bottom / top (Vim style; off while typing in Find) |
| d / u (or e), f / b | Half page down / up, full page down / up (Vimium style) |
| ⌘, | Settings |

Press ⌘' (or the ⌘ button in the header, or Help › Keyboard Shortcuts) to see this list in the app.

## Third-party credits

Fonts and their licences: `Resources/Fonts/LICENSES/`. Themes: `Resources/THEMES.md`. Libraries: [marked](Resources/marked.LICENSE.txt), [highlight.js](Resources/highlight.LICENSE.txt), [Mermaid](Resources/mermaid.LICENSE.txt), [KaTeX](Resources/katex.LICENSE.txt), plus emoji and Octicons licences in `Resources/`.

## License

[MIT](LICENSE)
