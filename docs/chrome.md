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

### `starting` is projected from intent, not waited for

The state a row renders is `displayState`, not the polled Health state: while an
intent to **start** is outstanding and the Connection is not already `running` or
`starting`, the row renders `starting` across all five channels.

Without it, `starting` is nearly unreachable from a panel action. `start` **blocks
until the port opens** (`--wait-ms`, default `10000`), so the guaranteed post-action
poll — `delayedRefresh`, 500ms after the process exits — always observes the
*finished* state. Catching a genuine `starting` document needs a `pollTimer` tick to
land inside the start window, which `reconcile.v1.md` puts at *typically ~1s*, against
a 2s interval while the panel is open. Measured, a `status --json` costs 23ms, so the
document is cheap; the problem is purely when it is asked for. The result was that
rows went link-off → link with no `starting` ever on screen, and the only working
progress signal was the Group button's spinner.

**Truth still wins, it just lands second.** The first document to arrive with no
action in flight drops the intent (§5), so a start that took resolves to `running` and
one that failed resolves to `error`. The resting pair is therefore never
knob-on + link-off — that combination is not a state this panel comes to rest in.

Only an intent to **start** projects. A stop keeps the polled state, so the link glyph
stays lit until a document confirms the proxy is really down, and *"no link glyph"*
keeps meaning *"nothing is established"*.

Deliberately **not** solved by polling faster during an action. That would make the
CLI's own `starting` observable, but it buys a truthful transient with a standing cost
on every action, and the transient it buys is the one the operator cares about least:
the resting state after the action is what carries the outcome.

The three properties that stay on polled truth, not `displayState`:
`CursorSurface.current` (reserved for `running`), `ToggleSwitch.checked`'s fallback
(only consulted when no intent is held, where the two are equal by construction), and
`errorDetail` (a retry renders `starting…`, but hovering still surfaces what the
previous attempt failed with).

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
| Action button input gate | `enabled: revealed` — opacity-0 items still take clicks, so the reveal needs both. **Not** `&& !tracker.busy`: `enabled: false` dims a `PanelActionButton`'s icon, and `groupBusy` is one of the two things that *reveals* this Row, so that gate dimmed the spinner for exactly as long as it spun. Busy is swallowed in the Panel's command functions instead — §5 |

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
| `checked` | the row's **intent** while one is held, else `state === "running" \|\| state === "starting"` — see §5 |
| `busy` | `tracker.busy` — panel-wide, not `busyKey`-scoped: Tracker runs one action at a time, so every switch is equally unclickable while any is in flight |
| `interactive` | **never bound.** It drives `cursorRing`, and so the control's implicit size — see the geometry rule below |
| `onToggled` | `root.toggleConnection(conn)` — **never `tracker.start`/`stop` directly.** The command function is what busy-guards the click, records the intent, *then* calls Tracker; calling Tracker from the switch skips the intent and so loses both the optimistic knob and the projected `starting` (§2) |

`canStart(state)` is `state === "stopped" || state === "error"`. The **UI** picks the
verb; `Tracker` deliberately has no `toggle()` (`docs/modules.md`).

Every mouse and keyboard verb goes through the Panel's command functions (§5) — they
are the single place the busy guard and the intent write live, so no control reaches
`Tracker` on its own.

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

Every command function in the Panel opens with `if (!tracker || tracker.busy) return`.
That is the enforcement point, and it sits *before* intent is recorded — a control
that let a click through would otherwise strand an intent on an action Tracker
silently dropped. Each control's own gate is then only a second line of defence,
and none of them has to dim to provide it.

| Control | Blocks clicks via | Visually silent when blocked? |
|---------|-------------------|-------------------------------|
| Row `ToggleSwitch` | `busy: tracker.busy` | Yes — `busy` gates only `onClicked` |
| Group start / stop | the command guard | Yes — `enabled` tracks the reveal alone, so the spinner stays at full brightness |
| `Stop all` | `enabled` | Yes — `Button` colours derive from `selected`/`foreground`, never `enabled` |

**Never `ToggleSwitch.interactive` for this.** It means "the surrounding row owns the
click", and `cursorRing` derives from it — see the geometry rule below.

### The three positive signals

