# Colour themes

The page colour themes in `themes.json`: the light list and the dark list, each with Midam
first (the default, and the fallback for an unknown stored id). A theme colours the document
only (both 읽기 and 원문); the window chrome, the glass capsules, the controls and the accent stay
Midam's. Swift (`ColorTheme` in `Settings.swift`) reads the file and passes the chosen theme's
colours to `render.js` `midamStyle()` as arguments; both sides accept only token names with
`#rrggbb` values. `python3 tools/theme-contrast.py` checks every text token reaches WCAG AA
(4.5:1) on the theme's background and on its code background.

## Tokens

| Token | Use |
|---|---|
| `bg`, `code-bg` | page and code background (`code-bg` also tints inline code) |
| `hairline` | rules, table lines, `kbd` edges |
| `find` | base of the find, selection and `<mark>` highlights (mixed at 18-34% over the page) |
| `text`, `muted`, `faint` | body text; secondary (table header rule); faintest (a link's URL in 원문) |
| `heading`, `marker`, `link`, `code`, `quote` | the Markdown elements, the same token in 읽기 and 원문 (`.hljs-section`, `.hljs-bullet`, link text, `.hljs-code`, `.hljs-quote`) |
| `tk-keyword` … `tk-meta` | highlight.js tokens in fenced code |

`mono: true` (Midam only) sets keywords in semibold, since its keywords share the ink of the text.

## Midam (our own)

Monochrome ink on paper (`#fbfaf7`, charcoal `#1d1c1a` in dark). Headings, links, inline code
and keywords are ink; they are told apart by weight and size, the link's thin underline, the
code background tint and keyword weight. List markers and comments use the faint grey,
quotes and strings the muted grey, comments are italic.

## Sources and licences

The palettes are taken from each project's own upstream palette files, not from derived
collections. Colours not defined upstream (a code background or hairline for a theme that has
none) are noted.

| Theme | Source | Licence |
|---|---|---|
| Catppuccin Latte / Mocha | https://github.com/catppuccin/palette (`palette.json`) | MIT, © 2021 Catppuccin |
| Gruvbox Light / Dark | https://github.com/morhetz/gruvbox (`colors/gruvbox.vim`; light uses the faded accents, dark the bright ones) | MIT/X11, © 2012 Pavel Pertsev (morhetz) |
| Nord (dark only; Nord has no official light theme) | https://github.com/nordtheme/nord (`src/nord.css`) | MIT, © 2016-present Sven Greb |
| Tokyo Night Day / Night | https://github.com/folke/tokyonight.nvim (`lua/tokyonight/colors/`, Day as generated in `extras/lua/tokyonight_day.lua`) | Apache-2.0, © Folke Lemaitre |
| Rosé Pine Dawn / Rosé Pine | https://github.com/rose-pine/palette (`palette.json`) | MIT, © mvllow |
| Everforest Light / Dark (medium) | https://github.com/sainnhe/everforest (`autoload/everforest.vim`) | MIT, © 2019 sainnhe |
| Kanagawa Lotus / Wave | https://github.com/rebelot/kanagawa.nvim (`lua/kanagawa/colors.lua`, `themes.lua`) | MIT, © 2021 Tommaso Laurenzi |
| One Light / One Dark | https://github.com/atom/atom (`packages/one-light-syntax`, `packages/one-dark-syntax`, `styles/colors.less`) | MIT, © 2011-2022 GitHub Inc. |
| Solarized Light / Dark | https://github.com/altercation/solarized (`README.md` palette) | MIT, © 2011 Ethan Schoonover |
| GitHub Light / Dark | https://github.com/primer/github-vscode-theme with `@primer/primitives` 7.10.0 | MIT, © 2020 Primer (GitHub Inc.) |

Each licence asks that its copyright notice and permission notice travel with copies of the
work. Only colour values are used here, no code or files; the notices above record the origin.
The Apache-2.0 licence of Tokyo Night also asks that modifications be stated: the values here
are the palette's hex colours, some adjusted in lightness as listed below.

### Mapping notes

- Headings, links, code and quotes come from each palette's accent hues, following the theme's
  own Markdown highlighting where it has one (One: red headings and markers, green code, mono-3
  quotes; GitHub: `markupHeading`, `markupList`, `markup.quote`, `markup.inline.raw`; Kanagawa:
  function blue headings, `special1` links, string green code). Body text is the palette's
  foreground.
- Values not in the upstream palette: One Light `code-bg` `#f0f0f1` and `hairline` `#e5e5e6`;
  One Dark `code-bg` `#21252b` (One Dark UI's panel tone) and `hairline` `#3b4048`; Rosé Pine
  Dawn `hairline` `#dfdad9` (its "highlight med").
- `find` is a chosen accent per theme (usually the yellow or the primary blue), since it is
  mixed at low opacity over the page.

## Adjustments for WCAG AA

Where an upstream colour falls under 4.5:1 on the theme's background or code background, its
OKLCH lightness is moved by the smallest step that reaches 4.5:1 (hue and chroma kept). Every
other colour is the upstream value unchanged. Midam's own faint grey is also darkened on the page
(the window chrome keeps `#75726b` / `#888480`).

| Theme | Tokens | Upstream → used | Lowest ratio |
|---|---|---|---|
| Midam (light) | faint, marker, tk-comment | `#75726b` → `#706d66` | 4.21 → 4.53 |
| Catppuccin Latte | muted | `#6c6f85` → `#65687e` | 4.06 → 4.50 |
| Catppuccin Latte | faint | `#8c8fa1` → `#656879` | 2.63 → 4.53 |
| Catppuccin Latte | heading, tk-keyword | `#8839ef` → `#8738ee` | 4.45 → 4.51 |
| Catppuccin Latte | marker, tk-number | `#fe640b` → `#c72d00` | 2.45 → 4.54 |
| Catppuccin Latte | link, tk-title | `#1e66f5` → `#155dec` | 4.04 → 4.53 |
| Catppuccin Latte | code, tk-string | `#40a02b` → `#0e7a00` | 2.75 → 4.54 |
| Catppuccin Latte | quote, tk-comment | `#7c7f93` → `#65687c` | 3.25 → 4.51 |
| Catppuccin Latte | tk-type | `#df8e1d` → `#a15500` | 2.15 → 4.53 |
| Catppuccin Latte | tk-meta | `#179299` → `#00757c` | 3.08 → 4.50 |
| Gruvbox Light | muted | `#7c6f64` → `#71655a` | 3.87 → 4.50 |
| Gruvbox Light | faint, quote, tk-comment | `#928374` → `#726456` | 2.92 → 4.55 |
| Gruvbox Light | heading, tk-string, tk-title | `#79740e` → `#6f6900` | 3.87 → 4.52 |
| Gruvbox Light | code, tk-meta | `#427b58` → `#397250` | 3.97 → 4.52 |
| Gruvbox Light | tk-type | `#b57614` → `#955800` | 3.00 → 4.55 |
| Tokyo Night Day | text | `#3760bf` → `#2f57b6` | 3.99 → 4.53 |
| Tokyo Night Day | muted | `#6172b0` → `#4a5995` | 3.15 → 4.54 |
| Tokyo Night Day | faint | `#68709a` → `#535a83` | 3.27 → 4.53 |
| Tokyo Night Day | heading, tk-title | `#2e7de9` → `#0058c1` | 2.74 → 4.52 |
| Tokyo Night Day | marker, tk-number | `#b15c00` → `#974500` | 3.25 → 4.52 |
| Tokyo Night Day | link | `#007197` → `#006389` | 3.76 → 4.55 |
| Tokyo Night Day | code | `#118c74` → `#006953` | 2.85 → 4.55 |
| Tokyo Night Day | quote, tk-comment | `#848cb5` → `#535a80` | 2.24 → 4.55 |
| Tokyo Night Day | tk-keyword | `#9854f1` → `#7b30ce` | 2.94 → 4.53 |
| Tokyo Night Day | tk-string | `#587539` → `#496529` | 3.56 → 4.50 |
| Tokyo Night Day | tk-type | `#188092` → `#006678` | 3.15 → 4.51 |
| Tokyo Night Day | tk-meta | `#387068` → `#2e665e` | 3.88 → 4.50 |
| Rosé Pine Dawn | muted, quote | `#797593` → `#6a6683` | 3.67 → 4.56 |
| Rosé Pine Dawn | faint, tk-comment | `#9893a5` → `#6c6778` | 2.48 → 4.55 |
| Rosé Pine Dawn | heading, tk-meta | `#907aa9` → `#76618e` | 3.16 → 4.53 |
| Rosé Pine Dawn | marker | `#b4637a` → `#a05169` | 3.50 → 4.52 |
| Rosé Pine Dawn | code, tk-string, tk-number | `#ea9d34` → `#a05800` | 1.87 → 4.50 |
| Rosé Pine Dawn | tk-title | `#d7827e` → `#a25250` | 2.37 → 4.54 |
| Rosé Pine Dawn | tk-type | `#56949f` → `#34727d` | 2.86 → 4.55 |
| Everforest Light | muted | `#829181` → `#637162` | 2.90 → 4.50 |
| Everforest Light | faint, quote, tk-comment | `#939f91` → `#657063` | 2.41 → 4.52 |
| Everforest Light | heading, tk-title | `#8da101` → `#637400` | 2.53 → 4.55 |
| Everforest Light | marker, tk-keyword | `#f85552` → `#cf2b30` | 2.86 → 4.53 |
| Everforest Light | link | `#3a94c5` → `#0b74a4` | 2.94 → 4.52 |
| Everforest Light | code, tk-string | `#35a77c` → `#007d55` | 2.63 → 4.51 |
| Everforest Light | tk-number | `#df69ba` → `#b34091` | 2.67 → 4.51 |
| Everforest Light | tk-type | `#dfa000` → `#9b5f00` | 2.00 → 4.54 |
| Everforest Light | tk-meta | `#f57d26` → `#bb4800` | 2.33 → 4.53 |
| Kanagawa Lotus | muted, quote | `#766b90` → `#655a7e` | 3.52 → 4.53 |
| Kanagawa Lotus | faint, tk-comment | `#8a8980` → `#616058` | 2.52 → 4.53 |
| Kanagawa Lotus | heading, tk-title | `#4d699b` → `#456092` | 3.95 → 4.50 |
| Kanagawa Lotus | marker | `#cc6d00` → `#9f4400` | 2.61 → 4.56 |
| Kanagawa Lotus | link | `#6693bf` → `#38638d` | 2.32 → 4.51 |
| Kanagawa Lotus | code, tk-string | `#6f894e` → `#4f672d` | 2.80 → 4.54 |
| Kanagawa Lotus | tk-number | `#b35b79` → `#984361` | 3.21 → 4.54 |
| Kanagawa Lotus | tk-type | `#597b75` → `#456660` | 3.33 → 4.53 |
| Kanagawa Lotus | tk-meta | `#77713f` → `#676130` | 3.57 → 4.52 |
| One Light | faint, quote, tk-comment | `#a0a1a7` → `#6c6d73` | 2.26 → 4.53 |
| One Light | heading, marker | `#e45649` → `#c73a30` | 3.22 → 4.52 |
| One Light | link, tk-title | `#4078f2` → `#3066df` | 3.56 → 4.51 |
| One Light | code, tk-string | `#50a14f` → `#2a7d2c` | 2.81 → 4.53 |
| One Light | tk-number, tk-meta | `#b76b01` → `#a55b00` | 3.60 → 4.50 |
| One Light | tk-type | `#cb7701` → `#a95800` | 2.98 → 4.52 |
| Solarized Light | text | `#657b83` → `#576c74` | 3.64 → 4.51 |
| Solarized Light | muted, faint, quote, tk-comment | `#93a1a1` → `#5e6b6b` | 2.18 → 4.52 |
| Solarized Light | heading, tk-meta | `#cb4b16` → `#bc3d00` | 3.76 → 4.50 |
| Solarized Light | marker | `#d33682` → `#c22274` | 3.71 → 4.54 |
| Solarized Light | link, tk-title | `#268bd2` → `#006cb1` | 3.00 → 4.53 |
| Solarized Light | code, tk-string, tk-number | `#2aa198` → `#00756d` | 2.58 → 4.55 |
| Solarized Light | tk-keyword | `#859900` → `#5f7000` | 2.62 → 4.51 |
| Solarized Light | tk-type | `#b58900` → `#8b6100` | 2.62 → 4.50 |
| GitHub Light | faint, tk-comment | `#6e7781` → `#6a737d` | 4.27 → 4.52 |
| Midam (dark) | faint, marker, tk-comment | `#888480` → `#918d89` | 4.02 → 4.53 |
| Catppuccin Mocha | faint | `#7f849c` → `#81869e` | 4.44 → 4.56 |
| Gruvbox Dark | faint, quote, tk-comment | `#928374` → `#a49586` | 3.58 → 4.52 |
| Gruvbox Dark | tk-keyword | `#fb4934` → `#ff654d` | 3.82 → 4.51 |
| Nord | muted, faint, quote, tk-comment | `#616e88` → `#a0aeca` | 1.96 → 4.50 |
| Nord | marker, tk-number | `#b48ead` → `#c9a2c1` | 3.55 → 4.51 |
| Nord | link, tk-keyword | `#81a1c1` → `#90b1d1` | 3.74 → 4.50 |
| Nord | tk-meta | `#d08770` → `#e79c84` | 3.54 → 4.55 |
| Tokyo Night | faint | `#737aa2` → `#7a81aa` | 4.10 → 4.52 |
| Tokyo Night | quote, tk-comment | `#565f89` → `#7781ae` | 2.76 → 4.51 |
| Rosé Pine | faint, tk-comment | `#6e6a86` → `#8783a0` | 3.20 → 4.54 |
| Rosé Pine | tk-keyword | `#31748f` → `#4c8eaa` | 3.16 → 4.52 |
| Everforest Dark | muted | `#9da9a0` → `#9faba2` | 4.44 → 4.55 |
| Everforest Dark | faint, quote, tk-comment | `#859289` → `#9daba1` | 3.33 → 4.52 |
| Everforest Dark | marker, tk-keyword | `#e67e80` → `#f38a8b` | 3.95 → 4.54 |
| Kanagawa Wave | muted, quote | `#938aa9` → `#968dac` | 4.34 → 4.51 |
| Kanagawa Wave | faint, tk-comment | `#727169` → `#939289` | 2.88 → 4.52 |
| Kanagawa Wave | tk-keyword | `#957fb8` → `#9e87c1` | 4.04 → 4.51 |
| One Dark | muted | `#828997` → `#8c93a1` | 3.98 → 4.54 |
| One Dark | faint, quote, tk-comment | `#5c6370` → `#8b93a1` | 2.32 → 4.52 |
| One Dark | heading, marker | `#e06c75` → `#e36e77` | 4.38 → 4.51 |
| Solarized Dark | text | `#839496` → `#8b9c9e` | 4.11 → 4.55 |
| Solarized Dark | muted, faint, quote, tk-comment | `#586e75` → `#859ca3` | 2.42 → 4.51 |
| Solarized Dark | heading, tk-meta | `#cb4b16` → `#f57142` | 2.82 → 4.53 |
| Solarized Dark | marker | `#d33682` → `#fc5ea5` | 2.86 → 4.51 |
| Solarized Dark | link, tk-title | `#268bd2` → `#3f9fe8` | 3.53 → 4.54 |
| Solarized Dark | code, tk-string, tk-number | `#2aa198` → `#35a99f` | 4.12 → 4.54 |
| Solarized Dark | tk-keyword | `#859900` → `#8da218` | 4.06 → 4.53 |
| Solarized Dark | tk-type | `#b58900` → `#be9218` | 4.05 → 4.53 |
| GitHub Dark | faint | `#6e7681` → `#7b838e` | 3.77 → 4.51 |
