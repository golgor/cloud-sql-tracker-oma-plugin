# cloud-sql-tracker-oma-plugin

A fast, keyboard-first Omarchy bar widget to monitor and control your [Google Cloud SQL Auth Proxies](https://github.com/GoogleCloudPlatform/cloud-sql-proxy) at a glance.

Toggle database proxies individually, spin up entire environment groups (`backend`, `frontend`, `staging`), or hit emergency **Stop all** — directly from your status bar without context-switching to terminal windows.

Powered by the external [`cloud-sql-tracker`](https://github.com/golgor/cloud-sql-tracker) control plane CLI.

## Status

**v1.0 Stable.** Features house-style grouped list UI, live status polling, environment group actions, setup preflight, and full keyboard navigation (`j`/`k`, `Enter`, `h`/`l`). Recommends CLI **≥ 0.1.1** for disabled-connection labeling (backward-compatible with older CLI versions).

| | |
|--|--|
| Plugin id | `io.github.golgor.cloud-sql-tracker` |
| How it works | [docs/how-it-works.md](docs/how-it-works.md) |
| Module seams | [docs/modules.md](docs/modules.md) |
| Design / chrome | [docs/DESIGN.md](docs/DESIGN.md), [docs/chrome.md](docs/chrome.md) |
| Agent notes | [AGENTS.md](AGENTS.md) |
| Language | [CONTEXT.md](CONTEXT.md) |
| Control plane | [golgor/cloud-sql-tracker](https://github.com/golgor/cloud-sql-tracker) |

## Requirements

- Omarchy with `omarchy plugin` support
- [`cloud-sql-tracker`](https://github.com/golgor/cloud-sql-tracker) on your `PATH` (or set `cliPath` in plugin settings)
- Configured `~/.config/cloud-sql-tracker/connections.json` (see CLI repo examples)
- `cloud-sql-proxy` + GCP ADC set up for the proxy itself

## Install

```bash
# Install from git and enable on the bar
omarchy plugin add https://github.com/golgor/cloud-sql-tracker-oma-plugin.git --enable
```

Place **Cloud SQL Tracker** on the bar (category *Development*), or add it in
`~/.config/omarchy/shell.json`.

## Removal

```bash
# Remove an installed plugin
omarchy plugin remove io.github.golgor.cloud-sql-tracker
```

Validate a local checkout:

```bash
omarchy plugin validate ~/Code/Personal/cloud-sql-tracker-oma-plugin
```

## Keyboard

The panel is fully drivable without a mouse once open: `j`/`k` walk rows across
group boundaries, `Enter` toggles whatever the cursor is on, `h`/`l` are the
explicit stop/start verbs for a connection or a whole group, `Esc` closes, and
`Tab` switches to the neighbouring bar panel.

To summon it with a hotkey, add a binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + Q", "Cloud SQL Tracker",
  "omarchy-shell shell toggle io.github.golgor.cloud-sql-tracker")
```

If that combination is already taken, `hl.unbind("SUPER + CTRL + Q")` on the line
before releases it first — check with `omarchy menu keybindings --print`.

Omarchy's built-in `SUPER + CTRL + <n>` also toggles the nth panel in the bar's
right section, which may already reach this one; a named binding is preferred
because the numbered form is positional and follows bar order.

## Local development

For working on this plugin itself, symlink this checkout into Omarchy's plugin
directory instead of using `omarchy plugin add` (which clones a copy):

```bash
./scripts/dev-link
```

This symlinks `~/.config/omarchy/plugins/io.github.golgor.cloud-sql-tracker`
to this checkout, runs `omarchy plugin validate`, rescans plugins, and
enables the widget (default bar section: `right`). Safe to re-run.

**Saved edits do not hot-reload.** The shell watches its own config path, not a
symlinked plugin directory, so QML changes under this checkout are picked up only
after:

```bash
omarchy restart shell
```

The symlink still saves you re-cloning on every change — it is the copy step that
goes away, not the reload step.

```bash
./scripts/dev-link --help              # options
./scripts/dev-link --section left      # place elsewhere
./scripts/dev-link --no-enable         # link + validate only
node scripts/check-model.js            # Model.js + fixtures (no QML runtime)
```

It never deletes a real plugin directory: if something other than a symlink
to this checkout already occupies that path, it fails with no changes made.

**Unlink:**

```bash
rm ~/.config/omarchy/plugins/io.github.golgor.cloud-sql-tracker
omarchy plugin disable io.github.golgor.cloud-sql-tracker   # optional
```

`omarchy plugin add <git-url>` (above) remains the non-dev install path for
everyone else — it clones its own copy rather than tracking a local checkout.

Agent workflow (branch, PR, seams, contract): [AGENTS.md](AGENTS.md).

## Contract

The plugin **only** shells out to:

```bash
cloud-sql-tracker --version
cloud-sql-tracker status --json
cloud-sql-tracker doctor --json   # once when the panel opens
cloud-sql-tracker start <id|--group=G|--group G|--all>
cloud-sql-tracker stop  <id|--group=G|--group G|--all>
```

It does **not** read or write the connections config file. Doctor hard-fail
hides the connection list (setup unusable). Per-connection start failures show
on the row after setup passes.

Disabled Connections (`enabled: false` in config, exposed on Status) stay
visible in the panel but are not start targets. Bar and group counts use
enabled Connections only.

## License

MIT
