import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Deep module: polls the cloud-sql-tracker CLI, gates on minimum version,
// runs doctor-on-open preflight, and runs start/stop. BarWidget and Panel
// bind to the view props below and call refresh() / runDoctor() / start() /
// stop() — they never touch Process, argv, or Model.js directly. Contract:
// docs/modules.md, docs/DESIGN.md, CONTEXT.md ("Tracker", "Degraded",
// "Action target"). Issue #31: doctor_failed + row-scoped actionErrors.
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
  // Also bumps _settingsGeneration so a versionProc already in flight against
  // the *old* cliPath/minCliVersion cannot validate the *new* settings when
  // it exits — see _checkVersion() and versionProc's handlers below.
  onSettingsChanged: {
    _versionOk = false
    _settingsGeneration++
    // Next panel open should re-run doctor against the new cliPath.
    root._doctorOk = null
    root._doctorFailMessage = ""
    root._doctorWanted = false
    root._doctorPending = false
  }

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
  // "cli_missing" | "cli_old" | "schema" | "status_failed" | "doctor_failed".
  // Config load failures from the CLI (exit 2 on status) land as status_failed.
  // Doctor hard-fail (ok === false) lands as doctor_failed and hides the
  // switchboard even when Status is healthy (issue #31).
  property var degraded: null

  // Action in flight. busyKey is opaque to callers beyond string identity;
  // see _targetKey() for its shape.
  readonly property bool busy: actionProc.running
  property string busyKey: ""

  // Per-connection start/stop failures the panel paints on the row (not a
  // global banner). Map id → { message, verb, exitCode }. Cleared for the
  // action's target scope on the next successful action. Issue #31.
  property var actionErrors: ({})

  function clearActionError(id) {
    if (id === undefined || id === null || id === "") {
      root.actionErrors = ({})
      return
    }
    if (!Object.prototype.hasOwnProperty.call(root.actionErrors, id)) return
    var next = {}
    for (var k in root.actionErrors) {
      if (k !== id) next[k] = root.actionErrors[k]
    }
    root.actionErrors = next
  }

  // Document provenance. `busy` covers actionProc only, so it cannot answer the
  // question a UI holding optimistic state actually has: *was this document
  // observed after my action finished?* A status poll started before an action
  // can exit after it, carrying pre-action truth, and a consumer that treats any
  // fresh document as authoritative will settle against it.
  //
  // actionEpoch counts actions whose outcome is settled — bumped when one exits,
  // and also when one is *refused*, so a refused action still advances the
  // counter and a consumer holding state for it can let go rather than waiting
  // forever on an action that never ran.
  //
  // documentEpoch is the actionEpoch that was current when the poll producing
  // the last applied document was *launched*. So `documentEpoch > e`, for an `e`
  // captured at the moment of acting, means "observed after that action
  // settled". Only successful Status documents advance it: a failed poll says
  // nothing about the world.
  readonly property int actionEpoch: root._actionEpoch
  readonly property int documentEpoch: root._documentEpoch

  property int _actionEpoch: 0
  property int _documentEpoch: -1
  property int _statusLaunchEpoch: -1

  // True once at least one status or version attempt has finished (success
  // or failure) — lets the UI distinguish "still loading" from "loaded and
  // degraded".
  property bool loaded: false

  // Doctor preflight: null = not run this settings generation; true/false
  // after runDoctor(). Hard fail wins over a healthy Status for the panel
  // (full-body Degraded, no connection list).
  property var _doctorOk: null
  property string _doctorFailMessage: ""
  // Set when runDoctor() is asked while the version gate is not yet ok, so
  // the version success path can start doctor even if panelOpen binding lags
  // (first-open race — issue #31 review).
  property bool _doctorWanted: false
  // True from doctor request until _applyDoctorReport settles. Healthy Status
  // must not clear Degraded or show the switchboard while this is true.
  property bool _doctorPending: false

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

  // One-shot setup preflight. Panel calls this on open in addition to
  // refresh(). Not on the status poll timer. Requires version gate pass.
  function runDoctor() {
    // Hide the switchboard until doctor settles (even before Process starts).
    root._doctorPending = true
    if (root.degraded === null || root.degraded.kind === "doctor_failed")
      root._setDegraded("doctor_failed", "Checking setup…")
    if (!_versionOk) {
      // Version probe in flight or not started — remember the request and
      // ensure a probe is running. versionProc onExited starts doctor when
      // the gate passes (panelOpen or _doctorWanted).
      root._doctorWanted = true
      if (!versionProc.running)
        _checkVersion()
      return
    }
    root._doctorWanted = false
    _checkDoctor()
  }

  // target: { kind: "id" | "group" | "all", id?, group? } — see
  // CONTEXT.md "Action target". No argv is built outside this module.
  //
  // Both gate on the version check (docs/modules.md "min CLI gate") having
  // passed. Calling start()/stop() while _versionOk is false — CLI missing,
  // too old, or not probed yet — is a clear no-op (logged, no Process
  // launched) rather than driving a CLI we have not validated.
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
    root._documentEpoch = root._statusLaunchEpoch
    root.runningCount = parsed.running
    root.errorCount = parsed.error
    root.total = parsed.total
    root.groups = parsed.groups
    root.connections = parsed.connections
    // Drop row overlays once Status shows the Connection is live again.
    root._clearActionErrorsForHealthyConnections(parsed.connections)
    // Healthy Status must not wipe doctor hard-fail *or* in-flight preflight.
    if (root._doctorOk === false) {
      root._setDegraded(
        "doctor_failed",
        root._doctorFailMessage !== ""
          ? root._doctorFailMessage
          : "cloud-sql-tracker doctor reported a failed check."
      )
      return
    }
    if (root._doctorPending || root._doctorWanted) {
      root._setDegraded("doctor_failed", "Checking setup…")
      return
    }
    root._clearDegraded()
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

  // Connection ids in scope for a target (for actionErrors attribution).
  function _idsForTarget(target) {
    var ids = []
    if (!target) return ids
    if (target.kind === "id" && target.id) {
      ids.push(String(target.id))
      return ids
    }
    var list = root.connections || []
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c || !c.id) continue
      if (target.kind === "all")
        ids.push(String(c.id))
      else if (target.kind === "group" && c.group === target.group)
        ids.push(String(c.id))
    }
    return ids
  }

  function _setActionErrorsForIds(ids, entry) {
    var next = {}
    for (var k in root.actionErrors) next[k] = root.actionErrors[k]
    for (var i = 0; i < ids.length; i++)
      next[ids[i]] = entry
    root.actionErrors = next
  }

  function _clearActionErrorsForIds(ids) {
    if (!ids || ids.length === 0) return
    var drop = {}
    for (var i = 0; i < ids.length; i++) drop[ids[i]] = true
    var next = {}
    var changed = false
    for (var k in root.actionErrors) {
      if (drop[k]) { changed = true; continue }
      next[k] = root.actionErrors[k]
    }
    if (changed) root.actionErrors = next
  }

  // Status truth wins: a running/starting row must not keep a stale start-fail
  // tooltip from a previous action (seams review PR #32).
  function _clearActionErrorsForHealthyConnections(connections) {
    if (!connections || connections.length === 0) return
    var ids = []
    for (var i = 0; i < connections.length; i++) {
      var c = connections[i]
      if (!c || !c.id) continue
      if (c.state === "running" || c.state === "starting")
        ids.push(String(c.id))
    }
    root._clearActionErrorsForIds(ids)
  }

  // ---- Internal: process launch ----------------------------------------------

  function _checkVersion() {
    if (versionProc.running) return
    _versionExited = false
    _versionProcGeneration = root._settingsGeneration
    versionProc.command = [root.cliPath, "--version"]
    versionProc.running = true
  }

  function _checkStatus() {
    // A poll asked for while one is in flight is *retried*, never dropped.
    // delayedRefresh is the only guaranteed post-action read, and silently
    // losing it left the panel on pre-action truth until the next tick.
    // Self-limiting: at most one retry is ever armed, and a status poll here
    // measures ~23ms against this 50ms retry.
    if (statusProc.running) { pendingStatus.restart(); return }
    _statusExited = false
    root._statusLaunchEpoch = root._actionEpoch
    statusProc.command = [root.cliPath, "status", "--json"]
    statusProc.running = true
  }

  function _checkDoctor() {
    if (doctorProc.running) return
    root._doctorPending = true
    if (root.degraded === null || root.degraded.kind === "doctor_failed")
      root._setDegraded("doctor_failed", "Checking setup…")
    _doctorExited = false
    _doctorProcGeneration = root._settingsGeneration
    doctorProc.command = [root.cliPath, "doctor", "--json"]
    doctorProc.running = true
  }

  function _runAction(verb, target) {
    if (actionProc.running) return
    if (!root._versionOk) {
      var gateMsg = "Cannot " + verb + " — version gate has not passed" +
        (root.degraded ? (" (" + root.degraded.kind + ").") : ".")
      console.warn("Tracker: " + gateMsg)
      // No connection scope without a validated CLI — nothing to pin on a row.
      root._actionEpoch++
      return
    }
    var args = _targetArgs(target)
    if (args === null) {
      console.warn("Tracker: invalid action target for " + verb + ":", JSON.stringify(target))
      root._actionEpoch++
      return
    }
    // Drop prior row errors for this scope when a new action is launched.
    root._clearActionErrorsForIds(root._idsForTarget(target))
    root.busyKey = _targetKey(target)
    root._pendingActionVerb = verb
    root._pendingActionTarget = target
    _actionExited = false
    actionProc.command = [root.cliPath, verb].concat(args)
    actionProc.running = true
  }

  // Verb / target of the in-flight or just-finished action (for actionErrors).
  property string _pendingActionVerb: ""
  property var _pendingActionTarget: null

  // Guards distinguishing "the process exited normally" (onExited fired)
  // from "the process never started" (Quickshell only emits runningChanged
  // in that case — the binary was not found, or was not executable). See
  // onRunningChanged on each Process below.
  property bool _versionExited: true
  property bool _statusExited: true
  property bool _actionExited: true
  property bool _doctorExited: true

  // Bumped by onSettingsChanged. _versionProcGeneration captures the value
  // at the moment a versionProc launch is kicked off, so its exit handlers
  // can tell a stale in-flight probe (started against a cliPath/
  // minCliVersion that settings has since replaced) from a current one, and
  // ignore the former instead of validating the new settings with an old
  // process's result.
  property int _settingsGeneration: 0
  property int _versionProcGeneration: -1
  // Same generation stamp as versionProc: a doctor launched against an old
  // cliPath must not apply after settings change (PR #32 seams).
  property int _doctorProcGeneration: -1

  function _missingCliMessage() {
    return "Could not run '" + root.cliPath + "'. Check the cliPath setting or your PATH."
  }

  // Prefer CLI stderr (often multi-line with a useful last line). Fall back to
  // stdout summary, then a generic exit-code line. Strip a leading "error: "
  // so the row tooltip is not "error: error: …".
  function _formatActionFailure(verb, exitCode, err, out) {
    var raw = err !== "" ? err : out
    var line = ""
    if (raw !== "") {
      var parts = raw.split("\n")
      for (var i = parts.length - 1; i >= 0; i--) {
        var t = String(parts[i] || "").trim()
        if (t !== "") { line = t; break }
      }
      if (line.indexOf("error: ") === 0) line = line.slice(7)
    }
    if (line === "")
      line = "'" + root.cliPath + " " + verb + "' exited with code " + exitCode + "."
    return line
  }

  // Summarize doctor --json hard failures for Degraded copy.
  function _doctorFailureMessage(report) {
    if (!report || typeof report !== "object")
      return "cloud-sql-tracker doctor failed."
    var checks = Array.isArray(report.checks) ? report.checks : []
    var failed = []
    for (var i = 0; i < checks.length; i++) {
      var c = checks[i]
      if (!c || c.status !== "fail") continue
      failed.push(c)
    }
    if (failed.length === 0)
      return "cloud-sql-tracker doctor reported a failed setup check."
    var first = failed[0]
    var id = first.id ? String(first.id) : "check"
    var detail = first.detail ? String(first.detail).trim() : ""
    var hint = first.hint ? String(first.hint).trim() : ""
    var msg = id + (detail !== "" ? (": " + detail) : " failed")
    if (hint !== "") msg = msg + " — " + hint
    if (failed.length > 1)
      msg = msg + " (+" + (failed.length - 1) + " more)"
    return msg
  }

  function _applyDoctorReport(text, exitCode) {
    root._doctorPending = false
    root._doctorWanted = false
    var raw = String(text || "").trim()
    var report = null
    if (raw !== "") {
      try {
        report = JSON.parse(raw)
      } catch (e) {
        report = null
      }
    }
    if (!report || typeof report !== "object") {
      var err = String(doctorStderr.text || "").trim()
      if (err.indexOf("error: ") === 0) err = err.slice(7)
      root._doctorOk = false
      root._doctorFailMessage = err !== ""
        ? err
        : ("doctor --json exited with code " + exitCode + ".")
      root._setDegraded("doctor_failed", root._doctorFailMessage)
      return
    }
    if (report.ok === true) {
      root._doctorOk = true
      root._doctorFailMessage = ""
      if (root.degraded !== null && root.degraded.kind === "doctor_failed")
        root._clearDegraded()
      return
    }
    root._doctorOk = false
    root._doctorFailMessage = root._doctorFailureMessage(report)
    root._setDegraded("doctor_failed", root._doctorFailMessage)
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

  // Re-runs a poll _checkStatus could not start because one was in flight.
  // Only _checkStatus's own bail path arms it, so exactly one retry is pending
  // at a time.
  Timer {
    id: pendingStatus
    interval: 50
    repeat: false
    onTriggered: root._checkStatus()
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
      if (root._versionProcGeneration !== root._settingsGeneration) {
        // Settings (cliPath/minCliVersion) changed while this probe was in
        // flight. Its result no longer applies — do not let a stale pass or
        // fail decide _versionOk/degraded for the *current* settings. The
        // next refresh() (poll tick or explicit call) starts a fresh probe.
        return
      }
      root.loaded = true
      if (exitCode !== 0) {
        var err = String(versionStderr.text || "").trim()
        root._doctorWanted = false
        root._doctorPending = false
        root._setDegraded("cli_missing", err !== "" ? err : ("'" + root.cliPath + " --version' exited with code " + exitCode + "."))
        return
      }
      var text = String(versionStdout.text || "").trim()
      if (!root._versionAtLeast(text, root.minCliVersion)) {
        root._doctorWanted = false
        root._doctorPending = false
        root._setDegraded("cli_old", "cloud-sql-tracker " + (text !== "" ? text : "(unknown)") + " is older than the required " + root.minCliVersion + ".")
        return
      }
      root._versionOk = true
      // Do not wait for the next poll tick to see the first Status document.
      root._checkStatus()
      // Doctor requested on panel open often races the version probe: runDoctor
      // sets _doctorWanted / _doctorPending while !_versionOk. Start doctor now
      // if the panel is open or a gated request is still pending.
      if (root.panelOpen || root._doctorWanted || root._doctorPending) {
        root._doctorWanted = false
        root._checkDoctor()
      }
    }
    onRunningChanged: {
      if (!running && !root._versionExited) {
        root._versionExited = true
        if (root._versionProcGeneration !== root._settingsGeneration) return
        root.loaded = true
        root._doctorWanted = false
        root._doctorPending = false
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
        var msg = err !== "" ? err : ("status --json exited with code " + exitCode + ".")
        if (msg.indexOf("error: ") === 0) msg = msg.slice(7)
        // Config load failures (invalid JSON, unknown keys, …) exit 2 with a
        // clear stderr line — still status_failed, not a separate kind, so
        // older panels keep working. The message is the operator signal.
        root._applyParsed({
          ok: false,
          degraded: {
            kind: "status_failed",
            message: msg
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
    id: doctorProc
    running: false
    command: []
    stdout: StdioCollector { id: doctorStdout; waitForEnd: true }
    stderr: StdioCollector { id: doctorStderr; waitForEnd: true }
    onExited: function (exitCode) {
      root._doctorExited = true
      if (root._doctorProcGeneration !== root._settingsGeneration) {
        // Settings (cliPath) changed while doctor was in flight — drop result.
        root._doctorPending = false
        return
      }
      // Doctor exits 3 when ok is false but still prints JSON — parse stdout
      // first. Non-JSON / empty stdout uses stderr or exit code.
      root._applyDoctorReport(String(doctorStdout.text || ""), exitCode)
    }
    onRunningChanged: {
      if (!running && !root._doctorExited) {
        root._doctorExited = true
        root._doctorPending = false
        root._doctorWanted = false
        if (root._doctorProcGeneration !== root._settingsGeneration)
          return
        root._doctorOk = false
        root._doctorFailMessage = root._missingCliMessage()
        root._setDegraded("doctor_failed", root._doctorFailMessage)
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
      root._actionEpoch++
      var verb = root._pendingActionVerb !== "" ? root._pendingActionVerb : "action"
      var target = root._pendingActionTarget
      var ids = root._idsForTarget(target)
      if (exitCode !== 0) {
        var out = String(actionStdout.text || "").trim()
        var err = String(actionStderr.text || "").trim()
        var msg = root._formatActionFailure(verb, exitCode, err, out)
        console.warn("Tracker: action exited with code " + exitCode + ":", msg)
        if (ids.length > 0) {
          root._setActionErrorsForIds(ids, {
            message: msg,
            verb: verb,
            exitCode: exitCode
          })
        }
      } else {
        root._clearActionErrorsForIds(ids)
      }
      delayedRefresh.restart()
    }
    onRunningChanged: {
      if (!running && !root._actionExited) {
        root._actionExited = true
        root.busyKey = ""
        root._actionEpoch++
        var verb = root._pendingActionVerb !== "" ? root._pendingActionVerb : "action"
        var target = root._pendingActionTarget
        var ids = root._idsForTarget(target)
        var msg = root._missingCliMessage()
        console.warn("Tracker: " + msg)
        if (ids.length > 0) {
          root._setActionErrorsForIds(ids, {
            message: msg,
            verb: verb,
            exitCode: -1
          })
        }
        delayedRefresh.restart()
      }
    }
  }
}
