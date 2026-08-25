# Test framework draft

**Purpose:** protect the Tracker/control-plane process seam that can affect the
long-lived Omarchy Quickshell bar.

**Issue:** marketplace review
[HANCORE-linux/omarchy-plugin-marketplace#1895](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/1895).

## Goals

- Prove the Tracker keeps CLI stdout/stderr bounded before QML stores it.
- Prove a hanging Control plane cannot keep a Tracker action busy forever.
- Prove the plugin keeps the frozen CLI contract and module seams.
- Keep normal PR checks fast.
- Make failures diagnosable from CI artifacts.

## Non-goals

- No screenshot or pixel tests.
- No real Google Cloud, ADC, Proxy, or `connections.json` access.
- No full Omarchy shell session in CI.
- No new Control plane commands.

## Pick

Use three test layers.

1. **Pure checks** — Node and shell scripts. Run everywhere.
2. **QML seam checks** — static checks against QML source. Run everywhere.
3. **Process seam integration** — a short Quickshell run with a fake Control
   plane. Run on an Arch/Omarchy-capable runner.

**Why:** each layer tests one module interface at the lowest stable seam.

**Discarded:** one large end-to-end panel test. It would be brittle, theme- and
compositor-sensitive, and poor at diagnosing process memory failures.

**Unchanged:** `BarWidget.qml` and `Panel.qml` still call Tracker only. `Process`
stays in `Tracker.qml`.

## Test files

```text
scripts/check-model.js                 # existing Model.js fixture check
scripts/check-qml-seams.sh             # static module seam check
scripts/check-process-seam.sh          # Quickshell process seam runner

tests/fixtures/fake-cloud-sql-tracker       # fake Control plane adapter
tests/process-seam/shell.qml                # minimal Quickshell harness
tests/process-seam/imports/CloudSqlTracker  # named test import for real Tracker
tests/process-seam/cases/*.json             # optional case declarations later
```

## Layer 1: pure checks

### Pick

Keep `scripts/check-model.js` as the fast Status document parser gate. Add more
pure modules only when code naturally has a deep internal seam.

Examples:

- `Model.js` — Status document parse and validation.
- optional later: `TrackerRules.js` — argv target rules, version rules, setting
  shape rules.

### Why

Pure checks are the cheapest way to cover shape validation and hostile input.
They do not need Qt, Quickshell, Wayland, or Omarchy.

### Discarded

Do not move QML-only behavior into JS just to test it. Extract only clusters that
pass the deletion test.

### Unchanged

The public Tracker interface remains `refresh()`, `runDoctor()`, `start(target)`,
`stop(target)`, plus view properties.

## Layer 2: QML module seam checks

### Pick

Add `scripts/check-qml-seams.sh`.

It should fail when:

- `Process {` appears outside `qml/Tracker.qml`.
- `Quickshell.Io` appears outside files that are allowed to own process I/O.
- `Model.js` is imported by `BarWidget.qml` or `Panel.qml`.
- CLI argv strings appear in `BarWidget.qml` or `Panel.qml`.
- `Tracker.qml` launches a process without `_cappedCommand(...)`.

### Why

These checks protect the architecture with near-zero runtime cost.

### Discarded

Do not parse QML into a full AST for the first version. Grep-style checks are
enough because the forbidden patterns are simple and deliberate.

### Unchanged

`omarchy plugin validate .` remains the plugin-shape validator. The seam check is
not a replacement for it.

## Layer 3: process seam integration

### Pick

Run a separate Quickshell process with a fake Control plane adapter.

The harness imports the real Tracker through a named test qmldir, injects
settings, then drives only the Tracker interface:

```qml
import CloudSqlTracker as Shared

Shared.Tracker.settings = {
  cliPath: fakeCliPath,
  minCliVersion: "0.1.0",
  refreshIntervalSec: 60,
  refreshIntervalOpenSec: 60
}

Shared.Tracker.refresh()
Shared.Tracker.runDoctor()
Shared.Tracker.start({ kind: "id", id: "backend-dev" })
```

The harness must not instantiate `Panel.qml`.

### Why

The risk is not visual chrome. The risk is `Process` output crossing into QML
memory. Testing Tracker directly gives the most leverage.

### Discarded

Do not run against the real Omarchy shell in CI. That adds bar layout,
compositor, user config, and plugin registry state to a process-safety test.

### Unchanged

Manual dogfood still covers the actual bar: count, panel open, one Connection
action, one Group action.

## Process Adapter cap wrapper

### Pick

Tracker's process Adapter uses a local shell cap wrapper before it executes the
Control plane argv. The wrapper is the producer-side byte ceiling for #1895.

### Why

Quickshell's `StdioCollector` has already buffered data by the time QML can read
`data.byteLength`. A pipe through `head -c` caps stdout/stderr before those bytes
enter QML memory.

### Discarded

Do not remove the shell wrapper unless Quickshell exposes a producer-side byte
limit or another implementation keeps the same cap before QML buffering.

### Unchanged

The frozen Control plane command set does not expand. The wrapper executes only
these argv as data, never as shell text:

```text
cloud-sql-tracker --version
cloud-sql-tracker status --json
cloud-sql-tracker doctor --json
cloud-sql-tracker start <id|--group=G|--all>
cloud-sql-tracker stop  <id|--group=G|--all>
```

## Fake Control plane adapter

### Interface

`tests/fixtures/fake-cloud-sql-tracker` must accept the frozen CLI contract:

```text
fake-cloud-sql-tracker --version
fake-cloud-sql-tracker status --json
fake-cloud-sql-tracker doctor --json
fake-cloud-sql-tracker start <id|--group=G|--all>
fake-cloud-sql-tracker stop  <id|--group=G|--all>
```

It is configured with environment variables:

```text
CST_FAKE_MODE          happy | status-flood | stderr-flood | hang-status | hang-action | doctor-fail | version-flood | doctor-flood | action-flood
CST_FAKE_BYTES         bytes the fake will attempt to write
CST_FAKE_CHUNK_BYTES   write chunk size, default 65536
CST_FAKE_TRACE         path to a JSONL trace file
```

Trace lines are JSONL:

```json
{"event":"attempted-write","command":"status --json","stream":"stdout","bytes":67108864}
{"event":"exit","command":"status --json","code":0}
```

### Why

Quickshell can only observe bytes that pass the producer cap. The fake adapter
records the larger attempted flood separately.

### Discarded

Do not infer attempted flood size from QML logs. A correct cap hides that from
QML by design.

### Unchanged

The real Control plane stays external. Tests do not read or write its config.

## Quickshell harness diagnostics

### Pick

Emit structured log markers from the harness and, if needed, from dormant Tracker
diagnostics enabled only during tests.

Prefix every machine-readable line:

```text
CST_TEST {"event":"stream-bytes","proc":"status","stream":"stdout","bytes":262144}
CST_TEST {"event":"observed","degradedKind":"status_failed","busyKey":""}
CST_TEST {"event":"settled","case":"status-over-limit"}
```

Use `StdioCollector.data.byteLength` for bytes seen by QML. `Tracker.qml` exposes
this through the inert-by-default `testDiagnosticsEnabled` /
`testStreamBytes(...)` test hook. Product callers do not use it.

### Why

The CI log and `.qslog` become enough to explain failures without rerunning the
case interactively.

### Discarded

Do not rely only on human-readable `console.warn` lines. They are useful, but
harder to assert.

### Unchanged

Normal operator-facing Degraded messages remain short and plain text.

## Memory assertions

### Pick

Measure Quickshell RSS from outside the process.

`scripts/check-process-seam.sh` runs each case through `/usr/bin/time -v` when
available, with a procfs RSS sampler fallback for lean Arch installs that do not
ship GNU time:

```bash
/usr/bin/time -v \
  timeout 12s quickshell --path tests/process-seam/shell.qml --no-color
```

Assertions:

- process exits before the outer timeout;
- exit code is expected: `0`, or `143` only after the harness emitted both the
  settled and terminator markers and sent SIGTERM to its own throwaway
  Quickshell process;
- `124` from `timeout(1)` always fails, even if a settled marker exists;
- expected `CST_TEST` settled marker appears;
- fake trace shows the attempted flood size;
- QML collector byte count stays near the configured cap;
- max RSS stays below a generous absolute ceiling;
- flood-case RSS does not exceed baseline RSS by more than a configured delta;
- no fake Control plane child remains after timeout cases.

Suggested first ceilings:

```text
CST_MAX_RSS_KB=262144          # absolute guard, 256 MiB
CST_MAX_RSS_DELTA_KB=65536     # flood over baseline, 64 MiB
```

Tune after the first local and CI runs.

### Why

RSS is the only direct answer to “could this crash the long-lived shell?” Byte
counts prove the cause; RSS proves the effect stayed bounded.

### Discarded

Do not assert exact memory values. Qt and Quickshell startup memory varies by
host.

### Unchanged

The Status document cap remains the CLI contract cap: 256 KiB for `status
--json`.

## Artifact directory safety

### Pick

`CST_PROCESS_SEAM_ARTIFACTS` must resolve under the repo root. The script rejects
empty paths, `~`, `/`, `/tmp`, paths outside the repo, the repo root, `.git`, and
paths containing tracked files.

### Why

The script cleans the artifact directory before each run.

### Discarded

Do not allow arbitrary absolute paths for convenience. A process safety test must
not be able to delete unrelated files.

### Unchanged

The default artifact directory remains `.test-artifacts/process-seam/`.

## Initial process-seam cases

Start small.

| Case | Fake mode | Expected result |
|------|-----------|-----------------|
| `happy-status` | `happy` | valid Status document accepted |
| `status-over-limit` | `status-flood`, `CST_FAKE_BYTES=10485760` | Degraded; QML sees at most 256 KiB; RSS bounded |
| `stderr-over-limit` | `stderr-flood`, `CST_FAKE_BYTES=10485760` | Degraded or row error; QML sees bounded stderr; RSS bounded |
| `hang-status` | `hang-status` | timeout Degraded; process settles |
| `hang-action` | `hang-action` | row action error; `busyKey` clears |

Add doctor/version/action-specific flood cases after the harness is stable.

## CI shape

### Pick

Use two jobs.

```yaml
name: ci

on:
  pull_request:
  push:
    branches: [main, "fix/**", "feat/**", "docs/**", "wayfinder/**", "test/**"]
  workflow_dispatch:
    inputs:
      run_omarchy_process_seam:
        type: boolean
        default: false

jobs:
  portable:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: node scripts/check-model.js
      - run: bash scripts/check-qml-seams.sh

  omarchy-process-seam:
    if: ${{ github.event_name == 'workflow_dispatch' && inputs.run_omarchy_process_seam }}
    runs-on: [self-hosted, linux, arch, omarchy]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: omarchy plugin validate .
      - run: bash scripts/check-process-seam.sh
```

The self-hosted job is `workflow_dispatch` + input gated so normal PR checks do
not queue forever when no Omarchy runner is registered. Run it manually once a
runner exists. When that job runs, missing `quickshell` is a hard failure.

### Why

GitHub-hosted Ubuntu can run pure checks, but it is the wrong host for
Quickshell/Omarchy process behavior. The risky seam should run on the platform
that owns the risk.

### Discarded

Do not make the Quickshell process test silently pass when `quickshell` is
missing. That would create false confidence.

### Unchanged

Marketplace validation remains external. This CI proves this repo's own process
safety claim before submission.

## Artifact policy

On failure, upload:

```text
process-seam.log             # foreground quickshell output
process-seam.qslog           # copied Quickshell log, if present
process-seam.qslog.path      # source path and copy status, or not-found
process-seam.qslog.not-found # present only when no readable .qslog was found
fake-control-plane.jsonl
rss.txt
children-after.txt
```

These artifacts should answer:

- what command was run;
- how many bytes the fake attempted;
- how many bytes QML observed;
- which Degraded or row error state settled;
- max RSS;
- whether any child process survived.

## First implementation slice

1. Add `scripts/check-qml-seams.sh`.
2. Add `tests/fixtures/fake-cloud-sql-tracker`.
3. Add `scripts/check-process-seam.sh` with `happy-status`,
   `status-over-limit`, `stderr-over-limit`, `hang-status`, and `hang-action`.
4. Add the CI `portable` job.
5. Add the workflow-dispatch self-hosted `omarchy-process-seam` job.

This gives useful process safety regressions without locking the repo into a
large visual test harness.
