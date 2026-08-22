# Chrome — Panel and Bar

**Normative** for how the Cloud SQL Tracker widget looks and behaves.

| Doc | Owns |
|-----|------|
| [`docs/DESIGN.md`](./DESIGN.md) | **Decisions** — what is locked, what is out, why |
| **this file** | **Appearance and interaction** — tokens, glyphs, measurements, keys, copy |
| [`docs/modules.md`](./modules.md) | **Seams** — the Tracker interface these surfaces bind to |
| [`CONTEXT.md`](../CONTEXT.md) | **Vocabulary** — Connection, Group, Health state, Degraded |

If this file and `DESIGN.md` disagree, one of them is a bug. Verified with
[`docs/prototypes/theme-sweep`](./prototypes/theme-sweep/).

Everything here is expressed in `qs.Ui` / `qs.Commons` terms. **No literal colours
and no literal pixel values** — the shell resolves both from the active theme, and
hardcoding either breaks under `omarchy theme set` or a non-default `[font] base-size`.

---

## 1 · Palette

Omarchy exposes exactly five foundational colours (`Commons/Color.qml`). There is no
semantic `success` / `warning` token and **none can be added** — a theme supplies
"what colour is text", not "what colour is healthy".

| Token | Key | Fallback chain |
|-------|-----|----------------|
| `Color.foreground` | `foreground` | `color7` → `#cacccc` |
| `Color.background` | `background` | `color0` → `#101315` |
| `Color.accent` | `accent` | `color4` → `#cacccc` |
| `Color.urgent` | `red` or `color1` (later line wins) | `#a55555` |
| `Color.muted` | `muted` | `color8` → `foreground` |

`colors.toml` defines `green`, `yellow`, `cyan` and friends. **`loadColors()` never
reads them.** They are not available. Do not reach for them.

### Two hazards this spec is built around

**`accent` may equal `foreground`.** `kanagawa` sets both to `#dcd7ba`. Any state
distinction carried by `accent`-vs-`foreground` alone is *invisible* there. This is
why `starting` also spins — motion is the channel that survives.

**`Qt.darker()` is not a de-emphasis primitive.** It divides the HSV *value*, i.e.
blends toward black unconditionally — which only coincides with "toward the
background" on dark themes. Measured across all 22 installed themes it **inverts** on
the four light ones (`catppuccin-latte`, `flexoki-light`, `lupine`, `rose-pine`),
where darkening an already-dark foreground *gains* contrast, and it is a **no-op** on
`white`, whose `foreground` is `#000000` (value already 0, nothing to divide).

> **Rule.** Use `Util.alpha(color, a)` for every de-emphasis. Never `Qt.darker()`.
> `Util.alpha` blends toward the actual background, so it reduces contrast on all 22.

The native panels use `Qt.darker` throughout. That is a wart to *not* copy.

---

## 2 · Health state matrix

Normative. Four states across five channels, so that **no single channel is
load-bearing**: the state is still readable in monochrome, with a colour-vision
deficiency, and on a theme where two tokens coincide.

| Health state | Glyph | Codepoint | Glyph colour | Row fill | Motion | Status line |
|---|:---:|---|---|---|---|---|
| `running`  | `󰌷` | `U+F0337` | `foreground` | `CursorSurface.current` | — | `running` |
| `stopped`  | `󰌸` | `U+F0338` | `alpha(fg, 0.55)` | none | — | `stopped` |
| `starting` | `󰦖` | `U+F0996` | `accent` | none | **spins** | `starting…` |
| `error`    | `󰀪` | `U+F002A` | `urgent` | none | — | *error `code`* |

`U+F0337` / `U+F0338` are a designed MDI pair (chain-link / chain-link-off),
so `running` and `stopped` carry **identical optical weight** — which is what makes
the column read as deliberate rather than as two unrelated icons. The metaphor is
also literally right: a Connection *is* a forwarded link to a remote instance.

`U+F0996` is already this repo's spinner glyph. `U+F002A` is
alert-circle: a filled shape at the same weight as the pair, so the column stays even.

