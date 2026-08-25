#!/usr/bin/env bash
# Quickshell process seam integration checks.
# Runs the real Tracker against a fake Control plane and asserts bounded output
# and bounded Quickshell memory under flood and hang cases.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if ! command -v quickshell >/dev/null 2>&1; then
  printf 'check-process-seam: quickshell not found. Install quickshell on the Arch/Omarchy runner.\n' >&2
  exit 1
fi

if [ ! -x /usr/bin/time ]; then
  printf 'check-process-seam: /usr/bin/time not found; using procfs RSS sampler fallback.\n' >&2
fi

if ! command -v timeout >/dev/null 2>&1; then
  printf 'check-process-seam: timeout(1) is required.\n' >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  printf 'check-process-seam: node is required to parse CST_TEST JSON markers.\n' >&2
  exit 1
fi

safe_artifact_dir() {
  local raw=$1
  local target target_real repo_real rel parent existing existing_real tracked

  if [ -z "$raw" ]; then
    printf 'check-process-seam: CST_PROCESS_SEAM_ARTIFACTS must not be empty.\n' >&2
    exit 1
  fi
  case "$raw" in
    '~'|'~'/*)
      printf 'check-process-seam: CST_PROCESS_SEAM_ARTIFACTS must be a repo-local path, not %s.\n' "$raw" >&2
      exit 1
      ;;
  esac

  case "$raw" in
    /*) target=$raw ;;
    *) target=$repo_root/$raw ;;
  esac

  repo_real=$(realpath -e -- "$repo_root")
  target_real=$(realpath -m -- "$target")

  if [ "$target_real" = "$repo_real" ]; then
    printf 'check-process-seam: refusing to use the repo root as artifact directory.\n' >&2
    exit 1
  fi
  case "$target_real" in
    "$repo_real"/*) ;;
    *)
      printf 'check-process-seam: artifact directory must resolve under the repo root: %s\n' "$raw" >&2
      exit 1
      ;;
  esac
  case "$target_real" in
    "$repo_real/.git"|"$repo_real/.git"/*)
      printf 'check-process-seam: refusing to clean inside .git: %s\n' "$target_real" >&2
      exit 1
      ;;
  esac

  rel=${target_real#"$repo_real"/}
  tracked=$(git -C "$repo_real" ls-files -- "$rel" "$rel/" 2>/dev/null || true)
  if [ -n "$tracked" ]; then
    printf 'check-process-seam: refusing to clean artifact directory containing tracked files: %s\n' "$target_real" >&2
    exit 1
  fi

  parent=$(dirname -- "$target_real")
  existing=$parent
  while [ ! -e "$existing" ]; do
    if [ "$existing" = / ]; then
      printf 'check-process-seam: no existing parent found for artifact directory: %s\n' "$target_real" >&2
      exit 1
    fi
    existing=$(dirname -- "$existing")
  done
  existing_real=$(realpath -e -- "$existing")
  case "$existing_real" in
    "$repo_real"|"$repo_real"/*) ;;
    *)
      printf 'check-process-seam: artifact parent resolves outside repo root: %s\n' "$existing_real" >&2
      exit 1
      ;;
  esac

  printf '%s\n' "$target_real"
}

artifact_dir=$(safe_artifact_dir "${CST_PROCESS_SEAM_ARTIFACTS:-.test-artifacts/process-seam}")
fake_cli=$repo_root/tests/fixtures/fake-cloud-sql-tracker
harness=$repo_root/tests/process-seam/shell.qml
max_rss_kb=${CST_MAX_RSS_KB:-262144}
max_rss_delta_kb=${CST_MAX_RSS_DELTA_KB:-65536}

# Cleanup is intentionally narrow. The override must resolve under this repo,
# must not be the repo root or .git, and must not contain tracked files.
rm -rf -- "$artifact_dir"
mkdir -p -- "$artifact_dir"

failures=0
baseline_rss=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

parse_rss() {
  awk -F: '/Maximum resident set size/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 }' "$1" | tail -n 1
}

descendant_pids() {
  local parent=$1
  local children
  children=$(pgrep -P "$parent" 2>/dev/null || true)
  local child
  for child in $children; do
    printf '%s\n' "$child"
    descendant_pids "$child"
  done
}

sample_rss_tree_kb() {
  local root_pid=$1
  local sum=0
  local pid rss
  for pid in "$root_pid" $(descendant_pids "$root_pid"); do
    if [ -r "/proc/$pid/status" ]; then
      rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
      if [ -n "$rss" ]; then
        sum=$((sum + rss))
      fi
    fi
  done
  printf '%s\n' "$sum"
}

run_with_rss() {
  local rss_file=$1
  local log_file=$2
  local outer_timeout_sec=$3
  shift 3

  if [ -x /usr/bin/time ]; then
    /usr/bin/time -v -o "$rss_file" \
      timeout --kill-after=2s "${outer_timeout_sec}s" \
      "$@" > "$log_file" 2>&1
    return $?
  fi

  timeout --kill-after=2s "${outer_timeout_sec}s" \
    "$@" > "$log_file" 2>&1 &
  local runner_pid=$!
  local max_rss=0
  local current_rss=0
  while kill -0 "$runner_pid" 2>/dev/null; do
    current_rss=$(sample_rss_tree_kb "$runner_pid")
    if [ "$current_rss" -gt "$max_rss" ]; then
      max_rss=$current_rss
    fi
    sleep 0.05
  done
  wait "$runner_pid"
  local rc=$?
  printf 'Maximum resident set size (kbytes): %s\n' "$max_rss" > "$rss_file"
  printf 'rss_source=procfs-sampler\n' >> "$rss_file"
  return "$rc"
}

has_case_marker() {
  local log_file=$1
  local case_name=$2
  local event_name=$3
  node - "$log_file" "$case_name" "$event_name" <<'NODE'
const fs = require("fs")
const [logFile, caseName, eventName] = process.argv.slice(2)
const text = fs.existsSync(logFile) ? fs.readFileSync(logFile, "utf8") : ""
for (const line of text.split(/\n/)) {
  const match = line.match(/CST_TEST\s+(\{.*\})/)
  if (!match) continue
  try {
    const marker = JSON.parse(match[1])
    if (marker.case === caseName && marker.event === eventName) process.exit(0)
  } catch (_) {}
}
process.exit(1)
NODE
}

assert_process_exit_status() {
  local rc=$1
  local log_file=$2
  local case_name=$3

  # timeout(1) returns 124 when the outer deadline fires. That is always a
  # harness failure, even if a settled marker was printed before Quickshell got
  # stuck during teardown. Do not let marker validation hide this.
  if [ "$rc" -eq 124 ]; then
    fail "$case_name hit the outer timeout; quickshell did not exit after the case settled or failed"
    return
  fi

  # rc 0 is allowed for runners where Quickshell exits normally.
  if [ "$rc" -eq 0 ]; then
    return
  fi

  # The harness normally terminates the throwaway Quickshell process with
  # SIGTERM after emitting the settled marker and then the terminator marker.
  # Shells report that as 128+15. Accept it only after both markers exist;
  # SIGTERM without them is an unexpected process death, not a passing test.
  if [ "$rc" -eq 143 ]; then
    if has_case_marker "$log_file" "$case_name" settled && \
        has_case_marker "$log_file" "$case_name" terminator-start; then
      return
    fi
    fail "$case_name ended with SIGTERM before settled and terminator markers were emitted"
    return
  fi

  fail "$case_name quickshell/timeout exited unexpectedly with code $rc"
}

copy_qslog_artifact() {
  local log_file=$1
  local case_dir=$2
  local qpath note_file

  note_file=$case_dir/process-seam.qslog.path
  qpath=$(sed -n -E 's/.*Saving logs to "([^"]+)".*/\1/p' "$log_file" | tail -n 1 || true)
  if [ -n "$qpath" ] && [ -r "$qpath" ]; then
    cp -- "$qpath" "$case_dir/process-seam.qslog"
    printf 'source=%s\nstatus=copied\n' "$qpath" > "$note_file"
    return
  fi

  printf 'source=%s\nstatus=not-found\n' "${qpath:-}" > "$note_file"
  printf 'Quickshell .qslog was not found from foreground output.\n' > "$case_dir/process-seam.qslog.not-found"
}

