# Bundled pixel fonts

The dashboard ships these local webfonts so its disposable report never needs a
font CDN or any font-related network request:

- `ark-pixel-12px-monospaced-zh_cn.woff2` from Ark Pixel Font 2026.07.20
- `fusion-pixel-12px-monospaced-zh_hans.woff2` from Fusion Pixel Font 2026.07.20

Ark Pixel Font is the primary face. Its upstream README currently warns that
the 12px font still lacks many Han characters, so Fusion Pixel Font is the
upstream-recommended glyph fallback for the same pixel style. A static coverage
audit of `src/template.html` found six Han characters missing from Ark and none
missing from the combined stack.

Both font files are distributed under SIL Open Font License 1.1. Their license
texts are retained beside the binaries.

Sources:

- https://github.com/TakWolf/ark-pixel-font/releases/tag/2026.07.20
- https://github.com/TakWolf/fusion-pixel-font/releases/tag/2026.07.20
