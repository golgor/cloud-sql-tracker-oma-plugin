# Design — cloud-sql-tracker-oma-plugin

Omarchy bar widget for [cloud-sql-tracker](https://github.com/golgor/cloud-sql-tracker).

## Seam

The plugin talks **only** to the CLI:

```
BarWidget / Panel  →  Process(["cloud-sql-tracker", ...])  →  stdout JSON
```

No reads/writes of `~/.config/cloud-sql-tracker/connections.json`. Config stays owned by the CLI (hand-edited v1; `config` subcommands later).

## Plugin id

`io.github.golgor.cloud-sql-tracker`

## UX (product decisions)

- Bar: icon + **running count**; warning affordance if any connection is `error`
- Dropdown: groups (`backend`, `fe`, `iot`) with a **title row** + **row of status-colored buttons** (exact chrome is iterable)
- Actions: per-connection toggle, group start/stop, stop all
- States from CLI: `stopped` | `starting` | `running` | `error`
- No autostart, no connection strings, no DBeaver integration
- Poll: slower when closed, faster when open (widget settings)
- On CLI missing / version too old / status JSON `version` mismatch: clear error in panel, don’t pretend proxies are fine

## Dependency

- `cloud-sql-tracker` on `PATH` (or `cliPath` setting)
- Minimum version via `minCliVersion` setting + `cloud-sql-tracker --version`
- Status document includes `"version": 1` (schema version); bump is a coordinated change

## Build slices (this repo)

1. Stub validate + install docs (current scaffold)
2. Status poll + bar count + error affordance
3. Dropdown list + per-row toggle
4. Group button row + stop all
5. Version gate + empty/misconfig empty-states

CLI work happens in the other repo first.
