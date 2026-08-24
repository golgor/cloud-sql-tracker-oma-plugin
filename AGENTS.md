# Agent notes — cloud-sql-tracker-oma-plugin

This repo is the **Omarchy bar plugin** for the external control plane CLI
[`cloud-sql-tracker`](https://github.com/golgor/cloud-sql-tracker). It shows
Connection health and issues start/stop. It does **not** own Proxy processes or
`connections.json`.

## Audience

The operator is a **senior developer** on Arch / Omarchy. Treat design and
trade-offs at that level.

Do **not** re-teach Linux basics. Do explain Omarchy / Quickshell plugin
quirks when they first appear (nested panel identity, `OpticalGlyph`, shell
rescan vs restart).

## Language

Use terms from [`CONTEXT.md`](./CONTEXT.md):

| Term | Meaning |
|------|---------|
| **Tracker** | In-shell module: poll, last Status view, start/stop |
| **Control plane** | The external `cloud-sql-tracker` CLI only |
| **Status document** | JSON from `status --json` (`version` integer, currently `1`) |
| **Connection** | One row in the Status document |
| **Health state** | `stopped` \| `starting` \| `running` \| `error` |
| **Group** | Bulk-action / section label on Connections |
| **Degraded** | Tracker cannot trust the control plane (not a row `error`) |
| **Action target** | `{ kind: "id" \| "group" \| "all", … }` for start/stop |

Write short sentences. One idea each. Same word for the same thing. Active voice.

When you state a **choice**, use this order:

1. **Pick** — what we use.
2. **Why** — one reason.
3. **Discarded** — what we do not use, and why (one line).
4. **Unchanged** — what this choice does not change.

## Read before changing code

| Doc | Why |
|-----|-----|
| [`CONTEXT.md`](./CONTEXT.md) | Domain language |
| [`docs/modules.md`](./docs/modules.md) | Seams: Bar / Panel / Tracker / Model.js |
| [`docs/DESIGN.md`](./docs/DESIGN.md) | Product decisions (Grouped list, non-goals) |
| [`docs/chrome.md`](./docs/chrome.md) | Normative appearance and interaction |
| [`docs/how-it-works.md`](./docs/how-it-works.md) | Cold-start narrative and data flow |
| [`README.md`](./README.md) | Install, dev-link, keyboard, CLI contract |
| Sibling CLI `docs/status-document.v1.md` | Status field meanings |
| Sibling CLI `docs/cli-contract.v1.md` | Argv and exit codes |

**Rule:** if chrome and DESIGN disagree, one of them is a bug. Prefer
`chrome.md` for look/feel; prefer `DESIGN.md` for product lock.

## Frozen CLI contract (do not expand here)

The plugin shells out **only** to:

```text
cloud-sql-tracker --version
cloud-sql-tracker status --json
cloud-sql-tracker doctor --json
cloud-sql-tracker start <id|--group G|--all>
cloud-sql-tracker stop  <id|--group G|--all>
```

- Do **not** read or write `~/.config/cloud-sql-tracker/connections.json`.
- `doctor --json` is **panel-open preflight only** (not a poll loop). Hard fail → Degraded full body.
- Do **not** add in-panel `restart`, interactive doctor tab, or `logs` on the current map.
- CLI discovery: `PATH` or absolute `cliPath` setting only.
- Status schema `version` must be `1`. Unknown JSON fields: ignore.
- `connections[].enabled` missing → treat as `true`. UI counts are
  **enabled-only**; disabled rows stay visible and non-startable.

Control-plane changes belong in the **CLI repo**, not this one.

## Architecture (do not break)

```text
BarWidget / Panel  →  Tracker  →  Process(cloud-sql-tracker)  →  stdout
                         │
                      Model.js   (pure parse; Tracker only)
```

| File | Role |
|------|------|
| `qml/BarWidget.qml` | Thin host: button, Loader, injectPanel |
| `qml/Panel.qml` | Chrome Adapter: cursor, intent, displayState; **calls Tracker only** |
| `qml/Tracker.qml` | Deep module: poll, version gate, doctor-on-open, start/stop, degraded |
| `qml/Model.js` | Pure Status parse (no QML, no Process) |
| `manifest.json` | `kinds: ["bar-widget"]`; settings keys |

**Hard rules**

- No `Process` / argv / `Model.js` import in `BarWidget.qml` or `Panel.qml`.
- No `toggle()` on Tracker — UI picks start vs stop from Health state.
- One Tracker instance per bar widget (no shared shell `service` in v1).
- Nested host shape: Panel registers under `hostWidget` for keyboard panel switch.

Detail: [`docs/modules.md`](./docs/modules.md).

## Local dogfood

```bash
# CLI on PATH (sibling repo: mise run install-local)
cloud-sql-tracker --version

# This checkout on the bar
./scripts/dev-link
omarchy plugin validate .
node scripts/check-model.js

# After QML or Model.js edits (symlink does not hot-reload)
omarchy restart shell
```

- `scripts/dev-link` symlinks
  `~/.config/omarchy/plugins/io.github.golgor.cloud-sql-tracker` → this
  checkout, validates, rescans, enables.
- `omarchy plugin validate` forbids **in-tree** symlinks. Top-level plugin
  symlink is OK. Always validate the **checkout root**, not only the link path.
- Prefer `omarchy restart shell` after large QML landings. Rescan alone is not
  always enough.

## Git workflow (PRs)

- Branch from latest `main`: `feat/…`, `fix/…`, `docs/…`, or `wayfinder/<n>-slug`.
- Open a **Pull Request** into `main`. Link the issue (`Closes #N` when the PR
  fully resolves it).
- **Two reviewers** check each change, not one review.
- **chatgpt-sol** checks the spec against the frozen contracts. **Opus-5** checks
  module seams, depth, and code style.
- A **Sonnet-5** subagent implements the change on a git worktree. The parent
  writes no product code.
- Reviewers are **read-only**. A human performs the merge.
- Prefer one logical slice per PR.
- After merge, update the map’s **Decisions so far** in the **same session**
  when the work closes a Wayfinder ticket ([map #1](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/1)).
- Do not commit product freezes straight to `main` when collaborating via PR history.

## Checks before you push

| Check | Command |
|-------|---------|
| Manifest / plugin shape | `omarchy plugin validate .` |
| Model.js smoke | `node scripts/check-model.js` |
| Manual | Bar count, open panel, start/stop one Connection and one Group |

There is no full QML unit suite in v1. Do not invent a heavy test harness
unless a ticket asks for it.

## Out of scope (unless a ticket reopens it)

- Config UI or any `connections.json` I/O
- Packaging / AUR / plugin GitHub Release as a required bar
- Expanded view (two-pane) and multi-tab shell — [#10](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/10), [#11](https://github.com/golgor/cloud-sql-tracker-oma-plugin/issues/11)
- Implementing or changing `cloud-sql-tracker` itself
- `allowMultiple` bar widgets
- Magic multi-path CLI discovery beyond `cliPath` + `PATH`