validate_markers() {
  local log_file=$1
  local trace_file=$2
  local case_name=$3
  local proc_name=$4
  local stream_name=$5
  local stream_cap=$6
  local require_attempt=$7
  local requested_bytes=$8

  node - "$log_file" "$trace_file" "$case_name" "$proc_name" "$stream_name" "$stream_cap" "$require_attempt" "$requested_bytes" <<'NODE'
const fs = require("fs")

const [logFile, traceFile, caseName, procName, streamName, streamCapRaw, requireAttemptRaw, requestedBytesRaw] = process.argv.slice(2)
const streamCap = Number(streamCapRaw)
const requireAttempt = requireAttemptRaw === "yes"
const requestedBytes = Number(requestedBytesRaw)

function parseLogMarkers(file) {
  const text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""
  const markers = []
  for (const line of text.split(/\n/)) {
    const match = line.match(/CST_TEST\s+(\{.*\})/)
    if (!match) continue
    try { markers.push(JSON.parse(match[1])) } catch (_) {}
  }
  return markers
}

function parseTrace(file) {
  const text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""
  const records = []
  for (const line of text.split(/\n/)) {
    if (!line.trim()) continue
    try { records.push(JSON.parse(line)) } catch (_) {}
  }
  return records
}

const markers = parseLogMarkers(logFile).filter(m => m.case === caseName)
const trace = parseTrace(traceFile)
const settled = markers.find(m => m.event === "settled")
const failed = markers.find(m => m.event === "fail")

if (!settled) {
  console.error(`missing settled marker for ${caseName}`)
  if (failed) console.error(`harness fail marker: ${JSON.stringify(failed)}`)
  process.exit(1)
}

if (procName !== "-") {
  const streamMarkers = markers.filter(m => m.event === "stream-bytes" && m.proc === procName && m.stream === streamName)
  if (streamMarkers.length === 0) {
    console.error(`missing stream-bytes marker for ${procName}/${streamName}`)
    process.exit(1)
  }
  const maxObserved = Math.max(...streamMarkers.map(m => Number(m.bytes) || 0))
  if (maxObserved <= 0) {
    console.error(`non-positive stream byte count for ${procName}/${streamName}`)
    process.exit(1)
  }
  if (maxObserved > streamCap) {
    console.error(`stream exceeded cap for ${procName}/${streamName}: ${maxObserved} > ${streamCap}`)
    process.exit(1)
  }
  console.log(`stream ${procName}/${streamName} maxObserved=${maxObserved} cap=${streamCap}`)
}

if (requireAttempt) {
  const attempts = trace.filter(r => r.event === "attempted-write")
  if (attempts.length === 0) {
    console.error("missing attempted-write trace")
    process.exit(1)
  }
  const maxAttempted = Math.max(...attempts.map(r => Number(r.bytes) || 0))
  if (maxAttempted < requestedBytes) {
    console.error(`attempted-write smaller than requested: ${maxAttempted} < ${requestedBytes}`)
    process.exit(1)
  }
  console.log(`attemptedWrite=${maxAttempted}`)
}

console.log(`settled=${settled.reason}; degradedKind=${settled.degradedKind || ""}; busyKey=${settled.busyKey || ""}`)
NODE
}

