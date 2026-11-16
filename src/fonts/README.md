# Bundled pixel font

The dashboard ships one local webfont so its disposable report never needs a
font CDN or any font-related network request:

- `fusion-pixel-12px-monospaced-zh_hans.woff2` is
  `fusion-pixel-12px-monospaced-zh_hans.ttf.woff2` from Fusion Pixel Font
  2026.11.10, unmodified apart from the file name. Internal family name
  `Fusion Pixel 12px Mono zh-Hans`, Regular only, TrueType outlines.

Fusion Pixel Font is TakWolf's Ark Pixel Font with Han coverage filled in from
the fonts listed below. It contains every code point of Ark Pixel 12px
monospaced `zh_cn` 2026.07.20, the face this dashboard used to load first, with
the same metrics (1200 units per em, ascent 1000, descent 200, half-width 600,
full-width 1200). It covers all 3755 level-1 GB2312 Han characters and 2972 of
the 3008 level-2 ones.

Compared with the previous pair (Ark Pixel plus Fusion Pixel 2026.07.20, both
CFF-flavoured woff2), rendered at 10x on whole pixels, 385 of the 389 characters
in the template and the demo snapshot keep the same bitmap; upstream redrew `–`,
在, 开 and 该. At 12px the strokes come out a little lighter, because Windows
antialiases TrueType and CFF outlines differently. The font also brings
contextual alternates that the browser applies by default and the page keeps:
a colon between two digits is raised to the middle of the digits (`calt`), and
two em dashes join into one line (`ccmp`).

A static audit of `src/template.html` against this release finds one character
the page can show that the font lacks: `≥` (U+2265), the lower-bound prefix on
incomplete amounts and token counts. It falls through the stack to the next
installed face (Cascadia Mono, then Microsoft YaHei or Consolas), exactly as it
did with the previous pair, which lacked it too.

The license texts from the release archive are retained beside the binary:

| File here | File in the release archive | Covers |
| --- | --- | --- |
| `OFL-Fusion-Pixel-Font.txt` | `OFL.txt` | Fusion Pixel Font (SIL OFL 1.1) |
| `OFL-Ark-Pixel-Font.txt` | `LICENSES/ark-pixel/OFL.txt` | Ark Pixel Font, its base (SIL OFL 1.1) |
| `OFL-Cubic-11.txt` | `LICENSES/cubic-11/OFL.txt` | Cubic 11 glyphs it includes (SIL OFL 1.1), with the free-use notices of the M+ bitmap fonts and JF Dot M+H 12 that Cubic 11 derives from |
| `LICENSE-Galmuri.txt` | `LICENSES/galmuri/LICENSE.txt` | Galmuri glyphs it includes (SIL OFL 1.1) |

Source:

- https://github.com/TakWolf/fusion-pixel-font/releases/tag/2026.11.10
- Asset `fusion-pixel-font-12px-monospaced-ttf.woff2-v2026.11.10.zip`,
  6,747,224 bytes, SHA-256
  `48bed8f8b0e8990bc8d3ed124a1987820b6d6c79bacbdb6bfcbbdad549177824`
- `fusion-pixel-12px-monospaced-zh_hans.woff2`, 957,056 bytes, SHA-256
  `16783b4599928e20fff825fdcf93a67782b371e9593640cb171e3a3dcf901f68`

Releases before this one also shipped `ark-pixel-12px-monospaced-zh_cn.woff2`.
`install.ps1` deletes that retired file from an installed runtime after an
upgrade commits, `uninstall.ps1` removes it with the rest of a repository
mirror, and the generator deletes a copy an older run left in its temporary
report directory.
