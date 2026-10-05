# CrossDiff brand assets

Two aligned documents, one removal, one addition. The slate blue panels and soft
rose/green change markers mirror a side-by-side comparison. Explicit minus and
plus shapes communicate the difference without relying on color alone.

The bilingual README banners pair the established icon with the “Compare everything”
direction, four product values, eleven available comparison types, and plugin expansion.
They are promotional compositions, not screenshots or promises of future capabilities.

The icon uses an inset macOS tile with a transparent surround. At 16 and 32 pixels,
secondary document lines are omitted to keep the mark legible.

| Asset | Use |
| --- | --- |
| `icon.svg` | Resolution-independent icon with a transparent surround |
| `icon-1024.png` | 1024 × 1024 app / project icon |
| `wordmark.svg`, `wordmark.png` | Transparent logo for light backgrounds |
| `hero.svg`, `hero.png` | 1600 × 700 English README / project banner |
| `hero-zh-CN.svg`, `hero-zh-CN.png` | 1600 × 700 Simplified Chinese README / project banner |

The canonical drawing is [`scripts/make-icon.swift`](../../scripts/make-icon.swift).
The SVG and PNG assets are generated from the same geometry; no downloaded images,
external fonts, or network requests are used. SVG wordmarks use the viewer's system
sans-serif font; PNG wordmarks are rendered with the macOS system font.

Regenerate all assets on macOS from the repository root:

```sh
bash scripts/build-brand.sh
```

The command keeps intermediate files under `.build/brand/` and validates the ten
ICNS representations through macOS ImageIO. The normal app build generates its own
iconset from the same drawing and packages it with `scripts/pack-icon.swift`.

These original project assets are included under the repository's [license](../../LICENSE).
