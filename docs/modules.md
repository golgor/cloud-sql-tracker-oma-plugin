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
Panel.qml       thin: render groups and rows; call start/stop
Tracker.qml     deep module (child of BarWidget)
Model.js        pure parse/map (used by Tracker; not by UI)
manifest.json   kinds: ["bar-widget"]; entryPoints.barWidget = BarWidget.qml
```

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
| `loaded` | At least one status or version attempt finished |

**`degraded.kind` (v1):** `cli_missing` | `cli_old` | `schema` | `status_failed`

When `degraded !== null`, UI must not present a healthy empty switchboard as success.

### Commands

| Command | Meaning |
|---------|---------|
| `refresh()` | Run status poll now (and version gate when needed) |
| `start(target)` | `cloud-sql-tracker start …` then refresh |
| `stop(target)` | `cloud-sql-tracker stop …` then refresh |

**Action target:** `{ kind: "id" | "group" | "all", id?: string, group?: string }`  
Tracker maps that to argv. UI does **not** build argv strings.

**No `toggle()` on Tracker.** UI reads Health state and calls `start` or `stop`.

### Not on the interface

Raw stdout/stderr buffers, `Process` objects, semver internals, doctor/logs/restart, config file paths.

## Model.js (internal)

Pure functions only (no QML imports, no Process):

- `parseStatusDocument(text) → { ok, degraded?, running, error, total, groups, connections, cliVersion, … }`
- Require Status document `version === 1`; ignore unknown fields (additive-safe consumer)
- Optional helpers (e.g. semver compare) stay pure if extracted

Golden fixture: sibling CLI `examples/status.v1.json` (copy or path in tests later).

## Process layout (inside Tracker only)

| Process | Role |
|---------|------|
| `statusProc` | `status --json` |
| `versionProc` | `--version` (min CLI gate) |
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

## Implement checklist (for later tickets)

- [ ] Add `Tracker.qml` + `Model.js`; keep Bar/Panel free of Process
- [ ] Wire `tracker` through `injectPanel`; bar binds counts/degraded
- [ ] Panel lists `groups` / `connections`; start/stop via Action target
- [ ] Degraded empty-states for each `degraded.kind`
- [ ] Optional later: Node/fixture tests calling `Model.js` only
