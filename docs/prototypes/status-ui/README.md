# PROTOTYPE — Status UI styles (throwaway)

**Wayfinder:** [#3 Prototype three Status panel and bar UI styles](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/3)

This is **not** production QML. It is a single self-contained HTML page so you can compare three bar + panel directions against a Status document fixture.

## Open

```bash
xdg-open docs/prototypes/status-ui/index.html
# or double-click index.html
```

No build step. No server required.

## Variants (`?variant=`)

| Key | Name | Structure |
|-----|------|-----------|
| **A** (default) | Grouped list | Group headers + connection rows + toggles |
| **B** | Dense chips / toolbar | Per-group start/stop chips + connection pills |
| **C** | Two-pane | Groups left; list + inspector detail right |

Switch with the floating bottom bar or keyboard **←** / **→** (when focus is not in an input).

## Scenarios (in-page)

- **Happy fixture** — golden-like Status document (7 connections; states include `running`, `starting`, `stopped`, `error`)
- **CLI missing** — degraded panel; bar warning; no invented connections
- **Empty config** — `total: 0` empty state

Actions (start/stop/group/all) are **stubs**. They only update the on-page “last action” log.

## Fixture

- Embedded copy in `index.html` for offline open
- File copy: [`status.v1.json`](./status.v1.json) (from sibling CLI golden, with `iot-dev` set to `starting` so all Health states appear)

## What to look for

- Bar summary: running count + error affordance
- Density vs clarity for ~7 connections across 3 groups
- Where bulk group actions live vs per-connection controls
- How error detail (`port_in_use`) shows up
- Empty / CLI-missing copy tone

Capture feedback on issue #3 (winner, hybrid bits, rejects). Chrome lock is a separate ticket after you react.
