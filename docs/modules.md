# Module seams — v1

**Wayfinder:** [Grill plugin module seams with codebase-design](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/5)  
**Language:** [`CONTEXT.md`](../CONTEXT.md)  
**Patterns research:** [`docs/research/omarchy-bar-widget-patterns.md`](./research/omarchy-bar-widget-patterns.md)

Deep-module layout for implement tickets. Chrome (how it looks) is separate — see prototype / design lock tickets.

## Pick

| Choice | Value |
|--------|--------|
| Host shape | **Nested** scaffold: `BarWidget.qml` loads `Panel.qml` (`Loader { active: true }`). |
| Deep module | **Tracker** (`Tracker.qml`) — poll, version gate, **doctor-on-open**, start/stop, last Status view. |
| Pure internal seam | **`Model.js`** — parse/validate Status JSON only. |
| UI | Bar and Panel **bind and call** Tracker only. No `Process` in UI files. |
| Shell `kind: "service"` | **No** for v1. |
| Multi-monitor poll sharing | **Yes** (issue #54) — one shared Tracker instance for every bar widget, not one per monitor. |

**Why:** One deep interface keeps CLI I/O local; nested scaffold already matches weather/clock and this repo; host-level service is overkill and uncertain for third-party plugins. Multi-monitor sharing: the bar exists once per monitor (`Bar.qml`'s `Variants { model: Quickshell.screens }`), so a per-widget Tracker polled the same question once per monitor — three monitors meant 36 subprocess launches a minute for one answer.

**Discarded:** Combined `barWidget` → single Panel entry (churn, no extra depth); fat Panel/Bar with inline Process; two *external* modules (Cli + Model) that every caller must compose; `execDetached` for start/stop; continuous doctor poll; a leader-election scheme across per-widget Trackers instead of one shared instance (issue #54 — trades a measurable cost for a race condition).

**Unchanged:** CLI-only contract (`--version`, `status --json`, `start`/`stop`, and `doctor --json` as **panel-open preflight only** — not on the status poll timer); no reads of `connections.json`; manifest settings keys.

## Files

```
qml/BarWidget.qml   thin: button, open/close/toggle, injectPanel, bind count / degraded
qml/Panel.qml       stateful chrome Adapter: render, cursor, intent, displayState;
                    calls Tracker only
qml/Tracker.qml     deep module — singleton shared by every bar (issue #54)
qml/Model.js        pure parse/map (used by Tracker; not by UI)
qml/qmldir          declares Tracker a singleton for this directory (issue #54)
manifest.json       kinds: ["bar-widget"]; entryPoints.barWidget = qml/BarWidget.qml
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
                         Tracker  ← ONE shared instance (qml/qmldir singleton, issue #54)
                          ▲   ▲
                          │   │  registerViewer / unregisterViewer / notifyViewerChanged
                          │   │  (panelOpen, barVisible — "true when ANY bar says true")
              ┌───────────┘   └───────────┐
        BarWidget (screen 1)        BarWidget (screen 2)   …
        ├── WidgetButton            ├── WidgetButton       ← each binds Tracker view props
        └── Loader → Panel          └── Loader → Panel     ← panel.tracker = root.tracker (via injectPanel)
```

Every `BarWidget` instance — one per monitor — has its own `WidgetButton` and its own
`Loader → Panel`; only `Tracker` itself is shared.

`injectPanel` sets at least: `bar`, `anchorItem`, `hostWidget`, `settings`, `tracker`.
`tracker` is the shared singleton on every widget instance — `root.tracker`
resolves to the bare `Tracker` identifier, not a locally-owned object.

## Tracker interface

Callers (Bar, Panel, later tests against a fake) learn only this surface.
Since issue #54, Tracker is **one shared instance** for every bar widget
(one bar per monitor) — see "Sharing" below for how `settings`,
`panelOpen`, and `barVisible` work with more than one caller.

### Config in

| Input | Meaning |
|-------|---------|
| Settings from manifest | `cliPath`, `minCliVersion`, `refreshIntervalSec`, `refreshIntervalOpenSec` |
| `panelOpen` | `bool`, read-only to callers — select open vs closed poll interval. `true` when **any** registered bar widget's panel is open (issue #54). |
| `barVisible` | `bool`, read-only to callers — gate on shell `barHidden` (#52). `true` when **any** registered bar widget is visible, or when none has registered yet (issue #54; same fail-open default #52 used for one bar). The poll timer itself stops launching new polls only when this is `false` **and** `panelOpen` is also `false` — an open panel keeps its 2s cadence even behind a hidden bar. |

### Sharing (issue #54)

Tracker is a singleton (`qml/qmldir`): every bar widget instance references
the bare `Tracker` identifier, never `Tracker { ... }`. Three inputs used to
come from one widget instance; each has a rule now that many widgets share
one Tracker.

| Input | Rule with N bar widgets |
|-------|--------------------------|
| `settings` | Same object for every instance — `allowMultiple: false` means one widget per bar, and every bar reads the same plugin config. Each widget assigns `Tracker.settings` on change; no conflict since the values agree. |
| `panelOpen` | `true` when **any** registered widget's panel is open — the faster cadence follows whichever monitor's panel is actually open. |
| `barVisible` | `true` when **any** registered widget is visible. |

Each `BarWidget` calls `Tracker.registerViewer(root)` once (`Component.onCompleted`,
`root` being that widget's own id), `Tracker.unregisterViewer(root)` on destruction,
and `Tracker.notifyViewerChanged(root)` whenever its own `opened` or `barVisible`
changes. Tracker re-scans the registered widgets' own current state on every call
rather than accumulating a delta, so a missed or reordered *notify* call cannot leave
the aggregate stuck. This does not cover a missed *unregister*: a widget destroyed
without its teardown signal firing stays counted (issue #54 review).

An empty registry means two different things depending on when it happens: before
the first widget has ever registered (startup ordering), `barVisible` fails open —
same rule #52 used for one widget. After every widget has registered and then gone
(plugin disabled on rescan, every screen unplugged), it fails **closed** instead —
`_everRegistered` is the one-way latch that tells the two cases apart. Without it, an
orphaned singleton with a `panelOpen`/`barVisible` binding but no reader would poll
the CLI forever.

`busy`, `busyKey`, and `actionErrors` are shared for free: starting a Connection
from the panel on one monitor shows the busy state and any row error on every
other monitor, since every Panel now reads the same Tracker object.

**`runDoctor()` needed a new guard, not just the existing ones.** `doctorProc.running`
and the `_settingsGeneration` / `_doctorProcGeneration` staleness checks already
stopped a second *concurrent* launch and discarded a *stale* result — but neither
stops a *settled* result from being redone. With one Tracker and only one caller, a
reopened panel re-running an already-answered doctor check was merely wasteful. With
more than one caller, `degraded` is shared, so a second panel's `runDoctor()` after
doctor already settled flips every *other* already-open panel's view to "Checking
setup…" and relaunches doctor for a question this generation already answered.
`runDoctor()` now returns immediately once `_doctorOk !== null` for the current
settings generation; the same guard was added to the version-reprobe path
(`versionProc.onExited`) that could otherwise re-trigger doctor on a transient
version-gate blip.

**Pick:** suppress a re-run on any settled result, pass or fail. **Why:** a failed
doctor is as much an answer for this generation as a healthy one — suppressing only
the pass case would still redo the run (and still re-flip every other panel) on every
reopen for as long as the environment stays broken. **Discarded:** auto-retry a failed
doctor on reopen — the existing way to ask for a recheck is a settings change
(`onSettingsChanged` resets `_doctorOk` to `null` on any write, including a
no-op-value save), and that stays the only trigger. **Unchanged:** a genuinely new
settings generation still gets a fresh doctor run on the next open, exactly as before
#54.

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
| Hyphen-leading id/Group target (#49) | **no process launched** | `actionErrors[id]` — plugin-side refusal, no exit code |

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
| `registerViewer(instance)` / `unregisterViewer(instance)` | Bar widget joins/leaves the `panelOpen` / `barVisible` aggregate (issue #54) |
| `notifyViewerChanged(instance)` | Bar widget's own `opened` or `barVisible` changed — recompute the aggregate |

**Action target:** `{ kind: "id" | "group" | "all", id?: string, group?: string }`  
Tracker maps that to argv. UI does **not** build argv strings.

**No `toggle()` on Tracker.** UI reads Health state and calls `start` or `stop`.

### Not on the interface

Raw stdout/stderr buffers, `Process` objects, semver internals, logs/restart UIs, config file paths. Doctor is invoked only via `runDoctor()` (not continuous).

## Model.js (internal)

Pure functions only (no QML imports, no Process):

- `parseStatusDocument(text) → { ok, degraded?, running, error, total, groups, connections, cliVersion, … }`
- Require Status document `version === 1`; ignore unknown fields (additive-safe consumer)
- Fail closed on shape (issue #47). Require `connections` to be an array and `groups` to be an object. Reject a Connection whose id/name/group/state/port/address/enabled/error field breaks type or range. Types and ranges come from `status-document.v1.md`, plus `config.v1.md` for the id charset and the non-empty group/address rule. A malformed document degrades (`kind: "schema"`) instead of showing an empty or defaulted view as healthy.
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
- Timer tick arms a one-shot retry flag if `statusProc.running`, consumed once the process stops (#45)
- Poll interval from settings; faster when `panelOpen`; timer stops launching new polls only when `barVisible` is `false` and `panelOpen` is also `false`
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
