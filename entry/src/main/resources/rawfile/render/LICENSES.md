# Vendored web runtimes — licence record

Everything under `entry/src/main/resources/rawfile/render/` is third-party code
that ships **inside the app**, so it must be fully offline and its licence
recorded here. No file in this tree may be fetched from a network at runtime;
all `<script>`/`<link>` references are relative paths into `vendor/`.

Versions were read back out of each downloaded artefact, not taken from the URL
alone (`katex.version` = `0.19.0`).

## Libraries

| File | Upstream project | Version | SPDX | Bytes | Source URL |
|---|---|---|---|---|---|
| `vendor/katex.min.js` | [KaTeX](https://github.com/KaTeX/KaTeX) | 0.19.0 | `MIT` | 272868 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.js |
| `vendor/katex.min.css` | [KaTeX](https://github.com/KaTeX/KaTeX) | 0.19.0 | `MIT` | 24793 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.css |

**KaTeX is the only web runtime left.** Mermaid (5.4 MB) and ECharts (1.1 MB)
were removed: `MdView` rendered every `Chart` block as a 「图表渲染未接入」
placeholder, so neither engine ever executed while occupying 60 % of the HAP.
Do not re-add a full diagram bundle — see `AGENTS.md` §「图表为什么不在包里」.

## KaTeX font set (complete — 20 faces)

These are the fonts `katex.min.css` requests by relative path (`fonts/<name>`).
`KaTeX_Size1`…`Size4` are **required**: they supply the extensible/`\left( … \right)`
delimiters and large operators, and omitting them silently breaks stretchy
brackets and `\sum`/`\int` sizing instead of erroring.

| File | Upstream project | Version | SPDX | Bytes | Source URL |
|---|---|---|---|---|---|
| `vendor/fonts/KaTeX_AMS-Regular.woff2` | [KaTeX](https://github.com/KaTeX/KaTeX) | 0.19.0 | `MIT` | 28076 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_AMS-Regular.woff2 |
| `vendor/fonts/KaTeX_Caligraphic-Bold.woff2` | KaTeX | 0.19.0 | `MIT` | 6912 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Caligraphic-Bold.woff2 |
| `vendor/fonts/KaTeX_Caligraphic-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 6908 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Caligraphic-Regular.woff2 |
| `vendor/fonts/KaTeX_Fraktur-Bold.woff2` | KaTeX | 0.19.0 | `MIT` | 11348 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Fraktur-Bold.woff2 |
| `vendor/fonts/KaTeX_Fraktur-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 11316 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Fraktur-Regular.woff2 |
| `vendor/fonts/KaTeX_Main-Bold.woff2` | KaTeX | 0.19.0 | `MIT` | 25324 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Main-Bold.woff2 |
| `vendor/fonts/KaTeX_Main-BoldItalic.woff2` | KaTeX | 0.19.0 | `MIT` | 16780 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Main-BoldItalic.woff2 |
| `vendor/fonts/KaTeX_Main-Italic.woff2` | KaTeX | 0.19.0 | `MIT` | 16988 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Main-Italic.woff2 |
| `vendor/fonts/KaTeX_Main-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 26272 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Main-Regular.woff2 |
| `vendor/fonts/KaTeX_Math-BoldItalic.woff2` | KaTeX | 0.19.0 | `MIT` | 16400 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Math-BoldItalic.woff2 |
| `vendor/fonts/KaTeX_Math-Italic.woff2` | KaTeX | 0.19.0 | `MIT` | 16440 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Math-Italic.woff2 |
| `vendor/fonts/KaTeX_SansSerif-Bold.woff2` | KaTeX | 0.19.0 | `MIT` | 12216 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_SansSerif-Bold.woff2 |
| `vendor/fonts/KaTeX_SansSerif-Italic.woff2` | KaTeX | 0.19.0 | `MIT` | 12028 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_SansSerif-Italic.woff2 |
| `vendor/fonts/KaTeX_SansSerif-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 10344 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_SansSerif-Regular.woff2 |
| `vendor/fonts/KaTeX_Script-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 9644 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Script-Regular.woff2 |
| `vendor/fonts/KaTeX_Size1-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 5468 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Size1-Regular.woff2 |
| `vendor/fonts/KaTeX_Size2-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 5208 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Size2-Regular.woff2 |
| `vendor/fonts/KaTeX_Size3-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 3624 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Size3-Regular.woff2 |
| `vendor/fonts/KaTeX_Size4-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 4928 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Size4-Regular.woff2 |
| `vendor/fonts/KaTeX_Typewriter-Regular.woff2` | KaTeX | 0.19.0 | `MIT` | 13568 | https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/KaTeX_Typewriter-Regular.woff2 |

Only the `.woff2` faces are vendored. `katex.min.css` also lists `.woff` and
`.ttf` sources in each `@font-face`; every current ArkWeb build supports
`woff2`, so the older formats would be ~1 MB of dead weight and are absent on
purpose. Browsers fall back through the list only if the earlier format fails to
decode, not if the file is missing — so this is safe on API 26.

## Licence texts

- MIT — https://opensource.org/license/mit

## Update policy

When bumping a version: replace **all** files of that project together (the CSS
and the twenty font faces must match `katex.min.js` exactly, or KaTeX measures
the wrong glyph metrics), re-read the version out of the new artefact, and
update the rows above. Never point a harness at a CDN "just for now" — the app
must render with the network disabled.
