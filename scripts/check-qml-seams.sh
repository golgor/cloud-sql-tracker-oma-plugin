#!/usr/bin/env bash
# Static regression gate for the QML module seams.
# It protects the Tracker/control-plane process seam without needing a QML runtime.

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

matching_files() {
  local pattern=$1
  shift
  grep -R -n -E --include='*.qml' "$pattern" "$@" 2>/dev/null || true
}

# Repo QML means the plugin runtime QML under qml/. Test harness QML is allowed
# to own its own Process instances.
repo_qml_files=(qml/*.qml)

process_hits=$(matching_files '(^|[[:space:]])Process[[:space:]]*\{' qml)
if [ -n "$process_hits" ]; then
  bad=$(printf '%s\n' "$process_hits" | grep -v '^qml/Tracker\.qml:' || true)
  if [ -n "$bad" ]; then
    fail "Process { must stay in qml/Tracker.qml only. Offending lines:\n$bad"
  fi
fi

io_hits=$(matching_files '^[[:space:]]*import[[:space:]]+Quickshell\.Io([[:space:]]|$)' qml)
if [ -n "$io_hits" ]; then
  bad=$(printf '%s\n' "$io_hits" | grep -v '^qml/Tracker\.qml:' || true)
  if [ -n "$bad" ]; then
    fail "Quickshell.Io imports must stay in qml/Tracker.qml only. Offending lines:\n$bad"
  fi
fi

for ui_file in qml/BarWidget.qml qml/Panel.qml; do
  if grep -n -E '^[[:space:]]*import[[:space:]]+.*Model\.js' "$ui_file" >/tmp/check-qml-seams-model.$$ 2>/dev/null; then
    fail "$ui_file must not import Model.js. Offending lines:\n$(cat /tmp/check-qml-seams-model.$$)"
  fi
  rm -f /tmp/check-qml-seams-model.$$

done

# Operator-facing copy may name cloud-sql-tracker. CLI argv construction must not
# live in UI files. Keep this check to exact argv fragments and command arrays.
for ui_file in qml/BarWidget.qml qml/Panel.qml; do
  argv_hits=$(grep -n -E '\[[^]]*("|'"'"')(cloud-sql-tracker|status|doctor|start|stop|--version|--json|--group|--all)("|'"'"')|\.command[[:space:]]*=|_cappedCommand|Process[[:space:]]*\{' "$ui_file" || true)
  if [ -n "$argv_hits" ]; then
    fail "$ui_file must not build Control plane argv or own Process. Offending lines:\n$argv_hits"
  fi

done

for proc in versionProc statusProc doctorProc actionProc; do
  assignments=$(grep -n -E "${proc}\.command[[:space:]]*=" qml/Tracker.qml || true)
  if [ -z "$assignments" ]; then
    fail "qml/Tracker.qml is missing a ${proc}.command assignment."
    continue
  fi
  bad=$(printf '%s\n' "$assignments" | grep -v '_cappedCommand' || true)
  if [ -n "$bad" ]; then
    fail "${proc}.command assignments must go through _cappedCommand. Offending lines:\n$bad"
  fi

done

if [ "$failures" -ne 0 ]; then
  printf '\ncheck-qml-seams: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'check-qml-seams: ok\n'
