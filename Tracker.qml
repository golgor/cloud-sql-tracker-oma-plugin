import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Deep module: polls the cloud-sql-tracker CLI, gates on minimum version,
// and runs start/stop. BarWidget and Panel bind to the view props below and
// call refresh() / start() / stop() — they never touch Process, argv, or
// Model.js directly. Contract: docs/modules.md, docs/DESIGN.md,
// CONTEXT.md ("Tracker", "Degraded", "Action target").
Item {
  id: root

  // ---- Config in ----------------------------------------------------------

  // Manifest defaults (see manifest.json barWidget.defaults): cliPath,
  // minCliVersion, refreshIntervalSec, refreshIntervalOpenSec.
  property var settings: ({})

  // Set by the host widget/panel to switch poll cadence. See DESIGN.md
  // "Poll: slower when closed, faster when open".
  property bool panelOpen: false

  readonly property string cliPath: _stringSetting("cliPath", "cloud-sql-tracker")
  readonly property string minCliVersion: _stringSetting("minCliVersion", "0.1.0")
  readonly property int refreshIntervalSec: _intSetting("refreshIntervalSec", 5, 2, 60)
  readonly property int refreshIntervalOpenSec: _intSetting("refreshIntervalOpenSec", 2, 1, 30)

  // A settings change may repoint cliPath or tighten minCliVersion — recheck
  // the version gate on the next refresh() instead of trusting a stale pass.
  onSettingsChanged: _versionOk = false

  // ---- View out (docs/modules.md "Tracker interface") ----------------------

  // Aggregates for the bar. Per docs/modules.md: from the last good Status
  // document, or zero when degraded and no document has ever been parsed —
  // see _setDegraded()/_hasGoodDocument below. The same "keep last good, or
  // empty if none yet" rule is applied to groups/connections too, so the
  // panel never shows aggregates and rows that disagree with each other.
  property int runningCount: 0
  property int errorCount: 0
  property int total: 0
  property var groups: []
  property var connections: []

  // null when usable; otherwise { kind, message }. kind is one of
  // "cli_missing" | "cli_old" | "schema" | "status_failed" (CONTEXT.md
  // "Degraded").
  property var degraded: null

  // Action in flight. busyKey is opaque to callers beyond string identity;
  // see _targetKey() for its shape.
  readonly property bool busy: actionProc.running
  property string busyKey: ""

  // True once at least one status or version attempt has finished (success
  // or failure) — lets the UI distinguish "still loading" from "loaded and
  // degraded".
  property bool loaded: false

  // Not in the docs/modules.md interface table: a short message from the
  // last start/stop that failed at the CLI level (unknown id, no systemd
  // bus, etc.) rather than as a per-connection Health state. The Status
  // document has no field for "the action command itself failed", and the
  // interface table has no slot for it either. Added here, minimally, so a
  // failed action is not silent; flagged for reviewer / spec follow-up
  // rather than assumed. Empty string when there is nothing to report.
  property string lastActionError: ""

  // ---- Commands (docs/modules.md "Commands") --------------------------------

  // Run a status poll now (and the version gate first, when it has not
  // passed yet). Safe to call at any time; no-ops while a poll of the same
  // kind is already in flight.
  function refresh() {
    if (!_versionOk) {
      _checkVersion()
      return
    }
    _checkStatus()
  }

  // target: { kind: "id" | "group" | "all", id?, group? } — see
  // CONTEXT.md "Action target". No argv is built outside this module.
  function start(target) {
    _runAction("start", target)
  }

  function stop(target) {
    _runAction("stop", target)
  }

  // ---- Internal: settings helpers -------------------------------------------

  function _stringSetting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return (value === undefined || value === null || value === "") ? fallback : String(value)
  }

  function _intSetting(name, fallback, min, max) {
    var n = parseInt(String(settings ? settings[name] : undefined), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // ---- Internal: version gate ------------------------------------------------

  property bool _versionOk: false

  // Compares only the numeric major.minor.patch prefix (the CLI contract's
  // bare-semver output, e.g. "0.1.0"). Pre-release/build metadata suffixes
  // are not compared — out of scope for the v1 gate.
  function _versionParts(text) {
    var m = String(text || "").trim().match(/^(\d+)\.(\d+)\.(\d+)/)
    if (!m) return null
    return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)]
  }

  function _versionAtLeast(actual, required) {
    var a = _versionParts(actual)
    var r = _versionParts(required)
    if (!a || !r) return false
    for (var i = 0; i < 3; i++) {
      if (a[i] > r[i]) return true
      if (a[i] < r[i]) return false
    }
    return true
  }

  // ---- Internal: degraded / view state ---------------------------------------

  // Whether a Status document has ever parsed successfully this session.
  // Governs whether a later degraded state keeps showing that last known
  // view (stale-but-known, with the warning affordance from `degraded`) or
  // shows zero/empty (never had anything to show).
  property bool _hasGoodDocument: false

  function _setDegraded(kind, message) {
    root.degraded = { kind: kind, message: message }
    if (!root._hasGoodDocument) {
      root.runningCount = 0
      root.errorCount = 0
      root.total = 0
      root.groups = []
      root.connections = []
    }
  }

  function _clearDegraded() {
    root.degraded = null
  }

  function _applyParsed(parsed) {
    root.loaded = true
    if (!parsed.ok) {
      root._setDegraded(parsed.degraded.kind, parsed.degraded.message)
      return
    }
    root._hasGoodDocument = true
    root._clearDegraded()
    root.runningCount = parsed.running
    root.errorCount = parsed.error
    root.total = parsed.total
    root.groups = parsed.groups
    root.connections = parsed.connections
  }

  // ---- Internal: action targets ---------------------------------------------

  function _targetArgs(target) {
    if (!target) return null
    if (target.kind === "id" && target.id) return [String(target.id)]
    if (target.kind === "group" && target.group) return ["--group", String(target.group)]
    if (target.kind === "all") return ["--all"]
    return null
  }

  function _targetKey(target) {
    if (!target) return ""
    if (target.kind === "id") return "id:" + target.id
    if (target.kind === "group") return "group:" + target.group
    return "all"
  }

  // ---- Internal: process launch ----------------------------------------------

  function _checkVersion() {
    if (versionProc.running) return
    _versionExited = false
    versionProc.command = [root.cliPath, "--version"]
    versionProc.running = true
  }

  function _checkStatus() {
    if (statusProc.running) return
    _statusExited = false
    statusProc.command = [root.cliPath, "status", "--json"]
    statusProc.running = true
  }

  function _runAction(verb, target) {
    if (actionProc.running) return
    var args = _targetArgs(target)
    if (args === null) {
      console.warn("Tracker: invalid action target for " + verb + ":", JSON.stringify(target))
      return
    }
    root.lastActionError = ""
    root.busyKey = _targetKey(target)
    _actionExited = false
    actionProc.command = [root.cliPath, verb].concat(args)
    actionProc.running = true
  }

  // Guards distinguishing "the process exited normally" (onExited fired)
  // from "the process never started" (Quickshell only emits runningChanged
  // in that case — the binary was not found, or was not executable). See
  // onRunningChanged on each Process below.
  property bool _versionExited: true
  property bool _statusExited: true
  property bool _actionExited: true

  function _missingCliMessage() {
    return "Could not run '" + root.cliPath + "'. Check the cliPath setting or your PATH."
  }

  // ---- Timers ---------------------------------------------------------------

  Timer {
    id: pollTimer
    interval: (root.panelOpen ? root.refreshIntervalOpenSec : root.refreshIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // After an action exits, the document seen just before it may already be
  // stale — a short delay avoids reading it back before the CLI (and the
  // proxy it started/stopped) settle.
  Timer {
    id: delayedRefresh
    interval: 500
    repeat: false
    onTriggered: root.refresh()
  }

  // ---- Processes (docs/modules.md "Process layout") -------------------------

  Process {
    id: versionProc
    running: false
    command: []
    stdout: StdioCollector { id: versionStdout; waitForEnd: true }
    stderr: StdioCollector { id: versionStderr; waitForEnd: true }
    onExited: function (exitCode) {
      root._versionExited = true
      root.loaded = true
      if (exitCode !== 0) {
        var err = String(versionStderr.text || "").trim()
        root._setDegraded("cli_missing", err !== "" ? err : ("'" + root.cliPath + " --version' exited with code " + exitCode + "."))
        return
      }
      var text = String(versionStdout.text || "").trim()
      if (!root._versionAtLeast(text, root.minCliVersion)) {
        root._setDegraded("cli_old", "cloud-sql-tracker " + (text !== "" ? text : "(unknown)") + " is older than the required " + root.minCliVersion + ".")
        return
      }
      root._versionOk = true
      // Do not wait for the next poll tick to see the first Status document.
      root._checkStatus()
    }
    onRunningChanged: {
      if (!running && !root._versionExited) {
        root._versionExited = true
        root.loaded = true
        root._setDegraded("cli_missing", root._missingCliMessage())
      }
    }
  }

  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function (exitCode) {
      root._statusExited = true
      if (exitCode !== 0) {
        var err = String(statusStderr.text || "").trim()
        root._applyParsed({
          ok: false,
          degraded: {
            kind: "status_failed",
            message: err !== "" ? err : ("status --json exited with code " + exitCode + ".")
          }
        })
        return
      }
      root._applyParsed(Model.parseStatusDocument(String(statusStdout.text || "")))
    }
    onRunningChanged: {
      if (!running && !root._statusExited) {
        root._statusExited = true
        root.loaded = true
        // The binary was reachable for --version but is gone now (removed,
        // PATH changed mid-session, …) — re-probe from the version gate
        // rather than assuming the earlier pass still holds.
        root._versionOk = false
        root._setDegraded("cli_missing", root._missingCliMessage())
      }
    }
  }

  Process {
    id: actionProc
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function (exitCode) {
      root._actionExited = true
      root.busyKey = ""
      if (exitCode !== 0) {
        var out = String(actionStdout.text || "").trim()
        var err = String(actionStderr.text || "").trim()
        root.lastActionError = err !== "" ? err : (out !== "" ? out : ("Command exited with code " + exitCode + "."))
      }
      delayedRefresh.restart()
    }
    onRunningChanged: {
      if (!running && !root._actionExited) {
        root._actionExited = true
        root.busyKey = ""
        root.lastActionError = root._missingCliMessage()
        delayedRefresh.restart()
      }
    }
  }
}