### Glyph family

All glyphs come from the **Nerd Font MDI range** (`U+F0000`–`U+F1AF0`), which resolves
to the same family as the text (`fc-match monospace` → `JetBrainsMono Nerd Font`
here). Plain Unicode geometric shapes are **forbidden**: `U+25CF`, `U+25CC`, `U+25D0`,
`U+25B2` all fall back to Liberation Sans — a different family, weight and vertical
metric, which reads as pasted in.

Verify any new glyph before using it:

```bash
fc-match ":charset=F0337" family     # must name the same family as `fc-match monospace`
```

### Literal characters, never `\u` escapes

All five glyphs live **above `U+FFFF`** (Supplementary Private Use Area-A), which
`\uXXXX` cannot express. A four-hex-digit escape silently truncates and the leftover
digit becomes a literal character:

| Role | Codepoint | Write this | `"\uXXXXX"` actually yields |
|------|-----------|:----------:|------------------------------|
| running | `U+F0337` | `󰌷` | `\uF033` + `"7"` |
| stopped | `U+F0338` | `󰌸` | `\uF033` + `"8"` |
| starting | `U+F0996` | `󰦖` | `\uF099` + `"6"` |
| error | `U+F002A` | `󰀪` | `\uF002` + `"A"` |
| cloud | `U+F015F` | `󰅟` | `\uF015` + `"F"` |

This does not fail loudly. `\uF033` is a **valid glyph** in the older nf-fa range, so
the result is a plausible-looking wrong icon followed by a stray digit.

> **Rule.** Embed the literal glyph character in the QML source — the way
> `bluetooth/Panel.qml` writes `text: row.isConnected ? "󰂱" : "󰂯"`. If an
> escape is unavoidable, use the surrogate pair (`"\uDB80\uDF37"` for `U+F0337`).

### Render glyphs through `OpticalGlyph`

Nerd Font glyphs have painted bounds that do not match their advance width, by a
*different* amount per glyph. A plain `Text` per row therefore leaves each glyph
optically off-centre by a different amount, and a column of them visibly jitters.
`Ui/OpticalGlyph.qml` measures `tightBoundingRect` and corrects horizontally only,
deliberately leaving the baseline alone to avoid vertical drift.

> **Rule.** Every state glyph in the row column is an `OpticalGlyph`, not a `Text`.

### Vertical alignment — no correction needed, and why

Measured from the font, every glyph in §2 has its ink centred on **exactly the same
axis**, 360/1000 em:

| Role | `yMin` | `yMax` | ink centre |
|------|-------:|-------:|-----------:|
| running `U+F0337` | 151 | 569 | **360** |
| stopped `U+F0338` | −15 | 735 | **360** |
| starting `U+F0996` | −56 | 776 | **360** |
| error `U+F002A` | −36 | 756 | **360** |
| cloud `U+F015F` | 26 | 694 | **360** |

And `(hhea.ascender − descent) / 2 = (1020 − 300) / 2 = 360`. The Nerd Font patcher
aligns every icon to the Latin line box's own centre, so an `OpticalGlyph` centred in
its box is **already vertically correct** — and the four-state column cannot drift,
because all four corrections are identically zero.

> **Rule.** Never apply a per-glyph vertical correction. It is unnecessary for these
> glyphs, and in a multi-glyph column it would *introduce* the drift `OpticalGlyph`
> was written to avoid.

The single exception is the hero, and it is a **design shift, not a correction** — §4.

---

## 3 · Measurements

Expressed as tokens. Resolved values shown for `[font] base-size = 12`,
`[spacing] scale = 1` — **for orientation only, never to hardcode**.

