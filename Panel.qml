import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Scaffold panel. Real UI will group connections and call:
//   cloud-sql-tracker status --json
//   cloud-sql-tracker start|stop <id|--group G|--all>
Panel {
  id: root
  moduleName: "io.github.golgor.cloud-sql-tracker"

  property var settings: ({})

  // Popout wiring filled in by BarWidget.injectPanel
  property var bar
  property var anchorItem
  property var hostWidget

  content: ColumnLayout {
    spacing: Style.space(2)

    StyledText {
      text: "Cloud SQL Tracker"
      font.bold: true
    }

    StyledText {
      Layout.maximumWidth: Style.space(80)
      wrapMode: Text.WordWrap
      text: "Scaffold only. Install and implement cloud-sql-tracker first, then wire status --json here. This plugin must not read connections.json directly."
      opacity: 0.8
    }
  }
}