1. **Intent, held until a document answers.** While an intent is outstanding, the
   switch *and* the state glyph (§2) both show what was **asked for**; both fall back
   to the polled document the moment one lands. Every command records its intent —
   `{ id: bool }`, set for one Connection, a Group's worth, or all of them — `checked`
   reads it when present, and `displayState` projects a *start* intent onto the glyph
   column (§2).

   The split is not switch-versus-glyph, it is during-versus-after. The glyph is where
   the **outcome** is legible, because it carries four states where the switch carries
   two: a start that failed resolves to alert-circle and its error code, where the
   knob can only fall back.

   **Do not key this to `busy`.** `busy` ends when the CLI process *exits*, but the
   fresh Status document does not arrive until `delayedRefresh` fires 500ms later. In
   that gap `checked` falls back to the stale state, so a single click renders as
   **On → Off → On**: three transitions for one action.

   The first document **observed after the action settled** carries the answer,
   whatever it says. It either confirms (knob stays, glyph goes live) or contradicts
   (knob slides back and the glyph resolves to `stopped` or `error` — the operator's
   signal that the start or stop did not take).

   **"Observed after" is a provenance test, not a timing one.** `tracker.busy` covers
   the action process alone, so a status poll started *before* an action can exit
   *after* it and land carrying pre-action truth — settling on that clears the intent
   against a document predating the very thing it is meant to confirm. Capture
   `tracker.actionEpoch` when the intent is written and settle only once
   `tracker.documentEpoch` exceeds it (`docs/modules.md`, "Document provenance").

   Self-healing survives that gate, by construction rather than by accident: Tracker
   advances `actionEpoch` when it **refuses** an action too, so a start its version
   gate rejected drops its intent on the next document instead of leaving the knob
   stuck.

   Reassign the intent map wholesale; mutating a `var` in place does not re-evaluate
   bindings that read it.
2. **Group spinner.** The acting Group's start button swaps to the spinner glyph and
   rotates. `busyKey` names the Group, not the verb, so there is nothing to attribute
   a separate spinner control to — and adding one would change the Row's extent.
3. **`starting`, projected immediately.** The acting Connection's glyph spins from the
   moment the intent is recorded, not once a poll confirms it: `start` blocks until the
   port opens, so the CLI's own `starting` is nearly unobservable from a panel action —
   see §2. This is the per-row signal; signal 2 is its Group-level counterpart.

### Geometry stability

Three of this kit's components change their **implicit size** when a state property
flips. Bind any of them to a transient state and the panel visibly jumps:

| Trap | Mechanism | Effect |
|------|-----------|--------|
| `ToggleSwitch.interactive` | `cursorRing: interactive`, `_pad: cursorRing ? cursorPad : 0`, `implicitWidth: trackWidth + _pad*2` | Switch shrinks `54×34` → `42×22` |
| `visible` on a reveal inside a `Row` | `Row` skips invisible children entirely | Row collapses: header height jumps, siblings anchored to its edge slide |
| `Button.iconText` `""` → glyph | Icon `Text` is `visible: iconText !== ""` inside a Row with `controlGap` | Button widens, moving `PanelHero.trailingInset` and reflowing the title |

A fourth trap in the same family, not geometric but the same shape of mistake —
a transient state leaving a permanent mark. `RotationAnimation on rotation` is a
**value source**: it takes the property over and keeps its last value when it stops,
so the `rotation: 0` binding it replaced is *not* restored. Every spinner therefore
needs `onRunningChanged: if (!running) <target>.rotation = 0`, or the glyph settles
at whatever angle the animation happened to end on. Both spinners here carry it.


> **Rule.** Never bind a geometry-affecting property to a transient state — busy,
> hover, or cursor. Reveal with **`opacity`** and gate input with **`enabled`**
> (opacity-0 items still take mouse input, so both are needed). `enabled` is safe on
> every control here *for geometry*: none of their implicit sizes depend on it.
>
> **But `enabled` is not colour-safe.** `PanelActionButton` paints its icon
> `Qt.darker(foreground, 2.0)` when disabled — its own header comment says
> *"`enabled` gates clicks and dims the icon."* So `enabled` may carry a reveal,
> which is already a visual change, but never a *transient* condition on a control
> that is visible at the time. Busy belongs in the command functions.

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
| `h` / `l` | Connection row | Explicit `stop` / `start` for that Connection |
| `Esc` | anywhere | Close |
| `Tab` | anywhere | `switchPanel(direction)` |