| Thing | Token | @12 |
|-------|-------|----:|
| Panel content width | `Style.space(380)` | 380 |
| Panel height cap | `Style.space(560)` | 560 |
| Panel padding | `Style.spacing.popupPadding` | 14 |
| Row horizontal padding | `Style.spacing.rowPaddingX` | 12 |
| Row / control gap | `Style.spacing.controlGap` | 8 |
| Toggle track | `42 × 22` derived by `ToggleSwitch` | 42×22 |
| Group action button | `PanelActionButton.size` | 22 |
| Connection name | `Style.font.body` | 12 |
| Status line | `Style.font.caption` | 10 |
| Group header label | `Style.font.caption` | 10 |
| Hero title | `Style.font.title` | 14 |
| Hero meta | `Style.font.caption`, bold, `letterSpacing 1.2` | 10 |
| Hero icon | `Style.font.display` | 24 |
| Hero icon → title gap | `Style.space(14)`, owned by `PanelHero` | 14 |
| Hero icon optical lift | `Style.space(2)` — §4 note 1 | 2 |
| `running` row fill | `Style.selectedFillAlpha` | 0.18 |
| Hover / cursor fill | `Style.hoverFillAlpha` | 0.08 |

`380 × 560` is the shell's default for list panels — 7 of 10 native panels use 380.
Both go through `fittedContentWidth` / `fittedContentHeight`, so they are **caps**
fitted to the real screen, not fixed sizes.

---

## 4 · Anatomy

### Panel header — `PanelHero`

```
┌────────────────────────────────────────────────┐
│  󰅟   Cloud SQL Tracker         [ Stop all ]  │
│      1 of 7 running · 2 error                  │
└────────────────────────────────────────────────┘
```

| Slot | Content |
|------|---------|
| `iconComponent` | `OpticalGlyph`, `fontSize: Style.font.display`, **explicitly sized** — see note 1 below. Glyph `U+F015F` |
| `title` | `"Cloud SQL Tracker"` |
| `meta` | `"<running> of <total> running"`, `+ " · <n> error"` when `errorCount > 0` |
| `trailingControl` | `Button` `"Stop all"`, `bordered: true` |

`Stop all` is visible only when `degraded === null && total > 0`, and is **one-way** —
see `DESIGN.md`. `iconOpacity` follows the native idiom: full when `runningCount > 0`,
`0.5` when nothing is running.

Then a `PanelSeparator`.

#### Four `PanelHero` behaviours to design around

`PanelHero` is not fully parameterised. These are its internals, not choices:

1. **The hero icon needs a 2px optical lift, and `PanelHero` will not do it.**
   `iconLoader` and `heroLabels` are both hardcoded to `parent.verticalCenter`, which
   centres the glyph on the label block's *geometric* middle. But that block —
   `Style.font.title` bold over `Style.font.caption` bold uppercase — is top-heavy, so
   it reads as centred *above* its geometric middle, and a geometrically-centred icon
   looks low. Measured against the type: the block is `33.68px` tall, the geometric
   centre `16.84px`, the title's cap-band centre `9.17px`, and an optical centre
   weighted 2:1 toward the title `15.12px` — a **1.72px** lift, i.e. `Style.space(2)`.
   (Aligning fully to the title would be a `7.67px` lift, which overhangs a `24px`
   glyph in a `33.68px` block.) Apply it *inside* the component you hand to
   `iconComponent`, since `PanelHero` owns the loader's anchors:

   ```qml
   iconComponent: Component {
     Item {
       implicitWidth: Style.font.display
       implicitHeight: Style.font.display
       OpticalGlyph {
         width: parent.width
         height: parent.height
         anchors.horizontalCenter: parent.horizontalCenter
         anchors.verticalCenter: parent.verticalCenter
         anchors.verticalCenterOffset: -Style.space(2)   // optical lift, §2
         text: "󰅟"                                     // literal, never \u — §2
         fontSize: Style.font.display
         color: root.bar.foreground
       }
     }
   }
   ```

   This is the **only** vertical glyph offset in the plugin. Row glyphs get none (§2).

