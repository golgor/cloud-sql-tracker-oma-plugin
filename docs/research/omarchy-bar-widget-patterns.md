# Research: Omarchy / Quickshell patterns for CLI-backed bar widgets

**Ticket:** [#2](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/2)  
**Scope:** Primary-source patterns only (local Omarchy install + official Quickshell docs + sibling CLI status contract as consumer context).  
**Out of scope:** Final module layout; product implementation.

**Local Omarchy tree examined:** `/usr/share/omarchy/shell/` and `/usr/share/omarchy/bin/omarchy-plugin-*`  
**Scaffold under study:** `manifest.json`, `BarWidget.qml`, `Panel.qml` in this repo  
**CLI consumer contract (do not redesign):** [`cloud-sql-tracker` status document v1](https://github.com/golgor/cloud-sql-tracker/blob/main/docs/status-document.v1.md) (`status --json`)

---

## Summary

Omarchy hosts everything in one long-lived Quickshell process (`omarchy-shell`). Third-party bar plugins are directories under `~/.config/omarchy/plugins/<id>/` with `manifest.json`; the shell discovers them via a bash scan and validates relative entry points. CLI-backed first-party widgets almost always shell out with `Quickshell.Io.Process` + `StdioCollector` (`waitForEnd: true`), guard with `if (!proc.running)`, parse JSON in pure `Model.js` helpers, and share bar/panel state by nesting the panel under the bar-widget entry (or a sibling `Service.qml` / `Main.qml` item)—not a separate `kind: "service"` unless the work must outlive the bar slot. `omarchy plugin validate` **rejects any symlink inside the plugin folder**; top-level install paths may be symlinks for remove/dev workflows, but validate of a linked checkout still fails if the tree contains links.

---

## Findings

### 1. Process I/O

1. **`Process` is the first-party CLI primitive** — Official Quickshell documents `import Quickshell.Io` `Process` with `command: list<string>` (no shell; each argv is its own string), `running` (true starts, false sends SIGTERM), `stdout`/`stderr` parsers, `onExited(exitCode, exitStatus)`, `exec()`, and `startDetached()` / `Quickshell.execDetached` for fire-and-forget. Changing `command`/`environment` while running applies to the *next* start. [Quickshell.Io Process (v0.2.0)](https://quickshell.org/docs/v0.2.0/types/Quickshell.Io/Process/)

2. **JSON / full-output commands use `StdioCollector` with `waitForEnd: true`** — Collector buffers until EOF, then exposes `text` and fires `onStreamFinished`. Default `waitForEnd` is true. Pattern in weather: parse in `onStreamFinished`, keep last-good data on empty/parse failure, optional retry timer. [StdioCollector](https://quickshell.org/docs/v0.2.0/types/Quickshell.Io/StdioCollector/); `/usr/share/omarchy/shell/plugins/panels/weather/Panel.qml` (`forecastProc`, `dailyForecastProc`).

3. **Streaming / login-style output uses `SplitParser`** — Tailscale login accumulates chunks and scrapes auth URLs as they arrive (`stdout: SplitParser { onRead: ... }`), while status JSON still uses collectors. `/usr/share/omarchy/shell/plugins/panels/tailscale/Service.qml` (`loginProcess` vs `statusProcess`).

4. **Avoid overlapping runs with explicit `running` guards** — Ubiquitous pattern:
   - `if (!forecastProc.running) forecastProc.running = true` (weather refresh).
   - `if (dailyForecastProc.running) return` before assigning `command` and starting (weather daily).
   - Tailscale: skip launch if the dedicated process is already running; `busy` is OR of all process `.running` flags.
   - Agents: if `updateProcess.running`, queue a single pending kind (`pendingUpdateKind`) instead of stacking processes; forced refresh outranks cheaper kinds.
   - Network: `if (!detailsProc.running) detailsProc.running = true`; action runner serializes UI with `actionKind !== ""`.

5. **Exit codes and stderr are first-class** — Tailscale status binds both collectors and decides in `onExited`: exit 0 → `parseStatus(stdout)`; else `resetUnavailable` + `lastError = stderr`. Actions clear optimistic state on failure and schedule a delayed refresh. Weather often ignores exit code and only inspects stdout emptiness/parse errors (curl `-f` already fails the body). Prefer Tailscale-style for a control-plane CLI.

6. **Detached vs tracked** — Side effects that must not die with reload/panel use `Quickshell.execDetached([...])` (clipboard, browser, `omarchy-tailscale-send`, menu actions). Tracked `Process` is for poll/parse and in-panel actions where UI needs exit feedback. Process docs: child is killed when Quickshell dies unless detached. [Process](https://quickshell.org/docs/v0.2.0/types/Quickshell.Io/Process/)

7. **Watchdogs and ramps for hung CLI** — Tailscale arms a 15s `pollWatchdog` that sets `statusProcess.running = false` (SIGTERM) if a poll never exits, because a hung process would permanently skip future ticks that guard on `!running`. Startup ramp polls every 2s until connected or ~30s. Agents retry limits-only when records set `retryAdvised`. Network uses `actionTimeout` so rows do not stick on “Connecting…”.

8. **Geocode / sequential queue pattern** — Weather geocode: one process; if query changed while in flight, `onStreamFinished` schedules `startGeocode` again for the pending query (latest-wins queue of depth 1).

9. **Stdin is rare** — Network enterprise connect sets `stdinEnabled: true`, writes secret in `onStarted`, clears it (never on argv). Not needed for `cloud-sql-tracker` v1.

10. **Shell-out shape for this plugin’s CLI** — Sibling contract: only `status --json` for bar state; actions `start`/`stop` with id/`--group`/`--all`; version via `--version`. Status is a point-in-time JSON document (`version === 1`). Plugin must not read `connections.json`. Local: `/home/golgor/Code/Personal/cloud-sql-tracker/docs/status-document.v1.md`.

---

### 2. State ownership

1. **Host model** — One Quickshell instance; plugins load inside it; shared services live once; summon is IPC into the running process. `/usr/share/omarchy/shell/README.md`; [Shell Plugins manual](https://omarchy.org/manual/shell-plugins/).

2. **Two common ownership shapes for bar + popup**

   | Shape | Manifest | Who owns Process / timers | Examples |
   |-------|----------|---------------------------|----------|
   | **A. Nested panel under bar-widget** | `kinds: ["bar-widget"]`, `entryPoints.barWidget` → thin `BarWidget.qml` that `Loader`s `Panel.qml` | Panel (or child Item) holds state; bar only displays + injects | Weather, clock; **this repo’s scaffold** |
   | **B. Combined entry** | `barWidget` points at `Panel.qml` directly (Panel subclasses still paint the bar button) | Same file hosts button + `Service {}` / `Main {}` child | Tailscale (`Service.qml`), agents (`Main.qml`), network, power, audio |
   | **C. True shell service + bar-widget** | `kinds: ["service","bar-widget"]`, often `keepLoaded: true` | Host mounts `Service.qml` once; bar uses `bar.shell.firstPartyServiceFor(id)` | Media (`omarchy.media`) |

3. **When first-party code uses a separate `kind: "service"`** — Headless work that must exist without a bar slot, or be shared across monitors as a host singleton (media/MPRIS, battery, idle, lock, notifications). CLI poll for a *user* bar widget is **not** required to be a shell service: Tailscale and agents keep long-lived pollers as plain `Item` children of the panel entry. Media is the contrast case: service entry + bar looks up `firstPartyServiceFor("omarchy.media")`. `/usr/share/omarchy/shell/plugins/README.md`, `services/media/manifest.json`, `services/media/BarWidget.qml`.

4. **Settings wiring** — Base `BarWidget` / `Panel` expose `settings` and `setting(name, fallback)` reading **inline** fields on the `shell.json` layout entry (no nested `config:` object). Manifest `barWidget.defaults` + `schema` document keys (e.g. Tailscale `refreshIntervalSec`). Persist mutations via `bar.shell.updateEntryInline(moduleName, entry)`. `/usr/share/omarchy/shell/Ui/BarWidget.qml`, `Ui/Panel.qml`; `/usr/share/omarchy/shell/README.md` (“Settings are inline on the entry”).

5. **Poll timers** — Typical: always-on `Timer` with `triggeredOnStart: true` (weather minutes; Tailscale `refreshIntervalSec`; agents 900s default). Faster or extra work while open: network `detailsPoll` 1.5s and `bandPoll` 4s with `running: root.opened`; agents `refreshLimits()` on open; Tailscale `onOpenedChanged → tailscale.refresh()`. Scaffold defaults already mirror closed/open intervals (`refreshIntervalSec` / `refreshIntervalOpenSec` in this repo’s `manifest.json`).

6. **Hot-reload implications** — Saving under `~/.config/omarchy/plugins/` triggers reload (inotify on plugins dir → shell reload path). Tracked `Process` children die with the QML tree; detached processes do not. State held only in QML properties resets on reload; durable state belongs in CLI-owned files or `shell.json` settings. File watches (`FileView` weather location; agents usage JSON) rehydrate after reload. `/usr/share/omarchy/shell/services/PluginRegistry.qml` (`localPluginWatcher`); shell README; weather `FileView` on `~/.local/state/omarchy/settings/weather.json`.

7. **Multi-monitor** — Bar widgets exist per monitor. `BarWidget.broadcast(method)` fans out to `bar.moduleWidgets(moduleName)` so IPC refresh does not update only one screen. Clock IPC uses `broadcast("refresh")`. Important if status is polled independently per instance (duplicate CLI load) vs shared service (single poll). `/usr/share/omarchy/shell/Ui/BarWidget.qml`.

---

### 3. Model split

1. **`import "Model.js" as Model` is the dominant pattern** for pure parse/map — Weather, network, power, clock, Tailscale (`Service.qml` imports `Model.js`). Functions take plain data in/out: `parseLocationFile`, `parseNetworkStatus`, `parseStatus` (Tailscale), `buildForecastDays`, etc. Keeps QML for binding/UI and JS for JSON/string math. Paths under `/usr/share/omarchy/shell/plugins/panels/*/Model.js`.

2. **Media uses `MediaModel.js` the same way** from `Service.qml` — same pure-helper idea without naming it `Model.js`.

3. **Agents keep more transform logic in QML `Main.qml` / `Panel.qml`** — Collector binary writes JSON files; Main discovers/merges; Panel formats meters. Still: no business logic in the bar button itself.

4. **Fixture / testability intent** — Network explicitly notes ConnectionFailReason values are passed into Model helpers so helpers “stay pure JS and Node-testable.” Weather Model has no QML imports—only functions and JSON.parse. Practical pattern for this plugin: `Model.js` (or `StatusModel.js`) with `parseStatusDocument(raw) → { ok, versionError, running, errorCount, groups, connections, ... }` matching status document v1; QML only assigns properties and renders.

5. **Last-good data** — Weather keeps previous `report` on failure; network keeps last details while `bandBusy`. Status UI should keep last good snapshot when a poll fails, and surface `lastError` / schema mismatch separately (per DESIGN.md empty-states).

---

### 4. Install / discover / symlinks

1. **Discovery roots** — First-party: `$OMARCHY_PATH/shell/plugins/` (nested `manifest.json` or `*.manifest.json`, depth 2–3). Third-party: `~/.config/omarchy/plugins/<id>/manifest.json` (top-level only). Scan implemented as bash embedded in `PluginRegistry.rescan()` via `Process`. `/usr/share/omarchy/shell/services/PluginRegistry.qml`; `shell/plugins/README.md`.

2. **Install paths** — `omarchy plugin add <git-url>` clones to staging, validates, moves to `~/.config/omarchy/plugins/<id>/`. Hand install: drop directory → `rescanPlugins` → enable. Enable for third-party ⇔ id appears in `shell.json` (bar layout entry, `plugins[]`, or `bar.id`). `/usr/share/omarchy/bin/omarchy-plugin-add`; [manual](https://omarchy.org/manual/shell-plugins/); shell README.

3. **Validate rules (must match shell)** — `/usr/share/omarchy/bin/omarchy-plugin-validate`:
   - `schemaVersion == 1` (JSON number)
   - required: `id`, `name`, `version`, `kinds`, `entryPoints`
   - id charset; **not** `omarchy.*`
   - each kind has matching entryPoints key (`bar-widget` → `barWidget`, etc.)
   - entry points: relative, no `..`, no absolute, file exists
   - **`find … -type l` anywhere under plugin (except pruned `.git`) → fail: “symlinks are not allowed inside a plugin folder”**

4. **Symlinks at the install directory level** — `omarchy-plugin-remove` treats `~/.config/omarchy/plugins/<id>` as directory **or** symlink (`-type d -o -type l`); symlink remove is `rm` unlink only. So a **top-level** symlink named as the plugin id is a supported *install* shape for remove/dev. That does **not** relax validate: validating the *target tree* still fails if any nested symlink exists (`node_modules`, accidental links, etc.). Clone uses `cp -aL` (dereference) into user plugins. Implications for `scripts/dev-link`:
   - Prefer `~/.config/omarchy/plugins/<id> → repo` **only if** the repo contains **zero** symlinks (validate the repo path).
   - Or rsync/`cp -aL` into the plugins dir (no live link).
   - Always run `omarchy plugin validate <path>` before enable; then `omarchy-shell shell rescanPlugins`.
   - Do not put symlinks *inside* the plugin for shared libs.

5. **Id / directory naming** — Directory name should be the manifest `id` (`io.github.golgor.cloud-sql-tracker`). Reserved: `omarchy.*`. Third-party cannot shadow first-party ids. PluginRegistry merge rejects third-party ids starting with `omarchy.`.

6. **Auto reload** — inotify on `pluginsDir` emits `localPluginChanged`; shell debounces reload. Forced: `omarchy-shell shell rescanPlugins`.

---

### 5. Bar + Panel coupling

1. **Scaffold already matches weather/clock split** — This repo’s `BarWidget.qml` extends `qs.Ui.BarWidget`, `Loader`s `Panel.qml`, and `injectPanel()` sets `bar`, `anchorItem`, `hostWidget`, `settings`. Weather/clock do the same and document why.

2. **`hostWidget` / bar identity** — Nested panel is **not** what the bar tracks. Weather:

   > The bar tracks the widget mounted in its slot — `BarWidget.qml` — not this nested panel. … popout coordinator … compares against `slot.activeItem`

   Panel exposes `hostWidget` and `readonly property var barIdentity: hostWidget || root`, passes `owner: root.barIdentity` into `KeyboardPanel`, and uses `bar.switchPanelFrom(root.barIdentity, direction)`. Forward `opened`, `open`/`close`/`toggle`, and preferably `closeForPopoutSwitch` / `popoutSwitchClosing` on the **bar-widget root** for summon/hide and popout switch. `/usr/share/omarchy/shell/plugins/panels/weather/BarWidget.qml`, `Panel.qml`; clock `BarWidget.qml`.

3. **`injectPanel` timing** — Call on Loader `onLoaded`, `Qt.callLater(injectPanel)`, and on `onBarChanged` / `onSettingsChanged` so late host injection still lands.

4. **Combined Panel entry (Tailscale/agents/network)** — Single root is both bar chrome (`BarIconButton`) and `Panel` base (`controller.show/hide`, `opened`). `manageIpc: false` when the file registers a custom `IpcHandler` (extra methods: `refresh`, `status`, …). Default `qs.Ui.Panel` already provides open/close/toggle IPC when `manageIpc: true` and `ipcTarget` set. `/usr/share/omarchy/shell/Ui/Panel.qml`.

5. **Popup chrome** — First-party rich panels use `KeyboardPanel` with `anchorItem` (the bar button), `bar`, `owner`, `open: root.opened`, focus catcher, fitted width/height. Weather sets `centerOnBar: true` for the center pill; right-side widgets anchor to the button. Tooltip on bar often suppressed when the panel is the detail view (weather).

6. **Shell summon routing** — Manifest id is the summon/toggle target (`omarchy-shell shell toggle <id>`). Description in this repo’s manifest already documents toggle for `io.github.golgor.cloud-sql-tracker`. Bar-widget panels are mounted with the bar, not via the on-demand panel loader used for pure `kind: "panel"` plugins (see shell comments on bar-widget panel plugins in upstream `shell.qml` patterns / weather shape contract).

7. **Visibility** — Bar can collapse empty widgets (`visible: false` when no data—agents, weather empty label). Useful when CLI missing vs zero connections (product choice).

---

## Implications for this plugin

Options and trade-offs only—no single forced architecture.

### A. Nested `BarWidget.qml` + `Panel.qml` (current scaffold; weather/clock)

- **Pros:** Matches existing repo files; clear bar identity/`hostWidget` story; bar stays thin; easy to reason about popout owner; validate entry point is one file.
- **Cons:** Status poller lives under the Loader panel—must keep `Loader { active: true }` (already true) so bar count updates while closed; per-monitor instances each poll unless you add extra sharing.

### B. Combined `Panel.qml` as `barWidget` entry (Tailscale/agents/network)

- **Pros:** One root owns button, panel, `Service`/`Main` child, IPC; fewer injectPanel edge cases; natural place for `busy` and optimistic toggle.
- **Cons:** Larger file or still splits `Service.qml` as a child; diverges from current scaffold; must still expose bar geometry/`opened` on that root.

### C. Add `kind: "service"` + `keepLoaded` (media-style)

- **Pros:** Single poll shared across monitors; survives bar layout tweaks if host always mounts services.
- **Cons:** Heavier contract; `firstPartyServiceFor` is a **first-party host** API—third-party may not get the same injection; enable rules differ for non-widget kinds (`plugins[]` vs layout); likely overkill for a dropdown that only matters when the widget is installed. Prefer a child `Item` service **inside** the widget (Tailscale) over shell `kind: "service"` unless host docs confirm third-party service mounting.

### Process / model recommendations (compatible with A–C)

1. **Dedicated Processes:** `statusProc`, `versionProc`, `actionProc` (or one action queue)—never one Process for concurrent status+action without a queue.
2. **Guards:** `if (statusProc.running) return` on timer ticks; optional watchdog if CLI can hang; after start/stop, `delayedRefresh` like Tailscale.
3. **Parse in `Model.js`:** enforce `version === 1`, map aggregates `running`/`error`, group connections; ignore unknown fields (status doc consumer checklist).
4. **Detached:** only if you intentionally spawn something that should outlive the shell; prefer tracked Process for start/stop so the panel can show failure stderr.
5. **Settings:** use existing manifest keys (`cliPath`, intervals, `minCliVersion`) via `setting()`; persist only UI prefs in `shell.json`, never connections.
6. **Open vs closed poll:** timer interval bound to `opened ? openSec : closedSec` (network-style extra timers or single timer with dynamic interval).

### Install / dev-link

| Approach | Validate | Live edit | Notes |
|----------|----------|-----------|-------|
| Top-level symlink `plugins/<id> → git checkout` | Passes only if tree has **no** symlinks | Yes (inotify) | Matches remove’s symlink support; run validate often |
| `cp -aL` / rsync install | Clean | No (need re-copy) | Closest to `plugin add` / clone |
| `omarchy plugin add` from git | Clean | `plugin update` | Production path |

Avoid nested symlinks entirely. Id directory must match `io.github.golgor.cloud-sql-tracker`.

### Bar coupling checklist (whatever layout)

- [ ] `opened` / `open` / `close` / `toggle` on bar-widget root  
- [ ] `hostWidget` + `barIdentity` if panel is nested  
- [ ] `injectPanel` on load + bar/settings changes  
- [ ] `KeyboardPanel` `owner` = bar identity; `anchorItem` = button  
- [ ] Optional `closeForPopoutSwitch` / `popoutSwitchClosing`  
- [ ] IPC: default Panel handler or `manageIpc: false` + custom (`refresh`, etc.)  
- [ ] Consider `broadcast("refresh")` if IPC should update all monitors  

### Severity notes for scaffold gaps (not defects until implementation)

| Item | Severity | Path / note |
|------|----------|-------------|
| No `Process` / status poll yet | info (scaffold) | `BarWidget.qml`, `Panel.qml` |
| Nested panel missing weather’s full popout forwards (`closeForPopoutSwitch`, `popoutSwitchClosing`, `openFromHotkey`) | low until multi-panel UX | `BarWidget.qml` |
| Panel lacks `manageIpc` / `ipcTarget` | low | `Panel.qml` — base defaults may suffice once wired |
| No `Model.js` yet | info | recommended before UI growth |
| DESIGN claims Process seam; matches Omarchy practice | info | `docs/DESIGN.md` |

---

## Sources

### Kept (primary)

- `/usr/share/omarchy/shell/README.md` — host model, manifest schema, shell.json, IPC, install
- `/usr/share/omarchy/shell/plugins/README.md` — first-party plugin catalogue and kinds
- `/usr/share/omarchy/shell/services/PluginRegistry.qml` — validate, scan, enable, inotify
- `/usr/share/omarchy/shell/Ui/BarWidget.qml`, `Ui/Panel.qml` — base inject API, IPC, settings
- `/usr/share/omarchy/shell/plugins/panels/weather/{BarWidget,Panel,Model}.qml/js` — nested panel, Process, Model.js, injectPanel
- `/usr/share/omarchy/shell/plugins/panels/tailscale/{Panel,Service,manifest}.qml` — CLI JSON poll, overlap guards, watchdog, combined entry
- `/usr/share/omarchy/shell/plugins/agents/{Panel,Main}.qml` — queued Process, file-backed state, open refresh
- `/usr/share/omarchy/shell/plugins/panels/network/{Panel,Model}.js` — open-only fast poll, action serialization, pure Model
- `/usr/share/omarchy/shell/plugins/services/media/{Service,BarWidget,manifest}` — true service + bar lookup
- `/usr/share/omarchy/shell/plugins/panels/clock/BarWidget.qml` — injectPanel + broadcast IPC
- `/usr/share/omarchy/bin/omarchy-plugin-validate` — no internal symlinks; schema checks
- `/usr/share/omarchy/bin/omarchy-plugin-add`, `omarchy-plugin-remove`, `omarchy-plugin-clone` — install/remove/symlink top-level
- [Quickshell Process](https://quickshell.org/docs/v0.2.0/types/Quickshell.Io/Process/), [StdioCollector](https://quickshell.org/docs/v0.2.0/types/Quickshell.Io/StdioCollector/)
- [Omarchy Shell Plugins manual](https://omarchy.org/manual/shell-plugins/)
- Sibling: `/home/golgor/Code/Personal/cloud-sql-tracker/docs/status-document.v1.md`
- This repo: `manifest.json`, `BarWidget.qml`, `Panel.qml`, `docs/DESIGN.md`

### Dropped

- Secondary blogs / “the quickshell book” mirrors — not first-party
- omarchyplugins.com develop page — community mirror of manual; official manual + source preferred
- GitHub PR narrative (“Omarchy goes Quickshell”) — historical, not API contract

---

## Gaps

- Third-party **`kind: "service"`** mounting and whether `firstPartyServiceFor` has a third-party equivalent was not fully traced in `shell.qml` beyond first-party media usage—treat shell-level services as uncertain for this plugin until a host code path is confirmed.
- Exact `KeyboardPanel` / `PanelController` geometry math not fully read; rely on weather/Tailscale usage patterns.
- No live `omarchy plugin validate` run from this research agent (no shell); claims about symlink validate come from script source.
- User `~/.config/omarchy/plugins/` contents not enumerated (directory read unavailable); patterns taken from bin + registry code.

**Suggested next steps:** codebase-design grill choosing A vs B; add `Model.js` fixtures from CLI golden `status.v1.json`; spike one `Process` status poll behind the scaffold Loader; decide multi-monitor poll duplication vs later optimization.