The keyboard needs one verb where the mouse has two buttons, hence `Enter`'s toggle
heuristic; `h`/`l` are the explicit asymmetric actions, and apply to whatever the
cursor is on — a Group header acts on the Group, a Connection row acts on that
Connection.

`h`/`l` on a row deliberately do **not** consult the current Health state the way
`Enter` does. Asking to start something already running is idempotent at the CLI, and
second-guessing it here would make the key silently do nothing on the row the operator
is pointing at.

(`audio/Panel.qml` makes `h`/`l` a no-op on its device rows, but that is not a
precedent to copy: there the keys move a *section-level* slider, so the thing acted on
would not be the thing highlighted. Here the cursor's target and the action's target
are the same row.)

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
- **The cursor is remembered across close/reopen.** Reopening re-activates the cursor
  where it was left — including a position reached by `j`/`k` without acting — so the
  common loop (open, toggle the Connection you care about, close, return later to
  toggle it back) costs one `Enter`. First open after a shell start keeps the house
  behaviour: no highlight until the keyboard or mouse arrives.

  **Keep exactly one copy of this state.** The cursor properties live on the Panel,
  and `BarWidget`'s `Loader` is `active: true` with no dynamic binding, so the object
  is constructed once and survives every open/close — verified by instrumenting
  `Component.onCompleted`, which fires once per shell start with no matching
  `onDestruction`. Reopening therefore only has to re-activate what is already there
  and re-clamp it. A separate "last position" pair updated on each *action* both
  duplicates the state and fails the requirement, because moving the cursor without
  acting leaves the copy pointing at the previous row.

  Session-scoped: no state file is involved, and this plugin owns none by design. A
  shell restart starts cold.

  **Positional, deliberately.** The cursor is `focusSection` + `selectedIndex`, so it
  restores to a *position*, not to a Connection `id`. Reordering `connections.json`
  therefore lands the cursor on whatever now occupies that index. Accepted: the config
  is hand-edited and settles after the first couple of passes, `clampCursor` guarantees
  the position is always in range so it can never point at nothing, and keying on `id`
  would mean carrying an identity that the flat row model does not otherwise need.
  Not a defect to fix — a trade-off already weighed.

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
3. `omarchy plugin validate` via `./scripts/dev-link`. Note that saved edits do
   **not** hot-reload through the symlink — run `omarchy restart shell` after each
   change, or you will be reviewing the previous build.
4. **`qmllint` — use the Qt 6 binary explicitly.** On Arch, `/usr/bin/qmllint` comes
   from `qt5-declarative` and silently reports *nothing* on Qt 6 QML: it exits 0 on a
   deliberate syntax error and on an unresolved type, so it reads as a clean pass.
   Use `/usr/lib/qt6/bin/qmllint` (check `--version` names a Qt 6 release), and give
   it the shell's modules under their real URIs — `qs.Ui` resolves as `qs/Ui`, so a
   symlink shim is needed:

   ```bash
   mkdir -p /tmp/qmlshim/qs
   ln -sfn /usr/share/omarchy/shell/Ui      /tmp/qmlshim/qs/Ui
   ln -sfn /usr/share/omarchy/shell/Commons /tmp/qmlshim/qs/Commons
   /usr/lib/qt6/bin/qmllint -I /tmp/qmlshim -I /usr/lib/qt6/qml Panel.qml
   ```

   Judge the result against the shipped panels rather than against zero: they produce
   71–198 warnings under the same command, essentially all `unqualified` (`root.*`
   from nested Components, which wants a `pragma ComponentBehavior: Bound` this
   codebase uses nowhere) and `missing-property` (`Style.font.*` / `Style.spacing.*`
   are anonymous `QtObject`s qmllint cannot introspect). What must stay at **zero** is
   `property-override`, `unresolved-type`, and `Could not find property`.
5. Live: all four `degraded.kind` bodies, the empty body, and all four Health states.
   `fixtures/` covers happy / empty / bad-version.
6. Keyboard: reach every control with `j`/`k`/`h`/`l`/`Enter` and confirm exactly one
   highlight is ever visible. This cannot be automated — `KeyboardPanel` takes a
   layer-shell keyboard grab that `wtype`'s virtual-keyboard protocol does not feed,
   so synthetic keys land in whatever window had focus instead.
7. Geometry: perform an action and confirm **nothing moves** — no row changes height,
   no control changes size, no label shifts sideways (§5 "Geometry stability").
