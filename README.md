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
