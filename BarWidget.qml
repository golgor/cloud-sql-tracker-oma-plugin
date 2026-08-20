import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Scaffold only — no CLI integration yet.
// Contract: poll `cloud-sql-tracker status --json`, never touch config files.
BarWidget {
  id: root
  moduleName: "io.github.golgor.cloud-sql-tracker"

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
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Placeholder until status polling lands: icon + count pattern.
    text: "☁ 0"
    tooltipText: "Cloud SQL Tracker (scaffold)"
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function (b) {
      if (b === Qt.LeftButton)
        root.toggle()
    }
  }
}
