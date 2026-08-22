import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar chrome: icon + running count, warning affordance when Tracker reports
// a Connection error or is itself Degraded. All CLI I/O and Status
// document parsing live in Tracker — this file only binds to its view
// props and forwards panel plumbing. Contract: docs/DESIGN.md "Bar",
// docs/modules.md wiring diagram, CONTEXT.md ("Tracker", "Degraded").
BarWidget {
  id: root
  moduleName: "io.github.golgor.cloud-sql-tracker"

  // Exposes the Tracker instance below as `root.tracker`, the name
  // docs/modules.md's wiring diagram uses, without colliding with the
  // child item's own id.
  property alias tracker: trackerImpl

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // One Tracker per widget instance (docs/modules.md: no shared/service
  // poll in v1). panelOpen selects the faster poll interval while the
  // dropdown is open (DESIGN.md "Poll: slower when closed, faster when
  // open").
  Tracker {
    id: trackerImpl
    settings: root.settings
    panelOpen: root.opened
  }

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
