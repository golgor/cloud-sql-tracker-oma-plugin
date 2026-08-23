# How it works

Cold-start guide for the Omarchy **Cloud SQL Tracker** bar plugin. For seams and
interfaces, see [`modules.md`](./modules.md). For product locks, see
[`DESIGN.md`](./DESIGN.md). For look and keys, see [`chrome.md`](./chrome.md).
Domain words: [`../CONTEXT.md`](../CONTEXT.md).

## What this plugin is

A bar dropdown that **observes** and **acts on** Cloud SQL Auth Proxy processes
through the external CLI `cloud-sql-tracker`.

| Owns | Does not own |
|------|----------------|
| Polling Status, bar count, panel chrome | Proxy processes (systemd user units) |
| start/stop commands via Tracker | `~/.config/cloud-sql-tracker/connections.json` |
| Optimistic UI intent until the next Status | Doctor, logs, restart UIs (v1) |

The CLI is the **control plane**. The plugin is a **client** of that CLI.

## End-to-end flow

```text
  operator
     │
     ▼
 ┌────────────┐     bind / call      ┌─────────────┐
 │ BarWidget  │ ───────────────────► │   Tracker   │
 │ Panel.qml  │ ◄─────────────────── │  (deep)     │
 └────────────┘   view props + cmds  └──────┬──────┘
                                            │ Process
                                            │ --version / status --json
                                            │ start|stop …
                                            ▼
                                   cloud-sql-tracker
                                            │
                                            ▼
                                   proxies / Status JSON
```

1. **Tracker** runs `cloud-sql-tracker --version` and gates on `minCliVersion`.
2. **Tracker** polls `status --json` on a timer (faster while the panel is open).
3. **Model.js** parses the Status document into view props (pure; no I/O).
4. **Bar** shows running count and a warning when there is a Connection `error`
   or Tracker is **Degraded**.
5. **Panel** renders Groups and Connections. Toggles and buttons call
   `Tracker.start` / `Tracker.stop` with an **Action target**.
6. After an action, Tracker refreshes Status. The panel holds **intent** until a
   document observed *after* the action settles confirms or denies it.

## Code structure

| Path | Role |
|------|------|
| `manifest.json` | Plugin id, bar-widget entry, settings (`cliPath`, intervals, `minCliVersion`) |
| `BarWidget.qml` | Host widget: button, `Tracker` child, `Loader` → Panel |
| `Panel.qml` | Grouped list chrome: cursor, intent, disabled rows, group actions |
| `Tracker.qml` | Poll, version gate, degraded, one action Process at a time |
| `Model.js` | `parseStatusDocument` — Status → plain objects |
| `scripts/dev-link` | Symlink this checkout into Omarchy’s plugin dir |
| `scripts/check-model.js` | Node smoke tests for Model.js + fixtures |
| `fixtures/` | Status JSON samples for Model.js |
| `docs/modules.md` | Normative module seams and Tracker interface |
| `docs/chrome.md` | Normative visuals and keyboard |

**Seam rule:** Bar and Panel never import `Model.js` and never spawn `Process`.
They only bind Tracker properties and call Tracker commands.

Full interface tables: [`modules.md`](./modules.md).

## Status document (what the UI believes)

Source of truth for rows: `cloud-sql-tracker status --json` (schema `version: 1`).

Important consumer rules:

- Ignore unknown fields (additive CLI changes stay safe).
- `connections[].enabled === false` → show the row as **disabled**, do not start
  it, do not count it in bar/group **enabled-only** totals.
- Missing `enabled` (old CLI) → treat as enabled.
- Document-level `total` in the JSON may still count every published row; the
  plugin **recomputes** enabled-only aggregates in Model.js for the bar and
  headers.
- Empty body uses **published** connection count so an all-disabled config still
  lists rows.

Field catalog lives in the CLI repo: `docs/status-document.v1.md`.

## UI behaviour (short)

### Bar

- Glyph + `runningCount` (enabled Connections in `running`).
- Warning styling when `errorCount > 0` or `degraded !== null`.
- Left click toggles the panel.

### Panel — Grouped list

- Header: title, enabled running/total, **Stop all** (one-way; no “start all”).
- Per **Group**: header counts (enabled-only), start/stop group actions.
- Per **Connection**: health glyph, name, `state · address:port` (or
  `disabled · …`), toggle.
- **Degraded** replaces the whole switchboard (CLI missing/old, bad schema,
  status failed — including invalid `connections.json`).
- **Action failure banner** (not Degraded): failed start/stop keeps the list and
  shows the CLI message (e.g. bad `proxy_bin`). Dismiss or succeed to clear.
- Keyboard: `j`/`k`, `Enter`, `h`/`l`, `Esc`, `Tab` — see README and `chrome.md`.

### Intent and busy

- Click records **intent** immediately (toggle slides; start projects
  `starting` on the glyph).
- Tracker runs **one** action at a time. Other controls stop accepting clicks
  but **do not dim** (geometry-stable busy).
- Intent clears when a Status document with newer provenance arrives after the
  action (or refusal). Detail: `chrome.md` §5 and `modules.md` “Document
  provenance”.

## Install paths

| Goal | Path |
|------|------|
| Normal use | `omarchy plugin add <git-url> --enable` (clones a copy) |
| Develop this repo | `./scripts/dev-link` then edit; `omarchy restart shell` after changes |
| CLI | Install/build sibling `cloud-sql-tracker`; put it on `PATH` or set `cliPath` |

Config Connections only via the CLI’s config file (hand-edit or future CLI
commands). The plugin never opens that file.

## Mental model checklist

You understand the plugin if you can answer:

1. What four argv families may the plugin run?
2. Which file may spawn `Process`?
3. Why can a disabled Connection look like `stopped` on an old CLI?
4. Why does Group start not throw the toggle on a disabled sibling?
5. Why is `omarchy restart shell` needed after QML edits with dev-link?

Answers: (1) version, status, start, stop — (2) `Tracker.qml` only —
(3) no `enabled` field; missing defaults to true in new plugin, old plugin
cannot tell — (4) start intent lists enabled members only — (5) shell does not
hot-reload a symlinked plugin tree.