trace_pids() {
  local trace_file=$1
  node - "$trace_file" <<'NODE'
const fs = require("fs")
const file = process.argv[2]
if (!fs.existsSync(file)) process.exit(0)
const pids = new Set()
for (const line of fs.readFileSync(file, "utf8").split(/\n/)) {
  if (!line.trim()) continue
  try {
    const record = JSON.parse(line)
    if ((record.event === "start" || record.event === "hang") && Number.isInteger(record.pid)) pids.add(record.pid)
  } catch (_) {}
}
for (const pid of pids) console.log(pid)
NODE
}

assert_no_fake_survivors() {
  local trace_file=$1
  local survivor_file=$2
  local survivor_count=0

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      printf 'pid from fake trace still alive: %s\n' "$pid" >> "$survivor_file"
      survivor_count=$((survivor_count + 1))
    fi
  done < <(trace_pids "$trace_file")

  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f -- "$fake_cli" >> "$survivor_file" 2>/dev/null; then
      survivor_count=$((survivor_count + 1))
    fi
  fi

  if [ "$survivor_count" -ne 0 ]; then
    fail "fake Control plane process survived; see $survivor_file"
  fi
}

run_case() {
  local case_name=$1
  local mode=$2
  local requested_bytes=$3
  local qml_max_ms=$4
  local outer_timeout_sec=$5
  local proc_name=$6
  local stream_name=$7
  local stream_cap=$8
  local require_attempt=$9
  local check_survivors=${10}

  local case_dir=$artifact_dir/$case_name
  mkdir -p -- "$case_dir"
  local log_file=$case_dir/process-seam.log
  local rss_file=$case_dir/rss.txt
  local trace_file=$case_dir/fake-control-plane.jsonl
  local survivor_file=$case_dir/children-after.txt

  printf 'check-process-seam: running %s\n' "$case_name"
  set +e
  QT_QPA_PLATFORM=offscreen \
    QML2_IMPORT_PATH="$repo_root/tests/process-seam/imports${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
    CST_TEST_CASE="$case_name" \
    CST_TEST_MAX_MS="$qml_max_ms" \
    CST_FAKE_CLI="$fake_cli" \
    CST_FAKE_MODE="$mode" \
    CST_FAKE_BYTES="$requested_bytes" \
    CST_FAKE_CHUNK_BYTES="${CST_FAKE_CHUNK_BYTES:-65536}" \
    CST_FAKE_TRACE="$trace_file" \
    run_with_rss "$rss_file" "$log_file" "$outer_timeout_sec" \
      quickshell --path "$harness" --no-color
  local rc=$?
  set -e
  printf 'exit_code=%s\n' "$rc" >> "$rss_file"
  copy_qslog_artifact "$log_file" "$case_dir"
  assert_process_exit_status "$rc" "$log_file" "$case_name"

  if ! validate_markers "$log_file" "$trace_file" "$case_name" "$proc_name" "$stream_name" "$stream_cap" "$require_attempt" "$requested_bytes" > "$case_dir/parsed.txt" 2>&1; then
    cat "$case_dir/parsed.txt" >&2 || true
    fail "$case_name did not produce expected CST_TEST/fake trace markers; see $case_dir"
  else
    cat "$case_dir/parsed.txt"
  fi

  local rss
  rss=$(parse_rss "$rss_file" || true)
  if [ -z "$rss" ]; then
    fail "$case_name did not produce max RSS output; see $rss_file"
  else
    printf 'rss_kb=%s\n' "$rss" | tee -a "$case_dir/parsed.txt"
    if [ "$rss" -gt "$max_rss_kb" ]; then
      fail "$case_name max RSS ${rss} KiB exceeded CST_MAX_RSS_KB=${max_rss_kb} KiB"
    fi
    if [ "$baseline_rss" -gt 0 ] && [ "$require_attempt" = yes ]; then
      local delta=$((rss - baseline_rss))
      if [ "$delta" -gt "$max_rss_delta_kb" ]; then
        fail "$case_name max RSS delta ${delta} KiB exceeded CST_MAX_RSS_DELTA_KB=${max_rss_delta_kb} KiB"
      fi
    fi
    if [ "$case_name" = happy-status ]; then
      baseline_rss=$rss
    fi
  fi

  : > "$survivor_file"
  if [ "$check_survivors" = yes ]; then
    assert_no_fake_survivors "$trace_file" "$survivor_file"
  fi
}

run_case happy-status happy 0 8000 12 - - 0 no no
run_case status-over-limit status-flood 10485760 9000 12 status stdout 262144 yes no
run_case stderr-over-limit stderr-flood 10485760 9000 12 status stderr 65536 yes no
run_case hang-status hang-status 0 7000 10 - - 0 no yes
run_case hang-action hang-action 0 20000 24 - - 0 no yes

if [ "$failures" -ne 0 ]; then
  printf 'check-process-seam: %d failure(s). Artifacts: %s\n' "$failures" "$artifact_dir" >&2
  exit 1
fi

printf 'check-process-seam: ok. Artifacts: %s\n' "$artifact_dir"
