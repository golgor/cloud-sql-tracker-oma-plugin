pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Deep module: polls the cloud-sql-tracker CLI, gates on minimum version,
// runs doctor-on-open preflight, and runs start/stop. BarWidget and Panel
// bind to the view props below and call refresh() / runDoctor() / start() /
// stop() — they never touch Process, argv, or Model.js directly. Contract:
// docs/modules.md, docs/DESIGN.md, CONTEXT.md ("Tracker", "Degraded",
// "Action target"). Issue #31: doctor_failed + row-scoped actionErrors.
//
// Issue #54: one shared instance for every bar, not one per widget. A
// three-monitor desk used to run three Trackers polling the same question —
// the poll cost no longer grows with the monitor count. Callers get the
// shared instance through a namespaced directory import — see
// `import "." as Shared` / `Shared.Tracker` in BarWidget.qml — never
// `Tracker { ... }`.
//
// Singleton mechanism (issue #54 review — three parts, all required):
//   1. `pragma Singleton` above, in *this* file — the file qml/qmldir
//      names via `singleton Tracker 1.0 Tracker.qml`. Qt requires both:
//      qmldir alone leaves the type an ordinary creatable composite, so
//      `Tracker { ... }` would silently build a second instance instead of
//      erroring, and a bare `Tracker` reference falls through to whatever
//      QML happens to resolve first.
//   2. Root type `Singleton` (below), from `import Quickshell` — the type
//      quickshell-mirror/quickshell's own convention uses for reloadable
//      shell state (src/core/singleton.hpp: "All singletons should inherit
//      from this type"). `Singleton` extends `ReloadPropagator` extends
//      `Reloadable` extends `QObject` (src/core/reload.hpp) — not
//      QQuickItem — so it is a plain non-visual container, the same shape
//      as `QtObject`. Verified against that source that this is legal for
//      this file's children: `ReloadPropagator` declares
//      `Q_PROPERTY(QQmlListProperty<QObject> children READ data)` as its
//      `DefaultProperty`, i.e. it accepts *any* QObject-derived child, not
//      only visual Items — Timer, Process, and StdioCollector below are all
//      QObject-derived, and this file already has no visual properties
//      (anchors, width/height, visible, …) to lose by leaving `Item`.
//   3. Callers must reach this file through a real, *named* import, not the
//      bare same-directory implicit lookup and not even an unqualified
//      `import "."` — see BarWidget.qml's `import "." as Shared` and its
//      import comment for why round 2 review moved to a namespaced import.
// Not possible to prove end to end in this container (no live Quickshell
// or Omarchy shell here) — a multi-monitor smoke test per the issue's "How
// to check" is a merge precondition.
Singleton {
  id: root

  // ---- Config in ----------------------------------------------------------

  // Manifest defaults (see manifest.json barWidget.defaults): cliPath,
  // minCliVersion, refreshIntervalSec, refreshIntervalOpenSec.
  property var settings: ({})

  // Selects poll cadence (DESIGN.md "Poll: slower when closed, faster when
  // open") and gates pollTimer on the shell's barHidden state (issue #52).
  // With one shared Tracker and one bar widget per monitor (issue #54),
  // neither can be a plain externally-set property any more — two bars
  // disagreeing about "open" or "visible" would just have the
  // last-evaluated binding win, not an answer. The rule instead is "true
  // when ANY registered bar says true": panelOpen follows whichever
  // monitor's panel is actually open, and the poll only fully stops when
  // every bar is hidden. Each bar widget registers itself once
  // (registerViewer/unregisterViewer) and calls notifyViewerChanged()
  // whenever its own `opened` or `barVisible` changes; the aggregate below
  // is always recomputed from the registered instances themselves, so a
  // missed *notify* call cannot leave it stuck (a missed *unregister* is a
  // different failure — see notifyViewerChanged below).
  // Public facades: read-only to callers, matching docs/modules.md — the
  // only writers are _recomputeViewerAggregates below (issue #54 review).
  // See DESIGN.md "Doctor-on-open" for the barVisible-gates-the-poll-timer
  // rule this feeds (#52). panelOpen's own onPanelOpenChanged (near the
  // doctor state further down) reacts to the true->false edge — the last
  // open panel closing.
  readonly property bool panelOpen: root._anyOpen
  readonly property bool barVisible: root._anyVisible
  property bool _anyOpen: false
  property bool _anyVisible: true

  // Registered bar widget instances (BarWidget.qml objects), compared by
  // identity — a plain array of object references, not a map, so there are
  // no string keys and no Object.prototype collision to guard against (the
  // Object.create(null) maps elsewhere in this file are for CLI-controlled
  // string ids, a different problem).
  property var _viewers: []

  // Issue #54 review: an empty _viewers array means "nobody has ever
  // registered yet" (fail open, see _recomputeViewerAggregates) right up
  // until it means "every bar widget is gone" (fail closed) — this flag is
  // the difference. Set once, on the first registration, and never cleared:
  // a plugin that has run at least one bar widget this session does not go
  // back to "unknown".
  property bool _everRegistered: false

  function _viewerIndex(instance) {
    for (var i = 0; i < root._viewers.length; i++) {
      if (root._viewers[i] === instance) return i
    }
    return -1
  }

  // Called once by each bar widget on creation. Recomputes the aggregate
  // right away so a widget that registers already open/visible does not
  // wait for a later change to be counted.
  function registerViewer(instance) {
    if (!instance || root._viewerIndex(instance) !== -1) return
    root._everRegistered = true
    root._viewers = root._viewers.concat([instance])
    root._recomputeViewerAggregates()
  }

  // Called on bar widget destruction (screen unplugged, shell rescan, …) so
  // a gone widget cannot hold panelOpen/barVisible open forever.
  function unregisterViewer(instance) {
    var idx = root._viewerIndex(instance)
    if (idx === -1) return
    var next = root._viewers.slice()
    next.splice(idx, 1)
    root._viewers = next
    root._recomputeViewerAggregates()
  }

  // Called by a registered widget whenever its own `opened` or
  // `barVisible` changes. Reads the instance's current state fresh instead
  // of taking it as an argument, so the aggregate re-scans the registered
  // instances' own truth rather than accumulating a delta that a missed
  // *notify* call could leave stale. This does not cover a missed
  // *unregister*: a widget destroyed without Component.onDestruction firing
  // stays counted (and reading its properties may itself throw — see
  // Component.onDestruction below), same as any QML object whose teardown
  // signal never fires.
  function notifyViewerChanged(instance) {
    if (root._viewerIndex(instance) === -1) return
    root._recomputeViewerAggregates()
  }

  function _recomputeViewerAggregates() {
    var anyOpen = false
    var anyVisible = false
    for (var i = 0; i < root._viewers.length; i++) {
      var v = root._viewers[i]
      if (v.opened === true) anyOpen = true
      if (v.barVisible !== false) anyVisible = true
    }
    root._anyOpen = anyOpen
    // The doctor-session reset for "last open panel just closed" lives on
    // onPanelOpenChanged next to the rest of the doctor state (issue #54
    // round 4), not here — panelOpen's own facade binding already turns
    // this plain assignment into that edge with no extra bookkeeping.
    // Issue #54 review: two different reasons for an empty list need two
    // different answers. Nobody has ever registered (startup ordering) —
    // default to visible/polling, the same fail-open rule a single missing
    // barVisible reading already used (#52). Every widget that once existed
    // is now gone (plugin disabled on rescan, every screen unplugged) —
    // fail closed instead, or an orphaned singleton polls the CLI forever
    // with no reader for the count. registerViewer recomputes immediately
    // on the next widget's arrival, so this does not delay that widget's
    // first poll.
    root._anyVisible = !root._everRegistered ? true : anyVisible
  }

  readonly property string cliPath: _stringSetting("cliPath", "cloud-sql-tracker")
  readonly property string minCliVersion: _stringSetting("minCliVersion", "0.1.0")

  // manifest.json default. Used both as the version-gate fallback and the
  // value named in the fallback warning (issue #50).
  readonly property string _minCliVersionDefault: "0.1.0"

  // The value the version gate actually compares against (see
  // versionProc.onExited below) — `minCliVersion` above stays the literal,
  // content-gated setting value untouched, and this is a plain pure
  // binding derived from it, not a property written from inside
  // _onProbeInputsChanged (issue #50 merged onto #54's content-based
  // gating). A facade whose own value depended on the result of handling
  // its own change signal would reassign itself from inside
  // onMinCliVersionChanged and refire it — this has no such feedback path,
  // since nothing here ever writes back into `minCliVersion` or `settings`.
  readonly property string _effectiveMinCliVersion:
    _isWellFormedMinCliVersion(root.minCliVersion) ? root.minCliVersion : root._minCliVersionDefault

  readonly property int refreshIntervalSec: _intSetting("refreshIntervalSec", 5, 2, 60)
  readonly property int refreshIntervalOpenSec: _intSetting("refreshIntervalOpenSec", 2, 1, 30)

  // Issue #54 round 2: this used to be onSettingsChanged, firing the reset
  // below on every *reassignment* of the settings object -- but with N bar
  // widgets each writing `Shared.Tracker.settings = root.settings` (settings is
  // the same object for every instance, so every widget's write is
  // normally a no-op value), that fired once per widget for a single real
  // change, and once per widget on every widget's own onCompleted/settings
  // rebind even when nothing changed. A reference-identity guard on the
  // write side was tried and discarded (see BarWidget.qml) because it can
  // be wrong in both directions depending on how the shell hands out
  // settings objects.
  //
  // Pick: gate on cliPath/minCliVersion actually changing *value*, not on
  // settings being reassigned. These are already `readonly property
  // string`, so QML's own change notification is content-based (string
  // equality), not reference-based like the `var settings` it derives
  // from -- two reassignments that resolve to the same effective cliPath
  // (same string, whatever object or key shape produced it) already do not
  // re-fire onCliPathChanged/onMinCliVersionChanged, with no extra
  // bookkeeping needed here. Why: this is the exact "did the raw values
  // that gate probing actually change" question, answered by the value
  // types QML already tracks for us, comparing the *effective* (post
  // fallback) value rather than a raw last-seen cache that would need to
  // be kept in sync by hand. refreshIntervalSec/refreshIntervalOpenSec need
  // no such guard -- they are read reactively on every poll, nothing caches
  // them.
  function _onProbeInputsChanged() {
    _versionOk = false
    _settingsGeneration++
    // Next panel open should re-run doctor against the new cliPath.
    root._doctorOk = null
    root._doctorFailMessage = ""
    root._doctorWanted = false
    root._doctorPending = false
    // A retry armed under the old settings must not launch an ungated poll
    // against the new cliPath. The flag can straddle up to statusTimeout's
    // 3s (#45), unlike the old 50ms timer, so it needs the same reset the
    // doctor flags above already get.
    root._statusRetryWanted = false
    // issue #50, merged onto #54's content-based gating: warn once per
    // distinct malformed minCliVersion value. Deliberately just a warning,
    // not a rewrite of `minCliVersion` itself — see _effectiveMinCliVersion
    // below for why the gate's fallback lives in a separate, pure property
    // instead of here.
    root._maybeWarnMinCliVersionShape()
  }
  // cliPath and minCliVersion are the only two settings keys that gate
  // probing today. A future settings key that also gates probing (e.g. a
  // new CLI flag the version/doctor check must account for) needs its own
  // onXChanged handler here calling _onProbeInputsChanged() too — adding it
  // anywhere else would silently exempt it from the reset this file relies
  // on to re-probe.
  onCliPathChanged: root._onProbeInputsChanged()
  onMinCliVersionChanged: root._onProbeInputsChanged()

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
  //
  // Object.create(null): ids are CLI-controlled Connection ids (issue #44) —
  // a bare {} would let an id matching an Object.prototype member
  // ("constructor", "toString", ...) read as present, drop rows, or clear
  // the wrong row's error.
  property var actionErrors: Object.create(null)

  function clearActionError(id) {
    if (id === undefined || id === null || id === "") {
      root.actionErrors = Object.create(null)
      return
    }
    if (!Object.prototype.hasOwnProperty.call(root.actionErrors, id)) return
    var next = Object.create(null)
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
  // and also when one is *refused before launch* (actionProc never runs for
  // it), so a refused action still advances the counter and a consumer
  // holding state for it can let go rather than waiting forever on an action
  // that never ran. A refusal reachable only while actionProc is already
  // running (the lost shared-Tracker race, issue #72) must NOT bump here —
  // see the comment on that branch in _runAction.
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

  // True from doctor request until the preflight settles (report applied,
  // or the doctor Process never started). Panel reads this to keep the
  // keyboard cursor in place while the switchboard is hidden for "Checking
  // setup…" instead of resetting it (issue #38). Documented alias for the
  // internal _doctorPending flag below (issue #51) — the two always agree,
  // since this is a plain passthrough, not a second copy of the state.
  readonly property bool preflightPending: root._doctorPending

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
  // Private: callers read preflightPending above, never this.
  property bool _doctorPending: false

  // Issue #54 round 2/4: closing the last open panel ends this doctor
  // preflight "session" — reset _doctorOk so the *next* open re-runs
  // doctor instead of reusing this session's answer forever.
  // DESIGN.md/chrome.md/how-it-works.md/README.md all promise doctor runs
  // once per panel OPEN, not once per app lifetime: runDoctor()'s
  // `_doctorOk !== null` guard exists to stop a SECOND monitor's
  // concurrent open from re-running an already-settled check, not to pin a
  // stale pass or a transient failure (a doctorProc timeout on
  // resume-from-sleep, a momentary exec error) for the rest of the
  // session. onPanelOpenChanged only fires on a genuine value transition
  // (QML dedupes a bool write that does not change the value), so this
  // needs no hand-rolled "was it open before" local the way
  // _recomputeViewerAggregates once did — an already-closed bar's own
  // churn (barVisible flapping, or panelOpen never having been true) never
  // re-triggers this.
  onPanelOpenChanged: if (!root.panelOpen) root._endDoctorSession()

  function _endDoctorSession() {
    root._doctorOk = null
    root._doctorFailMessage = ""
    // Nobody is waiting on a deferred "run doctor once version passes"
    // request any more -- a future open calls runDoctor() again and
    // re-establishes it if still needed.
    root._doctorWanted = false
    if (doctorProc.running) {
      // A doctorProc launched for the session that just ended is still
      // running. Force its settle path onto the *existing* stale-
      // generation branch in doctorProc.onExited instead of letting it
      // write a fresh verdict for a session that no longer has a panel
      // open to show it — the same mechanism this file already uses to
      // invalidate an in-flight probe after a real settings change
      // (_onProbeInputsChanged bumps _settingsGeneration the same way).
      // This does not reopen the _doctorWanted wedge: this function
      // already cleared _doctorWanted, above, unconditionally, regardless
      // of whether doctorProc is running — the stale branch this settle
      // lands on only clears _doctorWanted itself when the settle reason
      // is a timeout or an overflow (issue #58), leaving it untouched on a
      // plain exit so a *newer* generation's own request (set after this
      // reset, by a fresh runDoctor()) can survive. _doctorPending is left
      // alone here: it is not wrong yet (a check genuinely is still
      // running), and the stale branch it lands on clears it once the
      // process actually settles.
      root._doctorProcGeneration = -1
    } else {
      // Nothing is running -- _doctorPending being true here would already
      // be wrong (there is no in-flight check left to explain it), so this
      // is the one place it is safe to force it false directly.
      root._doctorPending = false
    }
  }

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
  //
  // Issue #54: more than one Panel can call this now — one per monitor, all
  // sharing this Tracker. Two different calls both reach this guard and
  // must be told apart: a SECOND monitor's panel opening while a FIRST
  // monitor's panel is already open (and doctor has already settled for
  // it) must be a no-op — degraded is shared too, so without this guard a
  // second call re-flips the already-open panel's view to "Checking
  // setup…" (_setDegraded below writes the one shared property) and
  // relaunches doctor for a question already answered. A FRESH open — every
  // panel closed, then one reopens — must NOT be a no-op: DESIGN.md,
  // chrome.md, how-it-works.md, and README.md all promise doctor runs once
  // per panel *open*, and a settled result that outlives every panel
  // closing (a doctorProc timeout on resume-from-sleep, a momentary exec
  // failure) must not pin `doctor_failed` for the rest of the session.
  //
  // Pick: `_doctorOk !== null` here only suppresses a *concurrent*
  // duplicate open — _recomputeViewerAggregates() resets `_doctorOk` back
  // to null the moment the aggregate `panelOpen` transitions true->false
  // (every panel closed), so this guard's null check is false again by the
  // time any panel next opens, and that reopen runs a fresh doctor check.
  // Why: this keeps the guard doing exactly the one job the issue asked for
  // (stop a second monitor's open from redoing an in-progress or
  // just-settled answer) without also making a settled result outlive the
  // session that asked for it. Discarded: suppress forever until a settings
  // change (round 2's initial fix) — a failed doctor became terminal for
  // the whole session, silently contradicting all four "once per open"
  // docs. Discarded: retry a failed doctor on every reopen regardless of
  // whether another panel is still open — that is exactly the redundant
  // relaunch-and-clobber this guard exists to stop. Unchanged: a genuinely
  // new settings generation (cliPath, minCliVersion) still resets
  // `_doctorOk` to null on its own and gets a fresh run on the next open.
  function runDoctor() {
    if (root._doctorOk !== null) return
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

  // Trimmed before the empty check (issue #50 review): a whitespace-only
  // value must fall back to the manifest default like an actually-empty one,
  // not survive as a bare string of spaces. Applies to every string setting
  // — cliPath and minCliVersion both go through this — so a leading- or
  // trailing-space typo of the same value now behaves the same way, instead
  // of one being shape-refused and the other reaching a "missing CLI"
  // launch attempt. Trade-off, accepted: an absolute path with a genuine
  // trailing space (unusual on Linux, not impossible) is unreachable
  // through this setting.
  function _stringSetting(name, fallback) {
    var value = settings ? settings[name] : undefined
    if (value === undefined || value === null) return fallback
    var trimmed = String(value).trim()
    return trimmed === "" ? fallback : trimmed
  }

  function _intSetting(name, fallback, min, max) {
    var n = parseInt(String(settings ? settings[name] : undefined), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // minCliVersion contract (manifest.json): a plain major.minor.patch
  // version, matched end to end — not just a semver-looking prefix. A value
  // outside that shape ("latest", a stray word, trailing text) must not
  // block the widget forever by comparing against a required version
  // nothing can ever satisfy (issue #50). This check is deliberately
  // stricter than _versionParts()/_versionAtLeast() below, which stay
  // unanchored so a CLI-reported version with build metadata still gates —
  // that leniency is only ever meant for the CLI's own --version output,
  // never for this setting.
  function _isWellFormedMinCliVersion(value) {
    return value.length <= 32 && /^\d+\.\d+\.\d+$/.test(value)
  }

  // Warns once when the raw minCliVersion value does not match the
  // documented shape (issue #50). Called from _onProbeInputsChanged, which
  // fires on any content-based change to cliPath or minCliVersion — so this
  // also re-checks (and, via the memory below, does not re-warn) on a
  // cliPath-only change that leaves an already-bad minCliVersion untouched.
  // `root.minCliVersion` is already trimmed by _stringSetting above; no
  // further trim needed here.
  property var _minCliVersionLastWarnedRaw: null

  function _maybeWarnMinCliVersionShape() {
    if (root._isWellFormedMinCliVersion(root.minCliVersion)) {
      root._minCliVersionLastWarnedRaw = null
      return
    }
    if (root._minCliVersionLastWarnedRaw === root.minCliVersion) return
    root._minCliVersionLastWarnedRaw = root.minCliVersion
    console.warn("Tracker: minCliVersion setting '" + root.minCliVersion + "' is not a plain major.minor.patch version. Using the default " + root._minCliVersionDefault + ".")
  }

  // cliPath contract (README.md, AGENTS.md "CLI discovery: PATH or absolute
  // cliPath setting only"): the value is an absolute path, or a bare command
  // name with no directory component, resolved on PATH. A value carrying a
  // '/' that does not start at root (e.g. "./tracker", "sub/dir/tracker")
  // would run a binary relative to the working directory of the shell
  // process instead — issue #50. `value` is assumed already trimmed (it
  // comes from the `cliPath` property, which goes through _stringSetting).
  // Returns null when the shape is fine, or a message naming the problem.
  //
  // The message is prefixed "Setting error: " (issue #50 review): every
  // other Degraded state this plugin reports is a control-plane problem,
  // and chrome.md's cli_missing title is "cloud-sql-tracker not found" — a
  // false headline sitting over a setting mistake without that prefix.
  // Quoted with single quotes, like every other operator-facing string in
  // this file. The echoed value is capped so an oversized setting cannot
  // blow up the tooltip the way an unbounded CLI output could before the
  // #41 byte guard.
  function _cliPathShapeError(value) {
    if (value.length > 4096) return "Setting error: cliPath is longer than 4096 characters."
    if (value.charAt(0) === "/" || value.indexOf("/") === -1) return null
    var shown = value.length > 128 ? value.substring(0, 128) + "…" : value
    return "Setting error: cliPath '" + shown + "' is a relative path. Use an absolute path or a bare command name."
  }

  // Shared launch-site guard (issue #50 review): every function that builds
  // a Process.command from root.cliPath — _checkVersion, _checkStatus,
  // _checkDoctor, _runAction — calls this first and returns immediately
  // when it reports true. Centralizing both the check and its side effects
  // here, not just the check, means a shape-invalid cliPath can never reach
  // execvp through any of the four, present or future, without each call
  // site having to remember what settling on Degraded requires.
  function _bailOnCliPathShape() {
    var cliPathError = root._cliPathShapeError(root.cliPath)
    if (cliPathError === null) return false
    root.loaded = true
    root._versionOk = false
    root._doctorWanted = false
    root._doctorPending = false
    root._setDegraded("cli_missing", cliPathError)
    return true
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

  // BarWidget's tooltip (Bar.qml's tooltipLabel) is a shell-owned Text with
  // no reachable textFormat property, and it defaults to AutoText — so a raw
  // "<" in degraded.message could open a tag there (issue #43). "<" is the
  // only character AutoText markup needs to start, so replacing it closes
  // the outbound-fetch risk. Not "&lt;": the plain-text Panel sinks that
  // also read degraded.message would show the entities literally.
  function _noRawAngleBracket(text) {
    return String(text || "").replace(/</g, "\u2039")
  }

  function _setDegraded(kind, message) {
    root.degraded = { kind: kind, message: root._noRawAngleBracket(message) }
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

  // A target string starting with '-' looks like a CLI option, not data
  // (issue #49). One rule covers both fields: id and Group name are both
  // plain text, so the plugin must not parse them differently. The CLI now
  // refuses a hyphen-leading Group name at config load
  // (cloud-sql-tracker#85), so this agrees with the contract and stays as
  // defense in depth — an existing config saved before that fix can still
  // hold one.
  function _isHyphenLeading(value) {
    return String(value).charAt(0) === "-"
  }

  function _targetArgs(target) {
    if (!target) return null
    if (target.kind === "id" && target.id && !root._isHyphenLeading(target.id))
      return [String(target.id)]
    // Attached form: "--group=NAME" cannot misread a hyphen-leading value as
    // a separate option, because the value is never its own argv token
    // (evidence in issue #49). "--group NAME" and "--group=NAME" are the
    // same option in the CLI contract; only the spelling differs.
    if (target.kind === "group" && target.group && !root._isHyphenLeading(target.group))
      return ["--group=" + String(target.group)]
    if (target.kind === "all") return ["--all"]
    return null
  }

  // Names the refusal when _targetArgs returns null because id or Group
  // starts with '-'. Returns null for every other invalid-target case, so
  // callers keep the existing silent-refusal behavior there.
  function _hyphenRefusalMessage(verb, target) {
    if (!target) return null
    if (target.kind === "id" && target.id && root._isHyphenLeading(target.id))
      return "Cannot " + verb + " — the Connection id starts with '-'."
    if (target.kind === "group" && target.group && root._isHyphenLeading(target.group))
      return "Cannot " + verb + " — the Group name starts with '-'."
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
    var next = Object.create(null)
    for (var k in root.actionErrors) next[k] = root.actionErrors[k]
    for (var i = 0; i < ids.length; i++)
      next[ids[i]] = entry
    root.actionErrors = next
  }

  function _clearActionErrorsForIds(ids) {
    if (!ids || ids.length === 0) return
    // Object.create(null): drop is a membership set over CLI-controlled ids
    // (issue #44). A bare {} answers drop["toString"] truthily for an id
    // that was never added to `ids`, which dropped that row's real error on
    // an unrelated successful action.
    var drop = Object.create(null)
    for (var i = 0; i < ids.length; i++) drop[ids[i]] = true
    var next = Object.create(null)
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
    if (root._bailOnCliPathShape()) return
    _versionExited = false
    root._versionOverflow = ""
    root._versionTimeoutMsg = ""
    root._versionStdoutFresh = false
    root._versionStderrFresh = false
    _versionProcGeneration = root._settingsGeneration
    versionProc.command = [root.cliPath, "--version"]
    versionTimeout.restart()
    versionProc.running = true
  }

  function _checkStatus() {
    // Guard needed here specifically (not just at _checkVersion()):
    // _retryStatusIfWanted() calls this unconditionally (via Qt.callLater)
    // from statusProc's onRunningChanged, gated by neither _versionOk nor a
    // shape check — a settings edit landing mid-poll could otherwise launch
    // a shape-invalid cliPath, and a stray healthy document from whatever
    // that path resolves to would clear Degraded until the next tick.
    if (root._bailOnCliPathShape()) return
    // A poll asked for while one is in flight is *retried*, never dropped.
    // delayedRefresh is the only guaranteed post-action read, and silently
    // losing it left the panel on pre-action truth until the next tick.
    // The retry is a flag, read once statusProc actually stops (its
    // onRunningChanged below) — not a self-arming timer. A timer here
    // used to retrigger every 50ms with no stop condition while a poll
    // stayed stuck, waking the CPU at 20 Hz (#45).
    if (statusProc.running) { root._statusRetryWanted = true; return }
    _statusExited = false
    root._statusOverflow = ""
    root._statusTimeoutMsg = ""
    root._statusStdoutFresh = false
    root._statusStderrFresh = false
    root._statusLaunchEpoch = root._actionEpoch
    statusProc.command = [root.cliPath, "status", "--json"]
    statusTimeout.restart()
    statusProc.running = true
  }

  function _checkDoctor() {
    if (doctorProc.running) return
    if (root._bailOnCliPathShape()) return
    root._doctorPending = true
    if (root.degraded === null || root.degraded.kind === "doctor_failed")
      root._setDegraded("doctor_failed", "Checking setup…")
    _doctorExited = false
    root._doctorOverflow = ""
    root._doctorTimeoutMsg = ""
    root._doctorStdoutFresh = false
    root._doctorStderrFresh = false
    _doctorProcGeneration = root._settingsGeneration
    doctorProc.command = [root.cliPath, "doctor", "--json"]
    doctorTimeout.restart()
    doctorProc.running = true
  }

  function _runAction(verb, target) {
    if (actionProc.running) {
      // Same-frame race across two monitors sharing one Tracker (issue #54
      // made this reachable): the loser's click passed Panel's trackerBusy
      // guard before this action's actionProc.running flipped true. Refused,
      // not queued — write the loser's own row error, mirroring the
      // hyphen-refusal path (#49), instead of a silent knob snap-back.
      var busyMsg = "Cannot " + verb + " — another action is already running."
      console.warn("Tracker: " + busyMsg)
      var busyIds = root._idsForTarget(target)
      if (busyIds.length > 0) {
        root._setActionErrorsForIds(busyIds, {
          message: busyMsg,
          verb: verb,
          exitCode: -1
        })
      }
      // Same terminal-outcome contract as timeout/overflow/non-zero-exit and
      // the hyphen refusal below: a settled actionErrors write must not wait
      // for the next poll tick.
      delayedRefresh.restart()
      // Deliberately NOT root._actionEpoch++ here, unlike every other refusal
      // below. Those are all refused *before launch* (actionProc never runs
      // for them this call). This is the one refusal reachable only while the
      // winner's actionProc is already running — bumping here would inflate
      // the epoch mid-flight, before the winner's own exit/timeout bump. A
      // status poll launched in that window (still pre-exit) would then
      // stamp documentEpoch past the winner's captured intentEpoch, and
      // settleIntents would clear the WINNER's intent against pre-action
      // truth — the exact bounce this epoch machinery exists to prevent. The
      // loser does not need the bump either: settleIntents is gated on
      // trackerBusy, so the loser's own intent can only settle on the first
      // document observed after actionProc actually stops, and every path
      // that stops it (exit, timeout, never-started) already bumps the
      // epoch and restarts delayedRefresh for that.
      return
    }
    if (root._bailOnCliPathShape()) {
      // Refused, not launched — still advance actionEpoch so a caller
      // holding optimistic state for this action can let go (see
      // "Document provenance" above _actionEpoch's declaration).
      root._actionEpoch++
      return
    }
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
      var hyphenMsg = root._hyphenRefusalMessage(verb, target)
      if (hyphenMsg !== null) {
        console.warn("Tracker: " + hyphenMsg)
        var refusedIds = root._idsForTarget(target)
        if (refusedIds.length > 0) {
          root._setActionErrorsForIds(refusedIds, {
            message: hyphenMsg,
            verb: verb,
            exitCode: -1
          })
        }
        // Same terminal-outcome contract as timeout/overflow/non-zero-exit:
        // a settled actionErrors write must not wait for the next poll tick.
        delayedRefresh.restart()
      } else {
        console.warn("Tracker: invalid action target for " + verb + ":", JSON.stringify(target))
      }
      root._actionEpoch++
      return
    }
    // Drop prior row errors for this scope when a new action is launched.
    root._clearActionErrorsForIds(root._idsForTarget(target))
    root.busyKey = _targetKey(target)
    root._pendingActionVerb = verb
    root._pendingActionTarget = target
    _actionExited = false
    root._actionOverflow = ""
    root._actionTimeoutMsg = ""
    root._actionStdoutFresh = false
    root._actionStderrFresh = false
    actionProc.command = [root.cliPath, verb].concat(args)
    actionTimeout.restart()
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

  // Set by _checkStatus's bail path when a poll is requested while one is
  // already in flight. statusProc's onRunningChanged reads and clears this
  // flag, then polls once more — a flag, not a timer, so a stuck CLI cannot
  // turn the retry into an unbounded loop (#45).
  property bool _statusRetryWanted: false

  // A timeout handler sets this right before signal(9) + running = false.
  // "" means this run has not timed out.
  // onExited reads it, clears it, and owns every write for both a timeout
  // and a normal exit (issue #58).
  // A killed process still reports a crash exit (exitCode=9, CrashExit),
  // not a normal one. onExited prefers this recorded reason over the exit
  // code — see the "settle preference" comment on versionProc.onExited
  // below for the one full copy of that rule; the other three onExited
  // handlers just point back to it.
  // Cleared at launch too, not only at read time, in
  // _checkVersion/_checkStatus/_checkDoctor/_runAction. The overflow
  // fields below follow the same rule: a reason recorded for run N-1 must
  // never describe run N's result.
  property string _versionTimeoutMsg: ""
  property string _statusTimeoutMsg: ""
  property string _actionTimeoutMsg: ""
  property string _doctorTimeoutMsg: ""

  // Set by an onDataChanged byte guard on that process's stdout/stderr
  // StdioCollector, right before signal(9) + running = false, when the CLI's
  // output crosses this process's ceiling (#41). "" means no overflow.
  // Non-empty carries the message to report. The matching onExited reads it
  // first, reports the overflow as this process's failure instead of
  // parsing the (incomplete, killed-mid-stream) buffer, and clears it back
  // to "" so the next launch starts clean — same shape as the
  // _xxxTimeoutMsg fields above.
  //
  // An overflow and a timeout CAN both get set for the same run: running =
  // false is an async request, not an immediate state flip (see
  // versionTimeout's comment below), so an overflow landing right at the
  // timeout boundary and the timer firing moments later can both record
  // before either kill actually lands. This is harmless, not fixed: the
  // settle-preference block in onExited checks the timeout reason first,
  // so the overflow field is simply left set, unread, until the next
  // launch resets it — its gc() release is skipped for that one run, the
  // same as any other unread overflow.
  property string _versionOverflow: ""
  property string _statusOverflow: ""
  property string _doctorOverflow: ""
  property string _actionOverflow: ""

  // True once this run's collector has received at least one onDataChanged.
  // waitForEnd: false means StdioCollector only sets its `text` on data arrival
  // — streamEnded() never resets it — so a run that exits with empty output
  // would otherwise leave the *previous* run's text in the collector and
  // reuse stale data or failure messages. Reset to false in the matching
  // launch function; the settle paths in onExited must use "" when false (#41 followup).
  property bool _versionStdoutFresh: false
  property bool _versionStderrFresh: false
  property bool _statusStdoutFresh: false
  property bool _statusStderrFresh: false
  property bool _doctorStdoutFresh: false
  property bool _doctorStderrFresh: false
  property bool _actionStdoutFresh: false
  property bool _actionStderrFresh: false

  // Bumped by _onProbeInputsChanged (cliPath/minCliVersion actually
  // changing value). _versionProcGeneration captures the value
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

  // Reads and clears _statusRetryWanted, then polls once more. Called only
  // from statusProc's onRunningChanged(!running) — the one point Quickshell
  // guarantees `running` has actually settled to false, covering every exit
  // path including "process never started" (#45). Qt.callLater moves the
  // launch out of this signal handler. The flag, not Qt.callLater, is what
  // bounds this to one retry: it is cleared before the deferred call is
  // scheduled, so a duplicate call finds it false and does nothing. This
  // depends on `running = false` being an asynchronous request, not a
  // synchronous state flip (see versionTimeout's comment).
  function _retryStatusIfWanted() {
    if (root._statusRetryWanted) {
      root._statusRetryWanted = false
      Qt.callLater(root._checkStatus)
    }
  }

  // Safety helper to read StdioCollector output with a hard character cap.
  // maxLen is required — a default here is what let #42 truncate a valid
  // Status document into broken JSON. Memory growth from a flooding CLI is
  // bounded by an early collector guard in each StdioCollector's
  // onDataChanged below (#41): StdioCollector has already appended and
  // published the buffer before that guard runs, so the real ceiling is the
  // configured limit plus one QProcess read pass, not a hard producer cap.
  // This helper only trims strings a human reads (stderr lines, the version
  // string) to a sane display length.
  function _safeText(collector, maxLen) {
    if (!collector || typeof collector.text !== "string") return ""
    var text = collector.text
    return text.length > maxLen ? text.substring(0, maxLen) : text
  }

  function _freshText(collector, fresh, maxLen) {
    if (!fresh) return ""
    return _safeText(collector, maxLen)
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

  // A Doctor report is trustworthy only when it has the right shape
  // (doctor.v1.md: version 1, checks is an array). Issue #48: a report that
  // only carries "ok" must not read as a real result — the same fail-closed
  // rule issue #47 applies to the Status document.
  function _isWellFormedDoctorReport(report) {
    if (!report || typeof report !== "object") return false
    if (report.version !== 1) return false
    if (!Array.isArray(report.checks)) return false
    return true
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
    if (!root._isWellFormedDoctorReport(report)) {
      var err = String(root._freshText(doctorStderr, root._doctorStderrFresh, 2048) || "").trim()
      if (err.indexOf("error: ") === 0) err = err.slice(7)
      root._doctorOk = false
      root._doctorFailMessage = err !== ""
        ? err
        : ("doctor --json exited with code " + exitCode + ".")
      root._setDegraded("doctor_failed", root._doctorFailMessage)
      return
    }
    // cli-contract.v1.md: exit 0 means ok true (warns allowed); exit 3 means
    // ok false (a check failed). Issue #48: the exit code and "ok" must
    // agree. A CLI that prints ok:true but exits 3 (or the reverse) is a
    // broken control plane, not a healthy or a known-failed setup.
    if (exitCode === 0 && report.ok === true) {
      root._doctorOk = true
      root._doctorFailMessage = ""
      if (root.degraded !== null && root.degraded.kind === "doctor_failed")
        root._clearDegraded()
      return
    }
    if (exitCode === 3 && report.ok === false) {
      root._doctorOk = false
      root._doctorFailMessage = root._doctorFailureMessage(report)
      root._setDegraded("doctor_failed", root._doctorFailMessage)
      return
    }
    root._doctorOk = false
    root._doctorFailMessage = "doctor --json exit code " + exitCode + " does not match its \"ok\" field."
    root._setDegraded("doctor_failed", root._doctorFailMessage)
  }

  // ---- Timers ---------------------------------------------------------------

  Timer {
    id: pollTimer
    interval: (root.panelOpen ? root.refreshIntervalOpenSec : root.refreshIntervalSec) * 1000
    // Bar hidden AND panel closed → no new polls (#52); an open panel
    // still needs its 2s cadence even if the shell parks the bar
    // off-screen without closing it (rows must keep advancing). See
    // BarWidget.qml for why barVisible defaults true.
    running: root.barVisible || root.panelOpen
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

  // ---- Process execution timeouts ------------------------------------------

  Timer {
    id: versionTimeout
    interval: 3000
    repeat: false
    onTriggered: {
      if (versionProc.running) {
        console.warn("Tracker: versionProc timed out after 3s, terminating process")
        // Not written here: onExited already sets root._versionExited near
        // its own top, unconditionally, and the verified signal ordering
        // (exited always arrives before runningChanged(false), for a
        // process that was actually running) means onExited always runs
        // first. A write here would be redundant on every reachable
        // ordering. In the one case it would matter — SIGKILL cannot reap
        // this child — neither signal ever fires, so the write would not
        // help there either.
        // Record why; onExited owns the rest (issue #58) — it fires after
        // this kill and prefers this reason over the exit code (see the
        // settle-preference comment on onExited below).
        root._versionTimeoutMsg = "'" + root.cliPath + " --version' timed out after 3s."
        // We send SIGKILL: SIGTERM is trappable and a hung CLI must not
        // outlive its timeout. running = false is bookkeeping only — signal(9)
        // is what ends it.
        versionProc.signal(9)
        versionProc.running = false
      }
    }
  }

  Timer {
    id: statusTimeout
    interval: 3000
    repeat: false
    onTriggered: {
      if (statusProc.running) {
        console.warn("Tracker: statusProc timed out after 3s, terminating process")
        // Not written here — see versionTimeout's comment: onExited already
        // sets root._statusExited, and always runs first.
        // Record why; onExited owns the rest (issue #58).
        root._statusTimeoutMsg = "'status --json' timed out after 3s."
        statusProc.signal(9)   // SIGKILL: see versionTimeout
        statusProc.running = false
      }
    }
  }

  Timer {
    id: doctorTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      if (doctorProc.running) {
        console.warn("Tracker: doctorProc timed out after 5s, terminating process")
        // Not written here — see versionTimeout's comment: onExited already
        // sets root._doctorExited, and always runs first.
        // Record why; onExited owns the rest (issue #58). A timeout always
        // leaves _doctorWanted false there, unlike a plain stale exit — see
        // doctorProc.onExited's generation-stale branch.
        root._doctorTimeoutMsg = "'doctor --json' timed out after 5s."
        doctorProc.signal(9)   // SIGKILL: see versionTimeout
        doctorProc.running = false
      }
    }
  }

  Timer {
    id: actionTimeout
    interval: 15000
    repeat: false
    onTriggered: {
      if (actionProc.running) {
        console.warn("Tracker: actionProc timed out after 15s, terminating process")
        // Not written here — see versionTimeout's comment: onExited already
        // sets root._actionExited, and always runs first.
        //
        // Accepted residual: if SIGKILL cannot reap this child (stuck in an
        // uninterruptible kernel wait, for example), neither exited nor
        // runningChanged ever fires, and nothing settles until it does.
        // busyKey stays held for that whole time, so a click during it
        // lands on #72's "another action is already running" row error —
        // the honest signal for a process that is, in fact, still running.
        // No timer-side mitigation: issue #58 asks for exactly one settle
        // point, onExited, and this is the cost of that.
        //
        // Record why; onExited owns the rest (issue #58) — busyKey,
        // _actionEpoch, actionErrors, and delayedRefresh.
        var verb = root._pendingActionVerb !== "" ? root._pendingActionVerb : "action"
        root._actionTimeoutMsg = "'" + root.cliPath + " " + verb + "' timed out after 15s."
        actionProc.signal(9)   // SIGKILL: see versionTimeout
        actionProc.running = false
      }
    }
  }

  // ---- Processes (docs/modules.md "Process layout") -------------------------

  Process {
    id: versionProc
    running: false
    command: []
    // waitForEnd: false + an early collector guard on each StdioCollector's
    // onDataChanged bounds memory to the configured limit plus one QProcess
    // read pass (#41), rather than StdioCollector buffering unbounded.
    stdout: StdioCollector {
      id: versionStdout
      waitForEnd: false
      onDataChanged: {
        root._versionStdoutFresh = true
        if (root._versionOverflow === "" && data.byteLength > 65536) {
          root._versionOverflow = "'--version' produced more than 64 KB of output."
          versionProc.signal(9)   // SIGKILL: see versionTimeout
          versionProc.running = false
        }
      }
    }
    stderr: StdioCollector {
      id: versionStderr
      waitForEnd: false
      onDataChanged: {
        root._versionStderrFresh = true
        if (root._versionOverflow === "" && data.byteLength > 65536) {
          root._versionOverflow = "'--version' stderr produced more than 64 KB of output."
          versionProc.signal(9)   // SIGKILL: see versionTimeout
          versionProc.running = false
        }
      }
    }
    onExited: function (exitCode) {
      versionTimeout.stop()
      root._versionExited = true
      // Read and clear now — a reason recorded for this run must not
      // survive to describe a later one (issue #58).
      var timeoutMsg = root._versionTimeoutMsg
      root._versionTimeoutMsg = ""
      if (root._versionProcGeneration !== root._settingsGeneration) {
        // Settings (cliPath/minCliVersion) changed while this probe was in
        // flight. Its result no longer applies — do not let a stale pass or
        // fail decide _versionOk/degraded for the *current* settings. The
        // next refresh() (poll tick or explicit call) starts a fresh probe.
        root._versionOverflow = ""
        return
      }
      root.loaded = true
      // Settle preference (issue #58 — the one full copy of this rule; the
      // other three onExited handlers below point back here): a recorded
      // timeout reason wins over the exit code. The kill this run went
      // through reports as a crash exit (exitCode=9, CrashExit), not a
      // normal one, so checking the reason first is what stops a timed-out
      // run from reading as a generic non-zero exit.
      if (timeoutMsg !== "") {
        root._doctorWanted = false
        root._doctorPending = false
        root._setDegraded("cli_missing", timeoutMsg)
        return
      }
      if (root._versionOverflow !== "") {
        var overflowMsg = root._versionOverflow
        root._versionOverflow = ""
        // Release the ArrayBuffer generations pinned by the overflowed
        // read before this settles — hostile/broken overflow path only,
        // at most once per poll (#41 followup).
        gc()
        root._doctorWanted = false
        root._doctorPending = false
        root._setDegraded("cli_missing", overflowMsg)
        return
      }
      if (exitCode !== 0) {
        var err = String(root._freshText(versionStderr, root._versionStderrFresh, 2048) || "").trim()
        root._doctorWanted = false
        root._doctorPending = false
        root._setDegraded("cli_missing", err !== "" ? err : ("'" + root.cliPath + " --version' exited with code " + exitCode + "."))
        return
      }
      // Zero-byte run: onDataChanged never fired, so versionStdout.text is
      // still the *previous* run's text (waitForEnd: false never resets it
      // on streamEnded()). Treat it as empty so the gate fails as it did
      // before waitForEnd: false, instead of re-validating an old version.
      var text = root._versionStdoutFresh ? String(root._safeText(versionStdout, 2048) || "").trim() : ""
      // _effectiveMinCliVersion, not the raw minCliVersion setting (issue
      // #50): a malformed setting falls back to the manifest default here
      // instead of gating against a required version nothing can satisfy.
      if (!root._versionAtLeast(text, root._effectiveMinCliVersion)) {
        root._doctorWanted = false
        root._doctorPending = false
        root._setDegraded("cli_old", "cloud-sql-tracker " + (text !== "" ? text : "(unknown)") + " is older than the required " + root._effectiveMinCliVersion + ".")
        return
      }
      root._versionOk = true
      // Do not wait for the next poll tick to see the first Status document.
      root._checkStatus()
      // Doctor requested on panel open often races the version probe: runDoctor
      // sets _doctorWanted / _doctorPending while !_versionOk. Start doctor now
      // if the panel is open or a gated request is still pending.
      //
      // `_doctorOk === null` guard (issue #54): this path bypasses
      // runDoctor()'s own settled-generation guard, so without it a
      // transient version blip (CLI briefly unreachable, then found again)
      // would re-run an already-settled doctor and re-flip every open
      // panel's shared degraded view to "Checking setup…" for no reason —
      // the version gate flapping is not a reason to redo a preflight this
      // generation already answered.
      if ((root.panelOpen || root._doctorWanted || root._doctorPending) && root._doctorOk === null) {
        root._doctorWanted = false
        root._checkDoctor()
      }
    }
    onRunningChanged: {
      if (!running) versionTimeout.stop()
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
    // waitForEnd: false + an early collector guard on each StdioCollector's
    // onDataChanged bounds memory to the configured limit plus one QProcess
    // read pass (#41), rather than StdioCollector buffering unbounded.
    // The Status document is the largest thing this plugin parses, so its
    // ceiling (256 KB) is the highest of the four processes.
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: false
      onDataChanged: {
        root._statusStdoutFresh = true
        if (root._statusOverflow === "" && data.byteLength > 262144) {
          root._statusOverflow = "status --json produced more than 256 KB of output."
          statusProc.signal(9)   // SIGKILL: see versionTimeout
          statusProc.running = false
        }
      }
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: false
      onDataChanged: {
        root._statusStderrFresh = true
        if (root._statusOverflow === "" && data.byteLength > 65536) {
          root._statusOverflow = "status --json stderr produced more than 64 KB of output."
          statusProc.signal(9)   // SIGKILL: see versionTimeout
          statusProc.running = false
        }
      }
    }
    onExited: function (exitCode) {
      statusTimeout.stop()
      root._statusExited = true
      // Read and clear now — a reason recorded for this run must not
      // survive to describe a later one (issue #58).
      var timeoutMsg = root._statusTimeoutMsg
      root._statusTimeoutMsg = ""
      // Settle preference (issue #58) — see versionProc.onExited above for
      // the full rule.
      if (timeoutMsg !== "") {
        root._applyParsed({ ok: false, degraded: { kind: "status_failed", message: timeoutMsg } })
        return
      }
      if (root._statusOverflow !== "") {
        var overflowMsg = root._statusOverflow
        root._statusOverflow = ""
        // Release the ArrayBuffer generations pinned by the overflowed
        // read before this settles — hostile/broken overflow path only,
        // at most once per poll (#41 followup).
        gc()
        root._applyParsed({ ok: false, degraded: { kind: "status_failed", message: overflowMsg } })
        return
      }
      if (exitCode !== 0) {
        var err = String(root._freshText(statusStderr, root._statusStderrFresh, 2048) || "").trim()
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
      // No length cap here (#42) — a valid Status document must parse in
      // full. statusStdout's byte guard above is the only ceiling; once it
      // has not tripped, the whole buffer is fair game for Model.js. But a
      // zero-byte run never fired onDataChanged, so statusStdout.text would
      // still hold the *previous* run's text (waitForEnd: false never resets
      // it on streamEnded()) — feed "" instead so this settles Degraded like
      // any other empty document, not the stale one.
      root._applyParsed(Model.parseStatusDocument(root._statusStdoutFresh ? String(statusStdout.text || "") : ""))
      // No retry check here: statusProc.running still reads true at this
      // point (runningChanged(false) fires *after* exited — see
      // versionTimeout's comment above), so _checkStatus() would just bail
      // and re-set the flag. onRunningChanged below is the single point
      // where running has actually settled to false, and it is total: it
      // also covers the "process never started" exit, which never reaches
      // onExited at all.
    }
    onRunningChanged: {
      if (!running) statusTimeout.stop()
      if (!running && !root._statusExited) {
        root._statusExited = true
        root.loaded = true
        // The binary was reachable for --version but is gone now (removed,
        // PATH changed mid-session, …) — re-probe from the version gate
        // rather than assuming the earlier pass still holds.
        root._versionOk = false
        root._setDegraded("cli_missing", root._missingCliMessage())
      }
      if (!running) root._retryStatusIfWanted()
    }
  }

  Process {
    id: doctorProc
    running: false
    command: []
    // waitForEnd: false + an early collector guard on each StdioCollector's
    // onDataChanged bounds memory to the configured limit plus one QProcess
    // read pass (#41), rather than StdioCollector buffering unbounded.
    stdout: StdioCollector {
      id: doctorStdout
      waitForEnd: false
      onDataChanged: {
        root._doctorStdoutFresh = true
        if (root._doctorOverflow === "" && data.byteLength > 65536) {
          root._doctorOverflow = "doctor --json produced more than 64 KB of output."
          doctorProc.signal(9)   // SIGKILL: see versionTimeout
          doctorProc.running = false
        }
      }
    }
    stderr: StdioCollector {
      id: doctorStderr
      waitForEnd: false
      onDataChanged: {
        root._doctorStderrFresh = true
        if (root._doctorOverflow === "" && data.byteLength > 65536) {
          root._doctorOverflow = "doctor --json stderr produced more than 64 KB of output."
          doctorProc.signal(9)   // SIGKILL: see versionTimeout
          doctorProc.running = false
        }
      }
    }
    onExited: function (exitCode) {
      doctorTimeout.stop()
      root._doctorExited = true
      // Read and clear now — a reason recorded for this run must not
      // survive to describe a later one (issue #58).
      var timeoutMsg = root._doctorTimeoutMsg
      root._doctorTimeoutMsg = ""
      if (root._doctorProcGeneration !== root._settingsGeneration) {
        // Settings (cliPath) changed while doctor was in flight — drop this
        // generation's result. A newer generation's own doctor call decides
        // _doctorOk and _doctorWanted for itself from here.
        var staleOverflowMsg = root._doctorOverflow
        root._doctorOverflow = ""
        root._doctorPending = false
        // Issue #58 review: only a timeout or an overflow is a definite,
        // self-contained failure for this generation, so only those two
        // clear _doctorWanted here (the #54 round 2 rule — a settled
        // failure must not leave _doctorWanted stranded true). A plain
        // stale exit proves nothing about this generation and must leave
        // _doctorWanted untouched: a *newer* generation's runDoctor() may
        // have set it while this old probe was still in flight (the
        // first-open race, issue #31), relying on it to survive so the
        // version-gate success path can launch that generation's doctor
        // check once doctorProc frees up. Clearing it unconditionally here
        // would drop that request on the floor.
        if (timeoutMsg !== "" || staleOverflowMsg !== "") root._doctorWanted = false
        return
      }
      // Settle preference (issue #58) — see versionProc.onExited above for
      // the full rule.
      if (timeoutMsg !== "") {
        root._doctorPending = false
        root._doctorWanted = false
        root._doctorOk = false
        root._doctorFailMessage = timeoutMsg
        root._setDegraded("doctor_failed", timeoutMsg)
        return
      }
      if (root._doctorOverflow !== "") {
        var overflowMsg = root._doctorOverflow
        root._doctorOverflow = ""
        // Release the ArrayBuffer generations pinned by the overflowed
        // read before this settles — hostile/broken overflow path only,
        // at most once per poll (#41 followup).
        gc()
        root._doctorPending = false
        // Issue #54 round 2: same lifecycle rule as doctorTimeout above —
        // every path that settles _doctorOk must also leave _doctorWanted
        // false.
        root._doctorWanted = false
        root._doctorOk = false
        root._doctorFailMessage = overflowMsg
        root._setDegraded("doctor_failed", overflowMsg)
        return
      }
      // Doctor exits 3 when ok is false but still prints JSON — parse stdout
      // first. Non-JSON / empty stdout uses stderr or exit code. No length
      // cap here (#42) — same reasoning as statusStdout above. A zero-byte
      // run never fired onDataChanged, so doctorStdout.text would still hold
      // the *previous* run's text (waitForEnd: false never resets it on
      // streamEnded()) — feed "" instead so _applyDoctorReport's existing
      // empty-stdout handling applies, not a stale success/failure.
      root._applyDoctorReport(root._doctorStdoutFresh ? String(doctorStdout.text || "") : "", exitCode)
    }
    onRunningChanged: {
      if (!running) doctorTimeout.stop()
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
    // waitForEnd: false + an early collector guard on each StdioCollector's
    // onDataChanged bounds memory to the configured limit plus one QProcess
    // read pass (#41), rather than StdioCollector buffering unbounded.
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: false
      onDataChanged: {
        root._actionStdoutFresh = true
        if (root._actionOverflow === "" && data.byteLength > 65536) {
          root._actionOverflow = "'" + (root._pendingActionVerb !== "" ? root._pendingActionVerb : "action") + "' produced more than 64 KB of output."
          actionProc.signal(9)   // SIGKILL: see versionTimeout
          actionProc.running = false
        }
      }
    }
    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: false
      onDataChanged: {
        root._actionStderrFresh = true
        if (root._actionOverflow === "" && data.byteLength > 65536) {
          root._actionOverflow = "'" + (root._pendingActionVerb !== "" ? root._pendingActionVerb : "action") + "' stderr produced more than 64 KB of output."
          actionProc.signal(9)   // SIGKILL: see versionTimeout
          actionProc.running = false
        }
      }
    }
    onExited: function (exitCode) {
      actionTimeout.stop()
      root._actionExited = true
      // Read and clear now — a reason recorded for this run must not
      // survive to describe a later one (issue #58).
      var timeoutMsg = root._actionTimeoutMsg
      root._actionTimeoutMsg = ""
      root.busyKey = ""
      root._actionEpoch++
      var verb = root._pendingActionVerb !== "" ? root._pendingActionVerb : "action"
      var target = root._pendingActionTarget
      var ids = root._idsForTarget(target)
      // Settle preference (issue #58) — see versionProc.onExited above for
      // the full rule.
      if (timeoutMsg !== "") {
        if (ids.length > 0) {
          root._setActionErrorsForIds(ids, {
            message: timeoutMsg,
            verb: verb,
            exitCode: -1
          })
        }
        delayedRefresh.restart()
        return
      }
      // start/stop have no global Degraded state — an overflow here is a row
      // failure like any other action failure (actionErrors), not a Tracker
      // degraded kind.
      if (root._actionOverflow !== "") {
        var overflowMsg = root._actionOverflow
        root._actionOverflow = ""
        // Release the ArrayBuffer generations pinned by the overflowed
        // read before this settles — hostile/broken overflow path only,
        // at most once per poll (#41 followup).
        gc()
        console.warn("Tracker: " + overflowMsg)
        if (ids.length > 0) {
          root._setActionErrorsForIds(ids, {
            message: overflowMsg,
            verb: verb,
            exitCode: -1
          })
        }
        delayedRefresh.restart()
        return
      }
      if (exitCode !== 0) {
        var out = String(root._freshText(actionStdout, root._actionStdoutFresh, 2048) || "").trim()
        var err = String(root._freshText(actionStderr, root._actionStderrFresh, 2048) || "").trim()
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
      if (!running) actionTimeout.stop()
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
