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

### Bar

- Icon + **running count** (`Tracker.runningCount`)
- **Warning affordance** when `errorCount > 0` **or** Tracker is **Degraded**
- Tooltip: short summary (e.g. running/total, or degraded message)
- Left click toggles the panel

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

### Connection row detail (inline, not a second pane)

Show on the row or a single-line subtitle:

- **Show:** name, group (via section), Health state, **port**, **address**
- **When `error`:** error code and/or short message from Status `error`
- **Do not show in v1 UI:** full Cloud SQL `instance` string, systemd `unit`, `pid`, `uptime` (may appear later in tooltip or Expanded view)

### Degraded and empty (full panel body)

Not the same as Connection Health `error`. When `Tracker.degraded !== null`, replace the switchboard with a clear message:

| `degraded.kind` | Operator intent |
|-----------------|-----------------|
| `cli_missing` | Install CLI or set `cliPath` |
| `cli_old` | Upgrade CLI / adjust `minCliVersion` |
| `schema` | Status document `version` ≠ 1 — upgrade plugin or CLI together |
| `status_failed` | Status command failed — message/stderr hint |

When not degraded but `total === 0`: empty copy — configure Connections via CLI-owned `connections.json` (path as text only; **do not** open or parse the file in-plugin).

### Explicit non-goals (v1 chrome)

- Two-pane **Expanded view** (prototype **C**) — deferred product option, not v1
- Dense chips (prototype **B**) — not chosen
- Multi-tab shell (Status | Help | …) — deferred UI improvement; no config-file tab
- In-panel `restart` / `doctor` / `logs`
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
6. Dogfood + remaining docs (`AGENTS.md`, how-it-works)

CLI work stays in the sibling repo.
