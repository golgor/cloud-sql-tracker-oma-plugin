# cloud-sql-tracker-oma-plugin

Omarchy shell bar plugin for [cloud-sql-tracker](https://github.com/golgor/cloud-sql-tracker).

Shows an icon + running proxy count in the bar; dropdown starts/stops [Cloud SQL Auth Proxy](https://github.com/GoogleCloudPlatform/cloud-sql-proxy) connections by group.

## Status

**Scaffold / design locked.** Needs a working `cloud-sql-tracker` CLI before the widget does anything useful.

| | |
|--|--|
| Plugin id | `io.github.golgor.cloud-sql-tracker` |
| Design | [docs/DESIGN.md](docs/DESIGN.md) |
| Control plane | [golgor/cloud-sql-tracker](https://github.com/golgor/cloud-sql-tracker) |

## Requirements

- Omarchy with `omarchy plugin` support
- [`cloud-sql-tracker`](https://github.com/golgor/cloud-sql-tracker) on your `PATH`
- Configured `~/.config/cloud-sql-tracker/connections.json` (see CLI repo examples)
- `cloud-sql-proxy` + GCP ADC set up for the proxy itself

## Install

```bash
# 1) Install the CLI (see cloud-sql-tracker README), then:
omarchy plugin add https://github.com/golgor/cloud-sql-tracker-oma-plugin.git --enable
```

Place **Cloud SQL Tracker** on the bar (category *Development*), or add to `~/.config/omarchy/shell.json`.

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
enables the widget (default bar section: `right`). Saved edits under this
checkout hot-reload — no re-copy needed. Safe to re-run.

```bash
./scripts/dev-link --help              # options
./scripts/dev-link --section left      # place elsewhere
./scripts/dev-link --no-enable         # link + validate only
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

## Contract

The plugin **only** shells out to:

```bash
cloud-sql-tracker --version
cloud-sql-tracker status --json
cloud-sql-tracker start <id|--group G|--all>
cloud-sql-tracker stop  <id|--group G|--all>
```

It does **not** read or write the connections config file.

## License

MIT
