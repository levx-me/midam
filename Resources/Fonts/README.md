# Bundled fonts

WOFF2 files, given to the page as @font-face rules by render.js. They are not registered with the
app: Settings draws each family's regular face straight from its file (BundledFonts.regular), since
registering WOFF2 cost about 1 s at launch and slowed every later font query. Licence texts are in
LICENSES/. All are SIL Open Font License 1.1. Files come from each project's official release.
They are either the upstream WOFF2 or the upstream variable TTF re-encoded losslessly to WOFF2
with fontTools: the glyphs, names and tables are unchanged, and nothing is subset.

| Family (as listed) | Files | KB | Source | Licence |
|---|---|---|---|---|
| Pretendard Variable | PretendardVariable.woff2 | 2009 | orioncactus/pretendard v1.3.9 (web/variable/woff2) | OFL-1.1, © 2021 Kil Hyung-jin |
| Literata | Literata, Literata-Italic | 774 | googlefonts/literata 3.103 (fonts/webfonts, opsz+wght) | OFL-1.1, © 2017 The Literata Project Authors |
| Source Serif 4 Variable | SourceSerif4, SourceSerif4-Italic | 758 | adobe-fonts/source-serif 4.005R (WOFF2/VAR, TTF flavour) | OFL-1.1, © 2014-2023 Adobe, RFN "Source" |
| iA Writer Quattro V | iAWriterQuattroV, -Italic | 99 | iaolo/iA-Fonts (iA Writer Quattro/Variable, TTF re-encoded) | OFL-1.1, © 2018 Information Architects Inc., RFN "iA Writer" |
| Geist | Geist, Geist-Italic | 139 | vercel/geist-font v1.8.1 (Geist/webfonts) | OFL-1.1, © 2023 Vercel with basement.studio |
| Plus Jakarta Sans | PlusJakartaSans, -Italic | 125 | tokotype/PlusJakartaSans 2.7.1 (variable, TTF re-encoded) | OFL-1.1, © 2020 The Plus Jakarta Sans Project Authors |
| JetBrains Mono | JetBrainsMono, -Italic | 231 | JetBrains/JetBrainsMono v2.304 (fonts/variable, TTF re-encoded) | OFL-1.1, © 2020 The JetBrains Mono Project Authors |
| Geist Mono | GeistMono, GeistMono-Italic | 147 | vercel/geist-font v1.8.1 (GeistMono/webfonts) | OFL-1.1, © 2023 Vercel with basement.studio |
| Source Code Pro | SourceCodePro, SourceCodePro-Italic | 162 | adobe-fonts/source-code-pro 2.042R-u/1.062R-i/1.026R-vf (WOFF2/VF, TTF flavour); the default code font | OFL-1.1, © 2023 Adobe, RFN "Source" |
| D2Coding | D2Coding, D2Coding-Bold | 2992 | naver/d2codingfont VER1.3.2 (static TTF re-encoded) | OFL-1.1, © 2015 NAVER Corp., RFN "D2Coding" |

| KaTeX (math only) | KaTeX_*.woff2 (20 files) | 296 | KaTeX 0.19.0 (npm `katex`, dist/fonts) | MIT, © 2013-2020 Khan Academy and other contributors |

Total: 7822 KB on disk.

The KaTeX fonts are not registered with the app and not offered as reading fonts: only the page's
math uses them, through `Resources/katex.min.css`, whose `url()`s were rewritten to
`midam-font:///KaTeX_*.woff2` (WOFF2 only) when it was vendored.

Not bundled:
- **Inter**: Pretendard's Latin is Inter-based, and the user dropped it.
- **MaruBuri**: Naver's distribution says only "오픈 라이선스 (상업적 사용 허용)" (open licence, commercial use allowed), with no licence text in the download or the font. Add it once a licence text can be included.

Reserved Font Names (Source, iA Writer, D2Coding): the files are unmodified apart from the lossless
WOFF2 encoding, which the OFL FAQ does not treat as a Modified Version.
