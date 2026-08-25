import QtQuick
import Quickshell
import Quickshell.Io
import CloudSqlTracker as Shared

// Minimal process seam harness. It imports the real Tracker through a named
// test qmldir and never instantiates Panel.qml, because the risk under test is
// Control plane output entering QML memory through Quickshell.Io.Process.
ShellRoot {
  id: root

  readonly property string caseName: Quickshell.env("CST_TEST_CASE") || "happy-status"
  readonly property string fakeCliPath: Quickshell.env("CST_FAKE_CLI") || ""
  readonly property int maxMs: parseInt(Quickshell.env("CST_TEST_MAX_MS") || "9000", 10)
  readonly property double startedAt: Date.now()

  property bool actionIssued: false
  property bool finished: false
  property string lastSnapshot: ""

  function emitMarker(eventName, fields) {
    var payload = { event: eventName, case: root.caseName }
    fields = fields || {}
    for (var k in fields) payload[k] = fields[k]
    console.log("CST_TEST " + JSON.stringify(payload))
  }

  function degradedKind() {
    return Shared.Tracker.degraded ? String(Shared.Tracker.degraded.kind || "") : ""
  }

  function degradedMessage() {
    return Shared.Tracker.degraded ? String(Shared.Tracker.degraded.message || "") : ""
  }

  function actionErrorKeys() {
    var keys = []
    var errors = Shared.Tracker.actionErrors || {}
    for (var k in errors) keys.push(k)
    keys.sort()
    return keys
  }

  function hasActionError(id) {
    var errors = Shared.Tracker.actionErrors || {}
    return Object.prototype.hasOwnProperty.call(errors, id)
  }

  function snapshot() {
    return {
      loaded: Shared.Tracker.loaded,
      total: Shared.Tracker.total,
      runningCount: Shared.Tracker.runningCount,
      errorCount: Shared.Tracker.errorCount,
      degradedKind: root.degradedKind(),
      degradedMessage: root.degradedMessage(),
      busyKey: Shared.Tracker.busyKey,
      preflightPending: Shared.Tracker.preflightPending,
      actionErrorKeys: root.actionErrorKeys()
    }
  }

  function logSnapshotIfChanged() {
    var current = JSON.stringify(root.snapshot())
    if (current === root.lastSnapshot) return
    root.lastSnapshot = current
    root.emitMarker("observed", JSON.parse(current))
  }

  function finish(success, reason, fields) {
    if (root.finished) return
    root.finished = true
    fields = fields || {}
    fields.reason = reason
    fields.elapsedMs = Math.round(Date.now() - root.startedAt)
    var snap = root.snapshot()
    for (var k in snap) fields[k] = snap[k]
    root.emitMarker(success ? "settled" : "fail", fields)
    terminateTimer.start()
  }

  function driveActionWhenReady() {
    if (root.actionIssued) return
    if (Shared.Tracker.total <= 0 || root.degradedKind() !== "") return
    root.actionIssued = true
    root.emitMarker("action-start", { target: "id:backend-dev", verb: "start" })
    Shared.Tracker.start({ kind: "id", id: "backend-dev" })
  }

  function checkSettled() {
    var kind = root.degradedKind()
    var message = root.degradedMessage()

    if (root.caseName === "happy-status") {
      if (Shared.Tracker.loaded && kind === "" && Shared.Tracker.total > 0)
        root.finish(true, "happy Status document accepted")
      return
    }

    if (root.caseName === "status-over-limit") {
      if (Shared.Tracker.loaded && kind !== "")
        root.finish(true, "oversized status stdout settled degraded", { acceptedKind: kind })
      return
    }

    if (root.caseName === "stderr-over-limit") {
      if (Shared.Tracker.loaded && kind !== "")
        root.finish(true, "oversized stderr settled degraded", { acceptedKind: kind })
      return
    }

    if (root.caseName === "hang-status") {
      if (kind === "status_failed" && message.indexOf("timed out") !== -1)
        root.finish(true, "status timeout settled")
      return
    }

    if (root.caseName === "hang-action") {
      root.driveActionWhenReady()
      if (root.actionIssued && Shared.Tracker.busyKey === "" && root.hasActionError("backend-dev"))
        root.finish(true, "action timeout settled with row error")
      return
    }

    if (root.caseName === "doctor-fail") {
      if (kind === "doctor_failed" && !Shared.Tracker.preflightPending)
        root.finish(true, "doctor hard-fail settled")
      return
    }

    if (root.caseName === "version-flood") {
      if (Shared.Tracker.loaded && kind !== "")
        root.finish(true, "oversized version stdout settled degraded", { acceptedKind: kind })
      return
    }

    root.finish(false, "unknown test case")
  }

  Component.onCompleted: {
    if (root.fakeCliPath === "") {
      root.emitMarker("fail", { reason: "CST_FAKE_CLI is required" })
      terminateTimer.start()
      return
    }

    Shared.Tracker.testDiagnosticsEnabled = true
    Shared.Tracker.settings = {
      cliPath: root.fakeCliPath,
      minCliVersion: "0.1.0",
      refreshIntervalSec: 60,
      refreshIntervalOpenSec: 60
    }

    root.emitMarker("case-start", {
      fakeCliPath: root.fakeCliPath,
      maxMs: root.maxMs
    })

    if (root.caseName === "doctor-fail")
      Shared.Tracker.runDoctor()
    else
      Shared.Tracker.refresh()
  }

  Connections {
    target: Shared.Tracker
    function onTestStreamBytes(procName, streamName, byteLength) {
      root.emitMarker("stream-bytes", {
        proc: procName,
        stream: streamName,
        bytes: byteLength
      })
    }
  }

  Timer {
    interval: 100
    repeat: true
    running: !root.finished
    onTriggered: {
      root.logSnapshotIfChanged()
      root.checkSettled()
      if (!root.finished && Date.now() - root.startedAt > root.maxMs)
        root.finish(false, "case timed out in QML harness")
    }
  }

  Timer {
    id: terminateTimer
    interval: 100
    repeat: false
    onTriggered: {
      root.emitMarker("terminator-start", {})
      terminator.running = true
    }
  }

  // Qt.quit() is not connected by quickshell. Terminate this throwaway harness
  // from a child process after the final CST_TEST marker has been printed. The
  // shell script still wraps quickshell in an outer timeout as a hard stop.
  Process {
    id: terminator
    running: false
    command: ["sh", "-c", "kill -TERM \"$PPID\""]
  }
}
