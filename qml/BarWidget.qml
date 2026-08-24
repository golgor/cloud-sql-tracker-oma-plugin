import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
// Explicit directory import (issue #54 review): Qt's bare same-directory
// implicit lookup resolves `Tracker` by filename only — it is a singleton
// "in the context of the module, but not in the context of the implicit
// import" (Qt qmldir semantics), so it does not honor qml/qmldir's
// `singleton` line on its own. This import forces the qmldir-aware
// resolution that actually returns the shared instance.
import "."

// Bar chrome: icon + running count, warning affordance when Tracker reports
// a Connection error or is itself Degraded. All CLI I/O and Status
// document parsing live in Tracker — this file only binds to its view
// props and forwards panel plumbing. Contract: docs/DESIGN.md "Bar",
// docs/modules.md wiring diagram, CONTEXT.md ("Tracker", "Degraded").
BarWidget {
  id: root
  moduleName: "io.github.golgor.cloud-sql-tracker"

  // Exposes the shared Tracker singleton as `root.tracker`, the name
  // docs/modules.md's wiring diagram uses. `Tracker` here is the bare
  // singleton identifier (qml/qmldir + the explicit `import "."` above),
  // not a locally-owned instance — issue #54. Typed (not `var`) now that
  // the explicit import puts `Tracker` in typed scope, so qmllint can still
  // check member access on `root.tracker` the way it did against the old
  // per-instance child.
  readonly property Tracker tracker: Tracker

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // `omarchy-toggle-bar` parks the bar off-screen instead of unmapping it
  // (Bar.qml), so nothing stops this widget's poll on its own (#52).
  // `barHidden` is shell-owned state, not a documented plugin contract —
  // default to visible (poll) when `bar` or the property is missing, so a
  // shell rename fails toward the pre-#52 always-on behavior instead of
  // freezing the bar's count.
  readonly property bool barVisible: !(root.bar && root.bar.barHidden === true)

  function open() {
    if (panelLoader.item)
      panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item)
      panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item)
      panelLoader.item.toggle()
  }

  function injectPanel() {
    if (!panelLoader.item)
      return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.settings = root.settings
    panelLoader.item.tracker = root.tracker
  }

  // Issue #54 review: every bar widget assigns this on the same object
  // (allowMultiple: false, one config for the plugin), so a second or
  // third widget's write is normally a no-op value — but a plain `var`
  // write signals unconditionally regardless of whether the value actually
  // changed. Unguarded, a widget created mid-session (monitor hotplug)
  // would bump Tracker's _settingsGeneration purely by re-asserting the
  // same settings object, resetting _versionOk and refusing the next
  // start/stop until it re-probes. The reference check makes a same-object
  // reassignment a true no-op.
  function _syncTrackerSettings() {
    if (Tracker.settings !== root.settings)
      Tracker.settings = root.settings
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    root._syncTrackerSettings()
  }

  // Issue #54: Tracker is shared by every bar (one per monitor), so
  // settings/panelOpen/barVisible can no longer be plain bindings owned by
  // one widget instance. Each widget instead registers itself once and
  // reports its own state — see the aggregation rule on Tracker.qml's
  // panelOpen/barVisible.
  Component.onCompleted: {
    root._syncTrackerSettings()
    Tracker.registerViewer(root)
  }
  // `Tracker` guard: at full engine/shell teardown, object destruction
  // order between this widget and the singleton is not guaranteed — without
  // it, a widget destroyed after the singleton would throw calling a method
  // on a gone object, landing a TypeError in the shell log on exit for
  // something that changes nothing (the whole engine is going away).
  Component.onDestruction: if (Tracker) Tracker.unregisterViewer(root)
  onOpenedChanged: Tracker.notifyViewerChanged(root)
  onBarVisibleChanged: Tracker.notifyViewerChanged(root)

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Degraded message when Tracker cannot be trusted, else a short summary —
  // DESIGN.md "Bar": "Tooltip: short summary (e.g. running/total, or
  // degraded message)".
  readonly property string _tooltipText: root.tracker.degraded !== null
    ? root.tracker.degraded.message
    : (root.tracker.runningCount + "/" + root.tracker.total + " running"
        + (root.tracker.errorCount > 0 ? " · " + root.tracker.errorCount + " error" : ""))

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Icon + running count, per DESIGN.md "Bar". `active` drives this
    // codebase's existing warning affordance (activeColor → bar.urgent,
    // e.g. Microphone.qml's "in use" highlight) — no separate glyph needed.
    //
    // The glyph is nf-md-cloud (U+F015F), written as a literal character.
    // It must come from the Nerd Font MDI range, which is the family
    // `fc-match monospace` resolves to and therefore the family drawing the
    // count beside it: the previous ☁ (U+2601) is outside that range and
    // resolved to Noto Sans CJK JP here — a different family from its own
    // count, and tofu on any machine without Noto CJK. docs/chrome.md §8.
    text: "󰅟 " + root.tracker.runningCount
    active: root.tracker.degraded !== null || root.tracker.errorCount > 0
    tooltipText: root._tooltipText
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function (b) {
      if (b === Qt.LeftButton)
        root.toggle()
    }
  }
}
