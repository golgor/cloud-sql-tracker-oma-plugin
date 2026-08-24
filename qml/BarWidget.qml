import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
// Explicit, *namespaced* directory import (issue #54 review, round 2). Qt's
// bare same-directory implicit lookup resolves `Tracker` by filename only —
// it is a singleton "in the context of the module, but not in the context
// of the implicit import" (Qt qmldir semantics), so it does not honor
// qml/qmldir's `singleton` line on its own. An unqualified `import "."`
// forces qmldir-aware resolution too, but this file already sits *in* that
// same directory — round 2 review flagged that an unqualified self-import
// could still land on the implicit filename-based fallback in some Qt
// versions instead of the qmldir-aware one. Naming it (`as Shared`) removes
// the ambiguity: every reference below goes through `Shared.Tracker`
// explicitly, so there is no bare `Tracker` identifier left for any
// implicit resolution path to intercept.
import "." as Shared

// Bar chrome: icon + running count, warning affordance when Tracker reports
// a Connection error or is itself Degraded. All CLI I/O and Status
// document parsing live in Tracker — this file only binds to its view
// props and forwards panel plumbing. Contract: docs/DESIGN.md "Bar",
// docs/modules.md wiring diagram, CONTEXT.md ("Tracker", "Degraded").
BarWidget {
  id: root
  moduleName: "io.github.golgor.cloud-sql-tracker"

  // Exposes the shared Tracker singleton as `root.tracker`, the name
  // docs/modules.md's wiring diagram uses — not a locally-owned instance
  // (issue #54). Property *type* left as the plain `Tracker` name (still
  // resolvable for a type annotation via this directory's ordinary
  // implicit type visibility, which qmldir supplements rather than
  // replaces) so qmllint can still check member access on `root.tracker`;
  // the *value* comes from the namespaced `Shared.Tracker` so there is no
  // ambiguity about which resolution path supplies the actual singleton
  // instance. Not verified against a live qmllint in this container — if
  // the qualified type annotation `property Shared.Tracker` turns out to
  // be required instead, that is a one-line follow-up, not a behavior
  // change.
  readonly property Tracker tracker: Shared.Tracker

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

  // Issue #54 round 2: assign unconditionally, matching pre-#54 behavior.
  // A reference-identity guard was tried here and discarded — it can
  // suppress a REAL edit if the shell mutates the settings object in place
  // and re-emits the same reference (research: updateEntryInline), and it
  // may never even engage if the shell instead hands out a fresh wrapper
  // object on every read. Both are shell behaviors this plugin does not
  // control, so guarding on the *value* is wrong in both directions. The
  // actual guard now lives in Tracker.qml, gated on cliPath/minCliVersion
  // — the two raw values that gate probing — actually changing, using
  // QML's own content-based change notification on those `readonly
  // property string`s rather than object identity.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    Shared.Tracker.settings = root.settings
  }

  // Issue #54: Tracker is shared by every bar (one per monitor), so
  // settings/panelOpen/barVisible can no longer be plain bindings owned by
  // one widget instance. Each widget instead registers itself once and
  // reports its own state — see the aggregation rule on Tracker.qml's
  // panelOpen/barVisible.
  Component.onCompleted: {
    Shared.Tracker.settings = root.settings
    Shared.Tracker.registerViewer(root)
  }
  // `Shared.Tracker` guard: at full engine/shell teardown, object
  // destruction order between this widget and the singleton is not
  // guaranteed — without it, a widget destroyed after the singleton would
  // throw calling a method on a gone object, landing a TypeError in the
  // shell log on exit for something that changes nothing (the whole engine
  // is going away).
  Component.onDestruction: if (Shared.Tracker) Shared.Tracker.unregisterViewer(root)
  onOpenedChanged: Shared.Tracker.notifyViewerChanged(root)
  onBarVisibleChanged: Shared.Tracker.notifyViewerChanged(root)

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
