# PROTOTYPE — glyph + palette sweep (throwaway)

Verification harness for the Panel chrome pass. **Not** production QML, and not a
design deliverable — it exists to answer two questions that cannot be answered by
reading code:

1. **Do the candidate state glyphs actually look like their names?** Presence in
   the font is verifiable from the shell (`fc-match ":charset=<cp>"`); *shape* is
   not. Pick by eye in §1.
2. **Does the health-state system survive every installed palette?** Omarchy
   exposes only five foundational colors, so a state system leaning on hue breaks
   on themes where two of them coincide.

## Open

```bash
xdg-open docs/prototypes/theme-sweep/index.html
```

No build step, no server. Palettes are **inlined** rather than fetched — `file://`
blocks `fetch`, the same constraint the `status-ui` prototype worked around.

## Sections

| § | What it shows |
|---|---------------|
| **1** | Glyph candidates for `running`/`stopped` (as pairs, so you can judge weight matching), `starting`, `error`, and the group start/stop actions. Clicking updates §2 and §3 live. |
| **2** | One row rendered at real `Style.qml` measurements — `Style.space(380)` content width, `42×22` switch with a `16px` knob, `22×22` action buttons, `running` fill at `selected-fill-alpha 0.18`. |
| **3** | All installed palettes × all four states. |
| **4** | `Qt.darker(fg, 1.4)` vs `Util.alpha(fg, 0.7)`, with WCAG contrast ratios against each theme's own background. |

## Palette derivation

`PALETTES` is a faithful port of `Commons/Color.qml` `loadColors()`, **including its
fallback chain** — that fidelity is the point, since the interesting failures live in
the fallbacks:

| Token | Source | Fallback |
|-------|--------|----------|
| `foreground` | `foreground` | `color7` |
| `background` | `background` | `color0` |
| `accent` | `accent` | `color4` |
| `muted` | `muted` | `color8`, then `foreground` |
| `urgent` | `red` or `color1` (later line wins) | `#a55555` |

Note that **no shipped theme sets `urgent` explicitly** — it is always derived from
`red`/`color1`, which is why `urgent` is dependable as the error hue.

## What the sweep found

- **`kanagawa`** sets `accent == foreground == #dcd7ba`. Any state system that
  distinguishes `running` from `starting` by hue alone is invisible there. This is
  why `starting` also spins.
- **`Qt.darker(fg, 1.4)`** — the de-emphasis idiom used by `Panel.qml` and by the
  native panels — fails on 5 of 22 themes: it **inverts** on the four light themes
  (`catppuccin-latte`, `flexoki-light`, `lupine`, `rose-pine`), where darkening an
  already-dark foreground *gains* contrast, and it is a mathematical **no-op** on
  `white`, whose `foreground` is `#000000` (HSV value already 0, nothing to divide).
  `Util.alpha(fg, 0.7)` reduces contrast on all 22.
- Plain Unicode geometric shapes (`U+25CF`, `U+25CC`, `U+25D0`, `U+25B2`) resolve to
  **Liberation Sans**, not the Nerd Font — different family, weight and vertical
  metrics. All state glyphs must come from the Nerd Font MDI range.
- `☁` `U+2601`, used by `BarWidget.qml` today, resolves to **Noto Sans CJK JP** —
  a different family from the count rendered beside it, and tofu on any machine
  without Noto CJK.

## Lifecycle

Throwaway, like `../status-ui`. Once `docs/chrome.md` records the confirmed glyphs
and token mappings, this page's job is done — keep it only as long as it is useful
for re-checking a palette question.
