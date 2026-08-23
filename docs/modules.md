# Module seams — v1

**Wayfinder:** [Grill plugin module seams with codebase-design](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/5)  
**Language:** [`CONTEXT.md`](../CONTEXT.md)  
**Patterns research:** [`docs/research/omarchy-bar-widget-patterns.md`](./research/omarchy-bar-widget-patterns.md)

Deep-module layout for implement tickets. Chrome (how it looks) is separate — see prototype / design lock tickets.

## Pick

| Choice | Value |
|--------|--------|
| Host shape | **Nested** scaffold: `BarWidget.qml` loads `Panel.qml` (`Loader { active: true }`). |
| Deep module | **Tracker** (`Tracker.qml`) — poll, version gate, start/stop, last Status view. |
| Pure internal seam | **`Model.js`** — parse/validate Status JSON only. |
| UI | Bar and Panel **bind and call** Tracker only. No `Process` in UI files. |
| Shell `kind: "service"` | **No** for v1. |
| Multi-monitor poll sharing | **No** for v1 — each widget instance may poll. |

**Why:** One deep interface keeps CLI I/O local; nested scaffold already matches weather/clock and this repo; host-level service is overkill and uncertain for third-party plugins.

**Discarded:** Combined `barWidget` → single Panel entry (churn, no extra depth); fat Panel/Bar with inline Process; two *external* modules (Cli + Model) that every caller must compose; `execDetached` for start/stop.

**Unchanged:** CLI-only contract (`--version`, `status --json`, `start`/`stop`); no reads of `connections.json`; manifest settings keys.

## Files

```
BarWidget.qml   thin: button, open/close/toggle, injectPanel, bind count / degraded
Panel.qml       stateful chrome Adapter: render, cursor, intent, displayState;
                calls Tracker only
Tracker.qml     deep module (child of BarWidget)
Model.js        pure parse/map (used by Tracker; not by UI)
manifest.json   kinds: ["bar-widget"]; entryPoints.barWidget = BarWidget.qml
```

**Panel is thin in the dimension that matters and not in the one it does not.**
It holds no CLI knowledge — no `Process`, no argv, no `Model.js` import, no reads
of `connections.json` — and that is the seam this document exists to protect. It
does hold real UI state: the flat row model, the shared mouse/keyboard cursor and
its repair, the optimistic intent map, and the `displayState` projection. The
original "thin: render groups and rows" wording predates all four and would send
a future change looking for a layer that was never removed.

Those clusters are pure functions over their inputs, so they could move to an
internal UI-state module and become testable outside Quickshell — the deletion
test says they would be genuinely missed, unlike the visual mapping helpers. That
is a **follow-up**, not a debt to pay here, and it would be a second *internal*
seam, never a second external one. `Model.js` is not the destination: its
interface is Status parsing only.

### Wiring

```
BarWidget
├── Tracker              ← one per widget instance
├── WidgetButton         ← binds Tracker view props
└── Loader → Panel       ← panel.tracker = root.tracker (via injectPanel)
```

`injectPanel` sets at least: `bar`, `anchorItem`, `hostWidget`, `settings`, `tracker`.

## Tracker interface

Callers (Bar, Panel, later tests against a fake) learn only this surface.

### Config in

| Input | Meaning |
|-------|---------|
| Settings from manifest | `cliPath`, `minCliVersion`, `refreshIntervalSec`, `refreshIntervalOpenSec` |
| `panelOpen` | `bool` — select open vs closed poll interval |

### View out

| Prop | Meaning |
|------|---------|
| `runningCount`, `errorCount`, `total` | Aggregates for the bar (from last good Status document, or zeros when degraded with no document) |
| `groups` | Group summaries for the panel |
| `connections` | Connection rows for the panel |
| `degraded` | `null` when usable; else `{ kind, message }` |
| `busy` / `busyKey` | Action in flight (optional key for row spinners) |
| `actionErrors` | Map `id → { message, verb, exitCode }` for failed start/stop on that Connection. Cleared for the action's target scope on success. Not Degraded — Status may still be healthy (issue #31). |
| `actionEpoch` / `documentEpoch` | Document provenance — see below |
| `loaded` | At least one status or version attempt finished |

**`degraded.kind` (v1):** `cli_missing` | `cli_old` | `schema` | `status_failed` | `doctor_failed`

When `degraded !== null`, UI must not present a healthy empty switchboard as success.

**Config vs action failures**