2. **`OpticalGlyph` has no implicit size.** It is a bare `Item` whose inner `Text` is
   `anchors.centerIn: parent`, so an unsized instance is `0 × 0` — `iconLoader`
   collapses, `heroLabels` anchors to `x = 0`, and the glyph paints *through* the
   title. Give it an explicit box (`width: height: Style.font.display`), the way
   `BarIconButton` (`anchors.fill: parent`) and the clock bar widget (explicit
   `width`/`height`) both do. `PanelHero`'s `Style.space(14)` gap is measured from
   that box's right edge — without a box there is no gap at all. The snippet in note 1
   shows the sizing.
3. **`meta` is forced uppercase**: `text: root.meta.toUpperCase()`, bold,
   `letterSpacing 1.2`, at `Style.font.caption`. Not overridable. Write `meta` in
   sentence case and expect `1 OF 7 RUNNING · 2 ERROR` on screen. The §10 ban on
   uppercase letter-spaced text governs the **row status line**, which this spec owns;
   the hero meta belongs to the component.
4. **`meta` and `detail` are dimmed with `Qt.darker(foreground, 1.4)`**, hardcoded as
   `PanelHero.dim`. The §1 light-theme inversion is therefore baked into this
   component and cannot be corrected from outside; the only lever is `metaOpacity`
   (aliased to `metaText.opacity`). Accept it, for consistency with every native
   panel, rather than forking the component — but do not replicate the idiom in code
   this spec owns.

### Group header — `PanelSectionHeader` + counts + actions

```
BACKEND                        1/2   󰐊  󰓛
FE                     0/3 · 2 err   󰐊  󰓛
```

| Element | Spec |
|---------|------|
| Label | `PanelSectionHeader`, group name **uppercased**. Note it dims itself with `Qt.darker(foreground, 1.4)` internally — the §1 light-theme inversion is baked in, as with `PanelHero.meta`; accept it for consistency rather than forking the component |
| Counts | Right-aligned, `Style.font.caption`, `alpha(fg, 0.5)`. `"<running>/<total>"`, `+ " · <n> err"` when `error > 0` |
| Start | `PanelActionButton`, `U+F040A`, tooltip `"Start group"` |
| Stop | `PanelActionButton`, `U+F04DB`, tooltip `"Stop group"` |

The whole group header is itself a **`CursorSurface`**, which is what makes
"revealed on hover" implementable — a `PanelSectionHeader` is only a label and has no
pointer handling of its own:

| Property | Value |
|----------|-------|
| `hasCursor` | `cursorActive && focusSection === "group:<g>" && selectedIndex === -1` |
| `current` | `false` — reserve the persistent fill for `running` rows (§2) |
| Action button reveal | `opacity: hasCursor ? 1 : 0` on the enclosing `Row`, **never `visible`** — see §5 "Geometry stability" |
| Action button input gate | `enabled: revealed && !tracker.busy` — opacity-0 items still take clicks |

Its `MouseArea` sets `cursorActive = true`, `focusSection = "group:<g>"`,
`selectedIndex = -1` on hover, exactly as the row's does — that shared write is what
keeps mouse and keyboard on one cursor (§6). This mirrors
`bluetooth/Panel.qml`'s forget button, which is revealed by
`rowMouse.containsMouse || rowSelected`.

Group order comes from `Tracker.groups`, which mirrors the Status document's own
config order. Never re-sort it.

### Connection row — `CursorSurface`

```
     󰌷   Backend Dev                        ━━●
         running · 127.0.0.1:15432
     󰌸   Backend Prod                       ●━━
         stopped · 127.0.0.1:15433
     󰀪   FE Dev                             ●━━
         port_in_use · 127.0.0.1:15434
```

| Property | Value |
|----------|-------|
| `hasCursor` | `cursorActive && focusSection === "group:<g>" && selectedIndex === <i>` |
| `current` | `state === "running"` — gives the fill from §2 for free |
| Leading | `OpticalGlyph` in a `Style.space(20)` box at `Style.font.heading`, §2 glyph + colour, spinning when `starting`. Sized explicitly — see §4 note 1 |
| Line 1 | Connection **`name`** at `Style.font.body`. Never the `id` |
| Line 2 | `"<state> · <address>:<port>"` at `Style.font.caption`, `alpha(fg, 0.55)` |
| Line 2 when `error` | `"<error.code> · <address>:<port>"` in `urgent` |
| Trailing | `ToggleSwitch` |
| Tooltip | `PanelToolTip` with `error.detail`, **only** when `state === "error"` and `detail` is non-empty |

