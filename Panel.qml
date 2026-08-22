import QtQuick
import qs.Commons
import qs.Ui

// Grouped list — the locked v1 chrome (docs/DESIGN.md "Panel — Grouped
// list"). Binds to Tracker only: no Process, no argv, no connections.json
// I/O. Group and connection order come straight from Tracker, which
// mirrors the Status document's own config order.
//
// Nested under BarWidget (docs/modules.md "Nested" host shape), same as
// weather/clock — the bar widget (hostWidget), not this Item, is what the
// popout coordinator and KeyboardPanel identify the panel by.
Panel {
  id: root
  moduleName: "io.github.golgor.cloud-sql-tracker"

  // settings/bar are already declared on the base Panel (qs.Ui) — do not
  // redeclare them here (would shadow the base property qmllint warns
  // about; weather's own nested panel relies on the inherited ones the
  // same way). Only anchorItem/hostWidget/tracker are this panel's own,
  // set by BarWidget.injectPanel.
  property var anchorItem
  property var hostWidget

  // The Tracker instance owned by BarWidget (docs/modules.md wiring:
  // "panel.tracker = root.tracker").
  property var tracker

  readonly property var barIdentity: hostWidget || root

  // Base Panel.switchPanel() passes itself (this nested Item) as the
  // popout identity, but the KeyboardPanel below registers under
  // barIdentity (the hostWidget) for this "Nested" host shape
  // (docs/modules.md) — same mismatch weather's Panel.qml overrides this
  // for, and for the same reason: Tab-to-switch must look up the sibling
  // widget under the identity it was actually registered under.
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  readonly property var degraded: tracker ? tracker.degraded : null
  readonly property int total: tracker ? tracker.total : 0
  readonly property var groupList: tracker ? tracker.groups : []
  readonly property var connectionList: tracker ? tracker.connections : []
  readonly property bool trackerBusy: tracker ? tracker.busy : false
  readonly property string busyKey: tracker ? tracker.busyKey : ""

  // Refresh right away on open rather than waiting for Tracker's next poll
  // tick: the poll interval only shortens for *future* ticks
  // (docs/modules.md "Poll interval from settings; faster when
  // panelOpen") — it does not restart a countdown already in flight.
  onOpenedChanged: if (opened && root.tracker) root.tracker.refresh()

  function connectionsForGroup(name) {
    var list = []
    for (var i = 0; i < connectionList.length; i++) {
      if (connectionList[i].group === name) list.push(connectionList[i])
    }
    return list
  }

  function busyForKey(key) {
    return trackerBusy && busyKey === key
  }

  function canStart(state) {
    return state === "stopped" || state === "error"
  }

  // Health state color/affordance (CONTEXT.md "Health state"). This theme
  // kit has no bespoke green/red tokens, so the four states map onto the
  // palette's existing roles: foreground for the healthy state, accent for
  // in-progress, urgent for error, muted for the inactive/off state.
  function healthColor(state) {
    if (state === "running") return Color.foreground
    if (state === "starting") return Color.accent
    if (state === "error") return Color.urgent
    return Color.muted
  }

  function healthLabel(state) {
    if (state === "running") return "RUNNING"
    if (state === "starting") return "STARTING"
    if (state === "error") return "ERROR"
    return "STOPPED"
  }

  // One-line intent per Degraded kind (CONTEXT.md "Degraded";
  // docs/DESIGN.md "Degraded and empty"). The full message underneath
  // comes from Tracker.degraded.message.
  function degradedTitle(kind) {
    if (kind === "cli_missing") return "cloud-sql-tracker not found"
    if (kind === "cli_old") return "cloud-sql-tracker is too old"
    if (kind === "schema") return "Status document not understood"
    if (kind === "status_failed") return "Status check failed"
    return "cloud-sql-tracker unavailable"
  }

  function stopAll() {
    if (root.tracker) root.tracker.stop({ kind: "all" })
  }

  function startGroup(name) {
    if (root.tracker) root.tracker.start({ kind: "group", group: name })
  }

  function stopGroup(name) {
    if (root.tracker) root.tracker.stop({ kind: "group", group: name })
  }

  function toggleConnection(conn) {
    if (!root.tracker) return
    if (root.canStart(conn.state)) root.tracker.start({ kind: "id", id: conn.id })
    else root.tracker.stop({ kind: "id", id: conn.id })
  }

  KeyboardPanel {
    id: keyboardPanel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: keyboardPanel.fittedContentWidth(Style.space(340))
    contentHeight: keyboardPanel.fittedContentHeight(column.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        id: scrollArea
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scrollArea.width
          spacing: Style.space(14)

          // ---------- Header: title + stop all ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(titleLabel.implicitHeight, stopAllButton.implicitHeight)

            Text {
              id: titleLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Cloud SQL Tracker"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Button {
              id: stopAllButton
              visible: root.degraded === null && root.total > 0
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Stop all"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.busyForKey("all")
              opacity: enabled ? 1.0 : 0.55
              iconText: root.busyForKey("all") ? "󰦖" : ""
              iconSpinning: root.busyForKey("all")
              onClicked: root.stopAll()
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          // ---------- Degraded: replaces the switchboard entirely ----------
          // Not the same as a Connection's Health state "error" — this
          // means the plugin cannot trust the control plane at all
          // (docs/DESIGN.md "Degraded and empty").
          Column {
            visible: root.degraded !== null
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.degraded ? root.degradedTitle(root.degraded.kind) : ""
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: root.degraded ? root.degraded.message : ""
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Empty: no Connections configured ----------
          Column {
            visible: root.degraded === null && root.total === 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: "No connections configured."
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            // Path as text only — this plugin never reads or writes the
            // CLI-owned config file (docs/DESIGN.md, CONTEXT.md).
            Text {
              width: parent.width
              text: "Add connections with the CLI's config file: ~/.config/cloud-sql-tracker/connections.json"
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Groups ----------
          // Guarded on degraded === null so a stale-but-known document
          // (Tracker keeps the last good view while degraded, see
          // Tracker.qml _setDegraded) never renders underneath the
          // degraded message above.
          Repeater {
            model: root.degraded === null ? root.groupList : []

            delegate: Column {
              id: groupSection
              required property var modelData
              width: column.width
              spacing: Style.space(8)

              // ---- Group header: name, counts, group actions ----
              Item {
                width: parent.width
                implicitHeight: Math.max(groupHeaderColumn.implicitHeight, groupActions.implicitHeight)

                Column {
                  id: groupHeaderColumn
                  anchors.left: parent.left
                  anchors.right: groupActions.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  PanelSectionHeader {
                    text: groupSection.modelData.name.toUpperCase()
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                  }

                  Text {
                    text: groupSection.modelData.running + "/" + groupSection.modelData.total + " running"
                      + (groupSection.modelData.error > 0 ? "  ·  " + groupSection.modelData.error + " error" : "")
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  id: groupActions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Button {
                    text: "Start group"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    bordered: true
                    enabled: !root.busyForKey("group:" + groupSection.modelData.name)
                    opacity: enabled ? 1.0 : 0.55
                    iconText: root.busyForKey("group:" + groupSection.modelData.name) ? "󰦖" : ""
                    iconSpinning: root.busyForKey("group:" + groupSection.modelData.name)
                    onClicked: root.startGroup(groupSection.modelData.name)
                  }

                  Button {
                    text: "Stop group"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    bordered: true
                    enabled: !root.busyForKey("group:" + groupSection.modelData.name)
                    opacity: enabled ? 1.0 : 0.55
                    iconText: root.busyForKey("group:" + groupSection.modelData.name) ? "󰦖" : ""
                    iconSpinning: root.busyForKey("group:" + groupSection.modelData.name)
                    onClicked: root.stopGroup(groupSection.modelData.name)
                  }
                }
              }

              // ---- Connection rows ----
              Repeater {
                model: root.connectionsForGroup(groupSection.modelData.name)

                delegate: Item {
                  id: connectionRow
                  required property var modelData
                  width: groupSection.width
                  implicitHeight: Math.max(connectionInfo.implicitHeight, toggleButton.implicitHeight) + Style.space(4)

                  Column {
                    id: connectionInfo
                    anchors.left: parent.left
                    anchors.right: toggleButton.left
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    // Display name, not id — docs/DESIGN.md "Display name
                    // (not id as primary label)".
                    Text {
                      width: parent.width
                      text: connectionRow.modelData.name
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Row {
                      spacing: Style.space(8)

                      Text {
                        text: root.healthLabel(connectionRow.modelData.state)
                        color: root.healthColor(connectionRow.modelData.state)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 1
                      }

                      // address:port — v1 shows both fields; does not show
                      // instance/unit/pid/uptime (docs/DESIGN.md "Connection
                      // row detail").
                      Text {
                        text: connectionRow.modelData.address + ":" + connectionRow.modelData.port
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      visible: connectionRow.modelData.state === "error" && !!connectionRow.modelData.error
                      width: parent.width
                      text: connectionRow.modelData.error
                        ? (connectionRow.modelData.error.detail || connectionRow.modelData.error.code)
                        : ""
                      color: Color.urgent
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }

                  // One toggle: start if stopped/error, stop if
                  // running/starting (docs/DESIGN.md; no toggle() on
                  // Tracker — this UI decides the verb).
                  Button {
                    id: toggleButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.canStart(connectionRow.modelData.state) ? "Start" : "Stop"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    bordered: true
                    enabled: !root.busyForKey("id:" + connectionRow.modelData.id)
                    opacity: enabled ? 1.0 : 0.55
                    iconText: root.busyForKey("id:" + connectionRow.modelData.id) ? "󰦖" : ""
                    iconSpinning: root.busyForKey("id:" + connectionRow.modelData.id)
                    onClicked: root.toggleConnection(connectionRow.modelData)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