| Situation | CLI | Tracker |
|-----------|-----|---------|
| Invalid / unloadable `connections.json` | `status --json` exit **2**, stderr message | `degraded.kind === "status_failed"`, message from stderr |
| Bad `proxy_bin` / doctor hard-fail | `doctor --json` `ok: false` | `degraded.kind === "doctor_failed"` — **no connection list** |
| Start fails after doctor passed (per Connection) | `start` non-zero | `actionErrors[id]` — row paints error; no global banner |
| Single-id start refused (disabled, …) | exit **2** | `actionErrors[id]` (and no sticky start intent once settled) |

#### Document provenance

`busy` answers *"is an action running?"*. A UI holding optimistic state needs a
different question — *"was this document observed after my action finished?"* — and
`busy` cannot answer it, because it covers `actionProc` alone. A status poll started
before an action can exit after it, carrying pre-action truth.

| Prop | Meaning |
|------|---------|
| `actionEpoch` | Count of actions whose outcome is settled. Advanced when an action exits, **and when one is refused**, so optimistic state held for an action that never ran is still released. |
| `documentEpoch` | The `actionEpoch` current when the poll producing the last applied document was *launched*. Only a successful Status document advances it — a failed poll says nothing about the world. |

**Rule for callers.** Capture `actionEpoch` when you act; treat a document as
authoritative for that action only once `documentEpoch` exceeds the captured value.
`Panel` does exactly this with its intent map.

Tracker also **retries** a poll it could not start because one was in flight, rather
than dropping it. `start`/`stop` schedule the only guaranteed post-action read, and
silently losing it left callers on pre-action truth until the next tick.

### Commands

| Command | Meaning |
|---------|---------|
| `refresh()` | Run status poll now (and version gate when needed) |
| `runDoctor()` | One-shot `doctor --json` (panel open). Not on the status poll timer. |
| `start(target)` | `cloud-sql-tracker start …` then refresh |
| `stop(target)` | `cloud-sql-tracker stop …` then refresh |
| `clearActionError(id?)` | Drop one id or all `actionErrors` |

**Action target:** `{ kind: "id" | "group" | "all", id?: string, group?: string }`  
Tracker maps that to argv. UI does **not** build argv strings.

**No `toggle()` on Tracker.** UI reads Health state and calls `start` or `stop`.

### Not on the interface

Raw stdout/stderr buffers, `Process` objects, semver internals, logs/restart UIs, config file paths. Doctor is invoked only via `runDoctor()` (not continuous).

## Model.js (internal)

Pure functions only (no QML imports, no Process):

- `parseStatusDocument(text) → { ok, degraded?, running, error, total, groups, connections, cliVersion, … }`
- Require Status document `version === 1`; ignore unknown fields (additive-safe consumer)
- Parse `connections[].enabled` (missing → `true`). Recompute **enabled-only** `running`/`error`/`total` and per-group counters for the bar/panel; disabled rows remain in `connections` (issue #26)
- Optional helpers (e.g. semver compare) stay pure if extracted

Golden fixture: sibling CLI `examples/status.v1.json` (copy or path in tests later).

## Process layout (inside Tracker only)

| Process | Role |
|---------|------|
| `statusProc` | `status --json` |
| `versionProc` | `--version` (min CLI gate) |
| `doctorProc` | `doctor --json` (panel open only) |
| `actionProc` | One start/stop at a time (queue or ignore if busy) |

- Tracked `Quickshell.Io.Process` + `StdioCollector` (`waitForEnd`); not `execDetached` for these
- Timer tick no-ops if `statusProc.running`
- Poll interval from settings; faster when `panelOpen`
- After action exits, call `refresh()` (short delay allowed)

## Depth

```
     BarWidget / Panel
            │
            │  Tracker interface (table above)
            ▼
┌───────────────────────────┐
│         Tracker           │
│  timers, gate, Processes  │
│  busy, degraded, refresh  │
│            │              │
│            │ internal     │
│            ▼              │
│         Model.js          │
└───────────────────────────┘
            │
            ▼
    cloud-sql-tracker CLI
```

## Implement checklist

- [x] Add `Tracker.qml` + `Model.js`; keep Bar/Panel free of Process
- [x] Wire `tracker` through `injectPanel`; bar binds counts/degraded
- [x] Panel lists `groups` / `connections`; start/stop via Action target
- [x] Degraded empty-states for each `degraded.kind`
- [x] Node/fixture smoke: `scripts/check-model.js`
- [ ] Optional later: broader automated UI tests (not required for v1 dogfood)

Cold-start narrative: [`how-it-works.md`](./how-it-works.md). Agent workflow: [`../AGENTS.md`](../AGENTS.md).