The full `error.detail` lives in the tooltip, not the row — it can run to 100+
characters, which would wrap a row to three lines and destroy the uniform row height
the cursor depends on.

Fields shown are exactly `name`, `state`, `address`, `port`, `error.code`
(+ `error.detail` in the tooltip). **No** `instance`, `unit`, `pid`, `uptime`,
`source`, `private_ip` — `DESIGN.md` v1 non-goals.

### `ToggleSwitch` semantics

| Property | Value |
|----------|-------|
| `checked` | `state === "running" \|\| state === "starting"` |
| `busy` | `tracker.busy && tracker.busyKey === "id:" + id` |
| `interactive` | `!tracker.busy` — see §5 |
| `onToggled` | `canStart(state) ? tracker.start(...) : tracker.stop(...)` |

`canStart(state)` is `state === "stopped" || state === "error"`. The **UI** picks the
verb; `Tracker` deliberately has no `toggle()` (`docs/modules.md`).

---

## 5 · Busy

`Tracker` runs **one action at a time**: `_runAction` returns early and silently
when `actionProc.running`. So a control that stays live during another action is a
**dead click** — it looks active and does nothing.

> **Rule.** While `tracker.busy`, every action control **stops accepting clicks**.
> But **nothing dims.** An action is a sub-second CLI round trip; dimming every idle
> control for its duration reads as the whole panel flashing on every toggle.
> `ToggleSwitch` makes the same point about its own `busy`: it *"swallows further
> clicks, but leaves hover, cursor, and tooltips alone so the control does not
> flicker."* Feedback comes from the three positive signals below, not from taking
> the panel away.

| Control | Blocks clicks via | Visually silent when blocked? |
|---------|-------------------|-------------------------------|
| Row `ToggleSwitch` | `busy: tracker.busy` | Yes — `busy` gates only `onClicked` |
| Group start / stop | `enabled` | Yes — the Row sits at `opacity: 0` unless revealed |
| `Stop all` | `enabled` | Yes — `Button` colours derive from `selected`/`foreground`, never `enabled` |

**Never `ToggleSwitch.interactive` for this.** It means "the surrounding row owns the
click", and `cursorRing` derives from it — see the geometry rule below.

### The three positive signals

1. **Optimistic knob throw.** The acting row's `checked` is the *target* state while
   `busyKey` matches it, so the knob moves on click instead of waiting out the CLI
   plus the 500ms `delayedRefresh`. Derive the target the same way `toggleConnection`
   picks its verb. A failed action polls back to the unchanged state and the knob
   returns — correct, not a glitch.
2. **Group spinner.** The acting Group's start button swaps to the spinner glyph and
   rotates. `busyKey` names the Group, not the verb, so there is nothing to attribute
   a separate spinner control to — and adding one would change the Row's extent.
3. **`starting` state.** Once the poll lands, the Connection reports `starting` and
   its glyph spins (§2) — the durable signal the other two bridge to.

### Geometry stability

Three of this kit's components change their **implicit size** when a state property
flips. Bind any of them to a transient state and the panel visibly jumps:

| Trap | Mechanism | Effect |
|------|-----------|--------|
| `ToggleSwitch.interactive` | `cursorRing: interactive`, `_pad: cursorRing ? cursorPad : 0`, `implicitWidth: trackWidth + _pad*2` | Switch shrinks `54×34` → `42×22` |
| `visible` on a reveal inside a `Row` | `Row` skips invisible children entirely | Row collapses: header height jumps, siblings anchored to its edge slide |
| `Button.iconText` `""` → glyph | Icon `Text` is `visible: iconText !== ""` inside a Row with `controlGap` | Button widens, moving `PanelHero.trailingInset` and reflowing the title |

