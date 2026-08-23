# Design — cloud-sql-tracker-oma-plugin

Omarchy bar widget for [cloud-sql-tracker](https://github.com/golgor/cloud-sql-tracker).

## Seam

The plugin talks **only** to the CLI, through the **Tracker** module (not from Bar/Panel directly):

```
BarWidget / Panel  →  Tracker  →  Process(["cloud-sql-tracker", ...])  →  stdout JSON
```

Module layout and Tracker interface: [`docs/modules.md`](./modules.md). Domain words: [`CONTEXT.md`](../CONTEXT.md).

No reads/writes of `~/.config/cloud-sql-tracker/connections.json`. Config stays owned by the CLI (hand-edited v1; `config` subcommands later).

## Plugin id

`io.github.golgor.cloud-sql-tracker`

## UX — locked v1 chrome

Frozen after prototypes ([issue #3](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/3), throwaway [PR #8](https://github.com/golgor/cloud-sql-tracker-oma-plugin/pull/8)) and chrome grill ([issue #6](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/6)).

**Layout name:** **Grouped list** (prototype variant **A**).

Visual and interaction detail — tokens, glyphs, measurements, keyboard map, copy —
lives in [`docs/chrome.md`](./chrome.md). This section stays the **decision**
record: what is locked, what is out, and why. `chrome.md` is **normative for how it
looks and behaves**. If the two disagree, one of them is a bug.

### Bar

- Icon + **running count** (`Tracker.runningCount`)
- **Warning affordance** when `errorCount > 0` **or** Tracker is **Degraded**
- Tooltip: short summary (e.g. running/total among **enabled** Connections, or degraded message)
- Left click toggles the panel
- Icon glyph comes from the **Nerd Font MDI range** — the family `fc-match
  monospace` resolves to. Plain Unicode symbols (e.g. `☁` `U+2601`) fall back to an
  unrelated font: different metrics from the count rendered beside them, and tofu
  wherever that fallback font is absent.

### Panel — Grouped list

Single scrollable column (not two-pane in v1):

1. Optional header: title + global **Stop all** (when not degraded and `total > 0`)
2. For each **Group** (stable order from Status document / config order of first appearance):
   - **Group header row:** group name, small counts, **Start group** / **Stop group**
   - **Connection rows** under that group:
     - Display **name** (not id as primary label)
     - **Health state** color/affordance: `stopped` | `starting` | `running` | `error`
     - One **toggle** control: start if `stopped` or `error`; stop if `running` or `starting`
     - UI calls `Tracker.start` / `Tracker.stop` with Action target `{ kind: "id", id }` — no `toggle()` on Tracker
3. Busy: disable or spinner on the row / group whose action is in flight (`busy` / `busyKey`); do not block the whole panel harder than necessary

#### Amendments — chrome pass

The list above predates the chrome pass. These six points supersede it:

- **Panel size is `Style.space(380) × Style.space(560)`** — the shell's default for
  list panels (7 of 10 native panels use 380). The original `340 × 420` was narrower
  *and* shorter than every native panel, with no reason recorded.
- **Group actions are icon buttons** (`PanelActionButton`), revealed on hover or
  keyboard cursor — not always-visible text buttons. Two `Start group` / `Stop group`
  text buttons cost ~190px of a 380px panel, repeated once per Group.
- **Group counts sit on the group header line**, right-aligned, not on a second line.
- **`Stop all` stays one-way.** Native panels put a symmetric on/off switch in the
  header, but "start every Connection" means N proxy processes and N GCP auth
  handshakes from one click. The asymmetry is a safety property, not an oversight.
- **Busy blocks every control's clicks, but dims nothing.** Point 3 above said "do not
  block the whole panel harder than necessary"; in practice Tracker runs one action at
  a time and ignores a concurrent one silently, so leaving other controls live means
  dead clicks. Blocking them all is therefore right — but *dimming* them all is not:
  an action is a sub-second CLI round trip, so it reads as the whole panel flashing on
  every toggle. Feedback comes instead from the switch showing **intent** (it slides on
  click and holds until a Status document confirms or denies it), a spinner on the
  acting Group, and the acting row rendering `starting` from the moment the intent is
  recorded — not once a poll lands, because `start` blocks until the port opens, which
  leaves the CLI's own `starting` nearly unobservable. Detail:
  [`chrome.md`](./chrome.md) §5.
- **The cursor survives close/reopen.** Reopening re-activates it where it was left, so
  toggling the same Connection again costs one `Enter`. Session-scoped only: the
  cursor lives in the Panel object, and this plugin still writes **no** state to disk.

### Connection row detail (inline, not a second pane)

Show on the row or a single-line subtitle:

- **Show:** name, group (via section), Health state **or** `disabled`, **port**, **address**
- **When `enabled: false`:** still listed; status line `disabled · address:port`; no start intent; toggle inert. Group/bar counts use **enabled-only** denominators (issue #26). Missing Status field → treat as enabled.
- **When `error`:** error **code** on the row; the full `detail` string goes in a
  `PanelToolTip`, rather than wrapping the row to three lines and breaking the
  uniform row height
- **Do not show in v1 UI:** full Cloud SQL `instance` string, systemd `unit`, `pid`, `uptime` (may appear later in tooltip or Expanded view)

### Keyboard

Every native Omarchy panel is fully drivable without a mouse, and the shell's own
gallery (`plugins/dev-gallery/GalleryPanel.qml`) names
`plugins/panels/audio/Panel.qml` as the recipe plugin authors should copy. Locked:

| Key | Target | Action |
|-----|--------|--------|
| `j` / `k` | anywhere | Walk Connection rows, crossing Group boundaries |
| `Enter` | Connection row | Toggle that Connection — same verb rule as the mouse |
| `Enter` | Group header | Toggle the Group: `stop` if `running + starting > 0`, else `start` |
| `Enter` | Panel header | Stop all |
| `h` / `l` | Group header | Explicit `stop` / `start` for that Group |
| `h` / `l` | Connection row | Explicit `stop` / `start` for that Connection |
| `Esc` | anywhere | Close |
| `Tab` | anywhere | Switch to the sibling panel |

**One cursor for mouse and keyboard.** Hover writes the same `focusSection` /
`selectedIndex` / `cursorActive` state the keys do, so there is never a second
competing highlight.

### Degraded and empty (full panel body)

Not the same as Connection Health `error`. When `Tracker.degraded !== null`, replace the switchboard with a clear message:

| `degraded.kind` | Operator intent |
|-----------------|-----------------|
| `cli_missing` | Install CLI or set `cliPath` |
| `cli_old` | Upgrade CLI / adjust `minCliVersion` |
| `schema` | Status document `version` ≠ 1 — upgrade plugin or CLI together |
| `status_failed` | Status command failed — message/stderr hint (includes **invalid config JSON** / config load errors: CLI exits 2 on `status --json`) |
| `doctor_failed` | `doctor --json` hard-fail (`ok: false`) — setup untrustworthy (e.g. missing `proxy_bin`). Full body; **no connection list** |

When not degraded but **no Connections are published** in the Status document: empty copy — configure Connections via CLI-owned `connections.json` (path as text only; **do not** open or parse the file in-plugin). (UI progress counts are enabled-only; emptiness uses published row count so an all-disabled config still lists rows.)

**Doctor-on-open.** Opening the panel runs `cloud-sql-tracker doctor --json` once (not a continuous poll). Hard fail → `doctor_failed` Degraded. Status poll stays 5s closed / 2s open.

**Action failures are not Degraded.** After doctor has passed, a failed start/stop is **row-scoped** (`Tracker.actionErrors[id]`): error glyph/status line + hover detail. No panel-wide banner. Intent still settles so the knob does not stick On. (Issue #31.)

### Explicit non-goals (v1 chrome)

- Two-pane **Expanded view** (prototype **C**) — deferred product option, not v1
- Dense chips (prototype **B**) — not chosen
- Multi-tab shell (Status | Help | …) — deferred UI improvement; no config-file tab
- In-panel `restart` / interactive `doctor` tab / `logs` (doctor **preflight on open** is in scope — full-body Degraded only)
- Editing or viewing file contents of `connections.json`

### Prototype scenario controls (Happy / CLI missing / Empty)

Those labels in the HTML prototype were **fixture switchers** for review only, not product tabs. They map to: normal Status document / degraded CLI path / empty Status — not to Health states on rows.

## Dependency

- `cloud-sql-tracker` on `PATH` (or `cliPath` setting)
- Minimum version via `minCliVersion` setting + `cloud-sql-tracker --version`
- Status document includes `"version": 1` (schema version); bump is a coordinated change

## Deferred UX (not this map’s close bar)

Recorded so implementers do not invent them mid-slice; track as ordinary issues outside the v1 dogfood destination if desired:

1. **Expanded view** — two-pane layout (prototype **C**): groups (or list) left, connection inspector right; richer detail fields optional.
2. **Multi-tab shell** — e.g. Status | Help (paths, copy-paste doctor commands). Must **not** read `connections.json`.

## Build slices (this repo)

Order is indicative once install + Tracker exist; adjust on the map as tickets land:

1. Stub validate + install / dev-link docs
2. Tracker + Model.js: status poll, version gate, degraded
3. Bar: count + warning affordance
4. Panel: Grouped list + per-row toggle + group start/stop + stop all
5. Empty / degraded copy polish
6. Dogfood + remaining docs (`AGENTS.md`, how-it-works) — docs: [`AGENTS.md`](../AGENTS.md), [`docs/how-it-works.md`](./how-it-works.md)
7. Chrome pass: house-style Panel (`PanelHero`, `CursorSurface` rows, `ToggleSwitch`,
   keyboard cursor), health-state glyph system, `380 × 560` — spec in
   [`docs/chrome.md`](./chrome.md), verified with
   [`docs/prototypes/theme-sweep`](./prototypes/theme-sweep/)

CLI work stays in the sibling repo.