> **Rule.** Never bind a geometry-affecting property to a transient state — busy,
> hover, or cursor. Reveal with **`opacity`** and gate input with **`enabled`**
> (opacity-0 items still take mouse input, so both are needed). `enabled` is safe on
> every control here: none of their implicit sizes depend on it.

Not affected, and safe to swap freely: `PanelActionButton.iconText`
(`implicitWidth: size`, independent of content), and `PanelToolTip.visible`
(a popup, never in layout).

`busyKey` shapes are `"id:<id>"`, `"group:<name>"`, `"all"` — opaque to the UI beyond
string identity. Rows are never removed or re-ordered while busy: `Tracker` keeps the
last good view (`_hasGoodDocument`), so the switchboard stays stable under the cursor.

## 6 · Keyboard

Every native panel is fully mouse-free, and `plugins/dev-gallery/GalleryPanel.qml`
names `plugins/panels/audio/Panel.qml` as the recipe to copy. This panel copies it.

### Cursor state — three properties, one cursor

```qml
property bool   cursorActive: false   // no highlight until keyboard or mouse arrives
property string focusSection: ""      // "header" | "group:<name>"
property int    selectedIndex: -1     // -1 = the section's own header, 0..n-1 = row
```

`"header"` is **virtual**: it is the hero's `Stop all` and never appears in
`visibleSections`. Mouse `onHovered` writes these same three properties, which is how
mouse and keyboard share one highlight instead of fighting over two.

| Key | Target | Action |
|-----|--------|--------|
| `j` / `k` | anywhere | Walk rows, crossing Group boundaries; `k` from the first Group's header reaches `"header"` |
| `Enter` | Connection row | Toggle that Connection — same verb rule as the mouse |
| `Enter` | Group header (`-1`) | Toggle the Group: `stop` if `running + starting > 0`, else `start` |
| `Enter` | `"header"` | Stop all |
| `h` / `l` | Group header (`-1`) | Explicit `stop` / `start` for that Group |
| `Esc` | anywhere | Close |
| `Tab` | anywhere | `switchPanel(direction)` |

The keyboard needs one verb where the mouse has two buttons, hence `Enter`'s toggle
heuristic; `h`/`l` remain for the explicit asymmetric actions.

### Traversal rules

- `visibleSections` = every rendered Group, in `Tracker.groups` order.
- `sectionCount("group:<g>")` = number of Connections in that Group.
- `selectedIndex === -1` is **always** a valid target, even for a Group with zero
  Connections — `j` from it skips straight to the next section's `-1`.
- **Degraded, and empty (`total === 0`)**: **no cursor targets at all** in either
  case. `"header"` *is* the `Stop all` button, and that is hidden whenever
  `degraded !== null || total === 0` — so there is nothing to land on and no rows
  either. `j`/`k`/`h`/`l`/`Enter` are all no-ops; `Esc` and `Tab` still work, and
  `cursorActive` stays `false` so no highlight is ever painted.
- Clamp on every model change — a poll can shorten the list under a live cursor.
- `ListView` with `ScrollBar.AsNeeded`; `positionViewAtIndex(i, ListView.Contain)` on
  cursor move so `Contain` only scrolls when the row is actually clipped, and never
  lurches under a hovering mouse.

---

## 7 · Degraded and empty

**Degraded is not a Connection's `error`.** It means the plugin cannot trust the
control plane, so it must not render a switchboard at all — an empty healthy-looking
panel would read as "all stopped", which is a lie. The Groups `Repeater` stays guarded
on `degraded === null`, so a stale-but-known document never renders underneath.

Title in `urgent` at `Style.font.subtitle`, bold. Body is `Tracker.degraded.message`
verbatim at `Style.font.bodySmall`, `alpha(fg, 0.7)`.

| `degraded.kind` | Title |
|-----------------|-------|
| `cli_missing` | `cloud-sql-tracker not found` |
| `cli_old` | `cloud-sql-tracker is too old` |
| `schema` | `Status document not understood` |
| `status_failed` | `Status check failed` |
| *(unknown)* | `cloud-sql-tracker unavailable` |

The unknown fallback is required: `degraded.kind` is a `Tracker` value, and a future
kind must not render a blank body.

### Empty — `degraded === null && total === 0`

```
No connections configured.

Add connections with the CLI's config file:
~/.config/cloud-sql-tracker/connections.json
```

First line `Style.font.body` in `foreground`; the rest `Style.font.bodySmall` at
`alpha(fg, 0.7)`. The path is **selectable** (`TextEdit`, `readOnly: true`,
`selectByMouse: true`) so it can be copied rather than retyped.

> The path is **text only**. The plugin never opens, reads, parses or writes
> `connections.json` — it is CLI-owned. This is a hard architectural boundary
> (`DESIGN.md`, `CONTEXT.md`), not a convenience.

---

## 8 · Bar

| Property | Value |
|----------|-------|
| Glyph | `U+F015F` `󰅟` — **not** `☁` `U+2601` |
| Text | glyph + `runningCount` |
| `active` | `degraded !== null \|\| errorCount > 0` → the kit's `bar.active` affordance |
| Tooltip | `degraded.message`, else `"<running>/<total> running"` `+ " · <n> error"` |

`☁` `U+2601` resolves to **Noto Sans CJK JP** — a different family from the count
beside it, and tofu wherever that font is absent. See §2 "Glyph family".

---

## 9 · Component inventory

Everything below already exists in `qs.Ui`. Hand-rolling a substitute is a defect: it
skips the theme's `[controls]` state tokens, so it stops matching the rest of the shell
the moment a theme customises them.

| Need | Use |
|------|-----|
| Panel header | `PanelHero` |
| Section label | `PanelSectionHeader` |
| Divider | `PanelSeparator` |
| Row surface + hover/cursor | `CursorSurface` |
| Icon-only row action | `PanelActionButton` |
| On/off with in-flight state | `ToggleSwitch` |
| Text button | `Button` |
| Hover explanation | `PanelToolTip` |
| Centred Nerd Font glyph | `OpticalGlyph` |
| Scrolling list | `ListView` + `ScrollBar` |
| Key handling | `PanelKeyCatcher` |
| Popup shell | `KeyboardPanel` |

---

## 10 · Do not

- No literal colours. No literal pixels. Tokens only.
- No `Qt.darker()`. `Util.alpha()` instead (§1).
- No `colors.toml` colours beyond the five in §1 — the rest are not loaded.
- No plain-Unicode glyphs (§2).
- No uppercase letter-spaced state captions (`RUNNING`) **in the row status line** —
  that appears nowhere in the shell. Sentence case. (`PanelHero` uppercases its own
  `meta`; that is the component's business, not ours — §4.)
- No unsized `OpticalGlyph`, ever — §4 note 2.
- No `\uXXXX` escapes for glyphs. Literal characters only — §2.
- No per-glyph vertical glyph offsets. The hero's `Style.space(2)` lift is the single
  sanctioned exception — §2, §4 note 1.
- No `Process`, argv, or `Model.js` in `Panel.qml` / `BarWidget.qml`. Bind to
  `Tracker` only (`docs/modules.md`).
- No second pane, no tabs, no `restart` / `doctor` / `logs` — `DESIGN.md` non-goals.
- No re-sorting Groups or Connections. Status document order is the contract.

---

## 11 · Verification

1. `node scripts/check-model.js` — must pass unchanged. `Model.js` is not touched by
   chrome work, and these checks passing is the proof.
2. [`docs/prototypes/theme-sweep`](./prototypes/theme-sweep/) — re-check §1 and §2
   whenever a token mapping or glyph changes.
3. `omarchy plugin validate` via `./scripts/dev-link`.
4. Live: all four `degraded.kind` bodies, the empty body, and all four Health states.
   `fixtures/` covers happy / empty / bad-version.
5. Keyboard: reach every control with `j`/`k`/`h`/`l`/`Enter` and confirm exactly one
   highlight is ever visible.
