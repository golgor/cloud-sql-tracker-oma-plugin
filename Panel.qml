import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Grouped list — the locked v1 chrome, in the shell's house style.
//
// Normative appearance/interaction spec: docs/chrome.md. Decisions:
// docs/DESIGN.md. Seams: docs/modules.md. Vocabulary: CONTEXT.md.
//
// Binds to Tracker only — no Process, no argv, no connections.json I/O.
// Group and Connection order come straight from Tracker, which mirrors the
// Status document's own config order; never re-sorted (chrome.md §10).
//
// Nested under BarWidget (docs/modules.md "Nested" host shape), same as
// weather/clock — the bar widget (hostWidget), not this Item, is what the
// popout coordinator and KeyboardPanel identify the panel by.
Panel {
  id: root
  moduleName: "io.github.golgor.cloud-sql-tracker"

  // settings/bar are already declared on the base Panel (qs.Ui) — do not
  // redeclare them (shadows the base property, which qmllint flags, and
  // diverges from weather's nested-panel idiom that relies on the inherited
  // ones). Only these three are this panel's own, set by injectPanel.
  property var anchorItem
  property var hostWidget
  property var tracker

  readonly property var barIdentity: hostWidget || root

  // Base Panel.switchPanel() passes itself (this nested Item) as the popout
  // identity, but the KeyboardPanel below registers under barIdentity (the
  // hostWidget) for this "Nested" host shape — same mismatch weather's
  // Panel.qml overrides this for, and for the same reason: Tab-to-switch must
  // look up the sibling widget under the identity it was registered under.
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- Tracker view (docs/modules.md "Tracker interface") ------------------

  readonly property var degraded: tracker ? tracker.degraded : null
  readonly property int total: tracker ? tracker.total : 0
  readonly property int runningCount: tracker ? tracker.runningCount : 0
  readonly property int errorCount: tracker ? tracker.errorCount : 0
  readonly property var groupList: tracker ? tracker.groups : []
  readonly property var connectionList: tracker ? tracker.connections : []
  // Document row count (includes disabled). Enabled-only progress uses `total`.
  readonly property int publishedCount: connectionList.length
  readonly property bool trackerBusy: tracker ? tracker.busy : false
  readonly property string busyKey: tracker ? tracker.busyKey : ""
  readonly property int actionEpoch: tracker ? tracker.actionEpoch : 0
  readonly property int documentEpoch: tracker ? tracker.documentEpoch : -1

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- Health state glyphs (chrome.md §2) ---------------------------------
  //
  // Literal characters, never "\uXXXX": every codepoint here is above U+FFFF,
  // so a four-hex-digit escape truncates and the leftover digit becomes a
  // literal character. "\uF0337" parses as \uF033 -- a *valid* glyph in the
  // older nf-fa range -- followed by "7", so it renders a plausible wrong
  // icon rather than failing. Same idiom as bluetooth/Panel.qml, which
  // writes its two device glyphs as literal characters too.
  readonly property string glyphRunning: "󰌷"   // U+F0337 link
  readonly property string glyphStopped: "󰌸"   // U+F0338 link-off
  readonly property string glyphStarting: "󰦖"  // U+F0996 spinner
  readonly property string glyphError: "󰀪"     // U+F002A alert-circle
  readonly property string glyphGroupStart: "󰐊" // U+F040A play
  readonly property string glyphGroupStop: "󰓛"  // U+F04DB stop
  readonly property string glyphCloud: "󰅟"     // U+F015F cloud

  // ---- Health state mapping (chrome.md §2) --------------------------------
  //
  // Five channels so no single one is load-bearing: shape (glyph), colour,
  // row fill, motion, and the status line. Only `error` spends hue —
  // Color.urgent, the one token every theme derives from `red`/`color1`.
  // `starting` uses Color.accent *and* spins, because kanagawa sets
  // accent == foreground and colour alone would be invisible there.

  function stateGlyph(state) {
    if (state === "running") return root.glyphRunning
    if (state === "starting") return root.glyphStarting
    if (state === "error") return root.glyphError
    // disabled uses link-off at lower alpha (stateColor), not a fifth glyph —
    // geometry-stable with stopped and still readable as "not in service".
    return root.glyphStopped
  }

  function stateColor(state) {
    if (state === "running") return root.fg
    if (state === "starting") return Color.accent
    if (state === "error") return Color.urgent
    if (state === "disabled") return Util.alpha(root.fg, 0.35)
    return Util.alpha(root.fg, 0.55)
  }

  // Util.alpha, never Qt.darker: darker() divides HSV value, i.e. blends
  // toward black unconditionally, which only coincides with "toward the
  // background" on dark themes. Measured over the 22 installed themes it
  // inverts on the four light ones and is a no-op on `white` (foreground
  // #000000, value already 0). chrome.md §1.
  // `disabled` is not a Health state; callers pass displayState or the
  // synthetic "disabled" token from ConnectionRow.
  function nameColor(state) {
    if (state === "disabled") return Util.alpha(root.fg, 0.55)
    return state === "stopped" ? Util.alpha(root.fg, 0.72) : root.fg
  }

  function statusColor(state) {
    if (state === "error") return Color.urgent
    if (state === "disabled") return Util.alpha(root.fg, 0.4)
    return Util.alpha(root.fg, 0.55)
  }

  function stateLabel(state) {
    if (state === "running") return "running"
    if (state === "starting") return "starting…"
    if (state === "error") return "error"
    return "stopped"
  }

  // "<state> · <address>:<port>", or the error code in place of the state.
  // The full error.detail goes in a PanelToolTip, not the row: it runs to
  // 100+ characters and would wrap rows to three lines, destroying the
  // uniform row height the cursor depends on (chrome.md §4).
  function statusLine(conn, state) {
    var where = conn.address + ":" + conn.port
    // Config policy, not Health: disabled rows stay visible but are not
    // start targets (issue #26). Prefer this label over a projected start.
    if (conn.enabled === false)
      return "disabled  ·  " + where
    if (state === "error")
      return (conn.error && conn.error.code ? conn.error.code : "error") + "  ·  " + where
    return root.stateLabel(state) + "  ·  " + where
  }

  // Detail only, never the code: the code is already in the status line two
  // pixels away, and the row's PanelToolTip is gated on this being non-empty —
  // so an empty detail correctly means no tooltip at all (chrome.md §4).
  // Model.js normalises a missing detail to "", so this is always a string.
  function errorDetail(conn) {
    if (conn.state !== "error" || !conn.error) return ""
    return conn.error.detail
  }

  // ---- Derived lists ------------------------------------------------------

  function connectionsForGroup(name) {
    var list = []
    for (var i = 0; i < root.connectionList.length; i++) {
      if (root.connectionList[i].group === name) list.push(root.connectionList[i])
    }
    return list
  }

  // Start targets only (#26). Stop may still include disabled (CLI no-op).
  function enabledConnections(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      if (list[i].enabled !== false) out.push(list[i])
    }
    return out
  }

  function isConnEnabled(conn) {
    return !conn || conn.enabled !== false
  }

  function groupFor(name) {
    for (var i = 0; i < root.groupList.length; i++) {
      if (root.groupList[i].name === name) return root.groupList[i]
    }
    return null
  }

  function groupCounts(g) {
    return g.running + "/" + g.total + (g.error > 0 ? "  ·  " + g.error + " err" : "")
  }

  // One flat model so the ListView index and the cursor share a coordinate
  // space, which is what makes positionViewAtIndex work. Group headers are
  // rows in their own right (selectedIndex === -1 within that section).
  // Rebuilt whenever Tracker publishes — hence the Qt.callLater in
  // keepCursorVisible below.
  // Empty exactly when the ListView is hidden, so the cursor's world and the
  // rendered world cannot disagree — `total === 0` matters as much as degraded,
  // because Model.js deliberately emits Group entries for keys in the document's
  // groups map that have no Connections (parseGroups' second loop). Without the
  // total guard those orphan Groups became keyboard sections with nothing drawn:
  // j landed a cursor on an unrendered header, and Enter fired startGroup on an
  // empty Group while the panel displayed the empty body.
  readonly property var flatRows: {
    var out = []
    if (root.degraded !== null || root.publishedCount === 0) return out
    for (var i = 0; i < root.groupList.length; i++) {
      var g = root.groupList[i]
      out.push({ kind: "group", group: g.name, g: g })
      var conns = root.connectionsForGroup(g.name)
      for (var j = 0; j < conns.length; j++) {
        out.push({ kind: "conn", group: g.name, indexInGroup: j, conn: conns[j] })
      }
    }
    return out
  }

  // ---- Cursor (chrome.md §6) ----------------------------------------------
  //
  // The audio/Panel.qml model dev-gallery names as the recipe to copy:
  // three properties, one cursor shared by keyboard and mouse. Mouse hover
  // writes the same three, which is what guarantees a single highlight —
  // CursorSurface's own contract forbids deriving visuals from containsMouse.
  //
  //   focusSection   "header" (virtual: the hero's Stop all) | "group:<name>"
  //   selectedIndex  -1 = that Group's header row, 0..n-1 = a Connection row
  //   cursorActive   false until the keyboard or mouse first arrives

  property string focusSection: ""
  property int selectedIndex: -1
  property bool cursorActive: false

  // Stop all is the only thing "header" targets, and it is hidden whenever
  // degraded or empty — so in those states there is nothing to land on and
  // no rows either. Cursor stays inert; Esc and Tab still work (chrome.md §6).
  readonly property bool headerAvailable: root.degraded === null && root.total > 0
  readonly property bool headerHasCursor: root.cursorActive && root.focusSection === "header"

  // Same guard as flatRows, and for the same reason — these two must agree with
  // the ListView's own `degraded === null && total > 0` or the cursor can point
  // at something that is not on screen.
  readonly property var visibleSections: {
    var list = []
    if (root.degraded !== null || root.publishedCount === 0) return list
    for (var i = 0; i < root.groupList.length; i++) list.push("group:" + root.groupList[i].name)
    return list
  }

  function sectionGroupName(section) {
    return section.indexOf("group:") === 0 ? section.substring(6) : ""
  }

  function sectionCount(section) {
    var name = root.sectionGroupName(section)
    return name === "" ? 0 : root.connectionsForGroup(name).length
  }

  function setCursor(section, index) {
    root.cursorActive = true
    root.focusSection = section
    root.selectedIndex = index
  }

  function moveCursor(delta) {
    var sections = root.visibleSections
    if (sections.length === 0) return

    if (root.focusSection === "header") {
      if (delta > 0) root.setCursor(sections[0], -1)
      return
    }

    var sIdx = sections.indexOf(root.focusSection)
    if (sIdx < 0) { root.setCursor(sections[0], -1); return }

    if (delta > 0) {
      if (root.selectedIndex < root.sectionCount(root.focusSection) - 1) {
        root.selectedIndex = root.selectedIndex + 1
        return
      }
      if (sIdx < sections.length - 1) root.setCursor(sections[sIdx + 1], -1)
      return
    }

    if (root.selectedIndex > -1) { root.selectedIndex = root.selectedIndex - 1; return }
    if (sIdx > 0) {
      // sectionCount - 1 is -1 for a Group with no Connections, which is
      // exactly that Group's header row — so this needs no special case.
      var prev = sections[sIdx - 1]
      root.setCursor(prev, root.sectionCount(prev) - 1)
    } else if (root.headerAvailable) {
      root.setCursor("header", -1)
    }
  }

  // h/l are the explicit asymmetric verbs, mirroring the two icon buttons the
  // mouse gets on a Group header: l starts, h stops. They apply to whatever
  // the cursor is on — a Group header acts on the Group, a Connection row acts
  // on that Connection.
  //
  // Earlier this was a no-op on Connection rows, by analogy with audio's
  // adjustVolume. That analogy was wrong: audio refuses because h/l there
  // would move a *section-level* slider while the cursor sits on a row, so the
  // thing acted on is not the thing highlighted. Here the cursor's target and
  // the action's target are the same row, so there is nothing surprising to
  // protect against — only a missing verb.
  function adjustCursor(delta) {
    if (root.trackerBusy) return
    var name = root.sectionGroupName(root.focusSection)
    if (name === "") return

    if (root.selectedIndex === -1) {
      if (delta > 0) root.startGroup(name)
      else root.stopGroup(name)
      return
    }

    var list = root.connectionsForGroup(name)
    if (root.selectedIndex >= list.length) return
    if (delta > 0) root.startConnection(list[root.selectedIndex])
    else root.stopConnection(list[root.selectedIndex])
  }

  function activateCursor() {
    // Tracker silently ignores a second concurrent action, and an ignored one
    // would leave an intent stranded until the next poll pulled the knob back.
    if (root.trackerBusy) return
    if (root.focusSection === "header") { root.stopAll(); return }
    var name = root.sectionGroupName(root.focusSection)
    if (name === "") return
    if (root.selectedIndex === -1) { root.toggleGroup(name); return }
    var list = root.connectionsForGroup(name)
    if (root.selectedIndex < list.length) root.toggleConnection(list[root.selectedIndex])
  }

  // Index of the cursor within flatRows, for positionViewAtIndex. -1 when the
  // cursor is inert or on the virtual header (which lives outside the list).
  readonly property int cursorRow: {
    if (!root.cursorActive || root.focusSection === "header") return -1
    var rows = root.flatRows
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if ("group:" + r.group !== root.focusSection) continue
      if (r.kind === "group" && root.selectedIndex === -1) return i
      if (r.kind === "conn" && root.selectedIndex === r.indexInGroup) return i
    }
    return -1
  }

  // A poll can shorten the list under a live cursor (a Connection removed from
  // config, a Group emptied), so re-clamp whenever Tracker republishes.
  onConnectionListChanged: {
    root.settleIntents()
    Qt.callLater(root.clampCursor)
  }
  // Content and provenance are separate triggers: connections is a fresh array
  // on every apply so this is usually redundant, but settling must not depend on
  // that implementation detail of Tracker.
  onDocumentEpochChanged: root.settleIntents()
  onGroupListChanged: Qt.callLater(root.clampCursor)
  onDegradedChanged: Qt.callLater(root.clampCursor)

  // The cursor is not reset on close, so reopening lands where it was left.
  // That makes the common loop — open, toggle the one Connection you care
  // about, close, come back later to toggle it back — a single Enter.
  //
  // This needs no saved copy of the position: the cursor properties live on
  // this Panel, and BarWidget's Loader is `active: true` with no dynamic
  // binding, so the object is constructed once and survives every open/close
  // (verified: Component.onCompleted fires once per shell start, and there is
  // no matching onDestruction). Reopening therefore only has to re-activate
  // what is already there. An earlier version kept a separate
  // lastSection/lastIndex pair updated on each *action*, which both duplicated
  // the state and quietly failed the actual requirement: moving the cursor
  // without acting left the memory pointing at the previous row.
  //
  // Session-scoped: no state file is involved, and this plugin owns none by
  // design (DESIGN.md). A shell restart starts cold.
  function restoreCursor() {
    // Nothing pointed at yet — first open after a shell start keeps the house
    // behaviour of no highlight until the keyboard or mouse arrives.
    if (root.focusSection === "") return
    root.cursorActive = true
    // The remembered target may be gone: a Connection dropped from config, a
    // Group emptied, Tracker now degraded. clampCursor repairs or stands down.
    root.clampCursor()
  }

  function resetCursor() {
    root.cursorActive = false
    root.focusSection = ""
    root.selectedIndex = -1
  }

  function clampCursor() {
    if (!root.cursorActive) return
    if (root.focusSection === "header") {
      if (!root.headerAvailable) root.resetCursor()
      return
    }
    var sections = root.visibleSections
    if (sections.length === 0) { root.resetCursor(); return }
    if (sections.indexOf(root.focusSection) < 0) { root.setCursor(sections[0], -1); return }
    var max = root.sectionCount(root.focusSection) - 1
    if (root.selectedIndex > max) root.selectedIndex = max
  }

  // Refresh right away on open rather than waiting for Tracker's next poll
  // tick: the poll interval only shortens for *future* ticks — it does not
  // restart a countdown already in flight.
  onOpenedChanged: {
    if (opened) {
      root.restoreCursor()
      if (root.tracker) root.tracker.refresh()
    }
  }

  // ---- Intent (chrome.md §5) ----------------------------------------------
  //
  // What the operator asked for, held until a Status document answers. Both the
  // switch and the state glyph read it while it is held (see ConnectionRow's
  // displayState) — the split is during-versus-after, not switch-versus-glyph.
  //
  // Keying the optimistic value to `busy` instead does not work: busy ends when
  // the CLI process exits, but the fresh document does not arrive until
  // delayedRefresh fires 500ms later, so the knob falls back to the stale state
  // and bounces On -> Off -> On for a single click.
  //
  // Reassigned wholesale rather than mutated, because mutating a var in place
  // does not re-evaluate bindings that read it.
  property var intents: ({})

  // Tracker's actionEpoch at the moment the outstanding intents were written.
  // One value, not one per id: Panel's command guard means at most one action is
  // ever outstanding, so there is only ever one generation of intents to settle.
  property int intentEpoch: -1

  function hasIntent(id) {
    return Object.prototype.hasOwnProperty.call(root.intents, id)
  }

  function intentFor(id) {
    return root.intents[id] === true
  }

  function setIntent(id, on) {
    var next = {}
    for (var k in root.intents) next[k] = root.intents[k]
    next[id] = on
    root.intentEpoch = root.actionEpoch
    root.intents = next
  }

  function setIntentForList(list, on) {
    var next = {}
    for (var k in root.intents) next[k] = root.intents[k]
    for (var i = 0; i < list.length; i++) next[list[i].id] = on
    root.intentEpoch = root.actionEpoch
    root.intents = next
  }

  // The first document *observed after the action settled* is the authority,
  // whatever it says: it confirms the intent (glyph goes live, knob stays), or
  // contradicts it (knob slides back, which is the operator's signal that the
  // start or stop did not take).
  //
  // "After the action settled" is why this reads documentEpoch and not just
  // `busy`. Tracker's `busy` covers actionProc alone, so a status poll started
  // before the action can exit after it — and settling on that clears the intent
  // against a document that predates the very thing it is supposed to confirm.
  // Visible as the knob falling back and the projected `starting` glyph dropping
  // mid-action, then both correcting 500ms later: the same bounce 3c19e07 fixed,
  // one layer down, at document provenance rather than at `busy`.
  //
  // Still self-healing: Tracker advances actionEpoch when it *refuses* an action
  // too, so an action its version gate rejected drops its intent on the next
  // document rather than leaving the knob stuck.
  function settleIntents() {
    if (root.trackerBusy) return
    if (Object.keys(root.intents).length === 0) return
    if (root.documentEpoch <= root.intentEpoch) return
    root.intents = ({})
  }

  // ---- Busy (chrome.md §5) ------------------------------------------------
  //
  // Tracker runs one action at a time: _runAction returns early and silently
  // when actionProc.running. A control left enabled during another action is
  // therefore a dead click — it looks live and does nothing. So *every* action
  // control is disabled while busy; only the busyKey target spins.

  function busyForKey(key) {
    return root.trackerBusy && root.busyKey === key
  }

  // ---- Commands (Action targets — CONTEXT.md, docs/modules.md) ------------
  //
  // Every command is the single place busy is enforced: Tracker ignores a
  // concurrent action silently, so a command that ran anyway would record an
  // intent for something that never happened and leave the knob stuck until
  // the next poll pulled it back. Guarding here rather than in each control's
  // `enabled` means no control has to dim to stay safe — see the note on
  // groupActions and chrome.md §5.

  function canStart(state) {
    return state === "stopped" || state === "error"
  }

  // Every command records its intent first, so group and panel-wide actions
  // throw their knobs as immediately as a single row does.
  function stopAll() {
    if (!root.tracker || root.trackerBusy) return
    root.setIntentForList(root.connectionList, false)
    root.tracker.stop({ kind: "all" })
  }

  function startGroup(name) {
    if (!root.tracker || root.trackerBusy) return
    // Intent only for startable members — disabled rows must not bounce (#26).
    var targets = root.enabledConnections(root.connectionsForGroup(name))
    if (targets.length === 0) return
    root.setIntentForList(targets, true)
    root.tracker.start({ kind: "group", group: name })
  }

  function stopGroup(name) {
    if (!root.tracker || root.trackerBusy) return
    root.setIntentForList(root.connectionsForGroup(name), false)
    root.tracker.stop({ kind: "group", group: name })
  }

  // The keyboard has one Enter where the mouse has two buttons, so Enter on a
  // Group header picks a verb the same way a row toggle does (chrome.md §6).
  function toggleGroup(name) {
    var g = root.groupFor(name)
    if (!g) return
    if (g.running + g.starting > 0) root.stopGroup(name)
    else root.startGroup(name)
  }

  // Explicit per-Connection verbs for h/l. Unlike toggleConnection these do
  // not consult the current Health state: asking to start something already
  // running is harmless and idempotent at the CLI, and second-guessing it here
  // would make h/l silently do nothing on the row the operator is pointing at.
  // Disabled is different: start is refused a priori (#26), not idempotent.
  function startConnection(conn) {
    if (!root.tracker || root.trackerBusy) return
    if (!root.isConnEnabled(conn)) return
    root.setIntent(conn.id, true)
    root.tracker.start({ kind: "id", id: conn.id })
  }

  function stopConnection(conn) {
    if (!root.tracker || root.trackerBusy) return
    if (!root.isConnEnabled(conn)) return
    root.setIntent(conn.id, false)
    root.tracker.stop({ kind: "id", id: conn.id })
  }

  // UI decides the verb; Tracker deliberately has no toggle().
  function toggleConnection(conn) {
    if (!root.tracker || root.trackerBusy) return
    if (!root.isConnEnabled(conn)) return
    var on = root.canStart(conn.state)
    root.setIntent(conn.id, on)
    if (on) root.tracker.start({ kind: "id", id: conn.id })
    else root.tracker.stop({ kind: "id", id: conn.id })
  }

  // ---- Degraded copy (chrome.md §7) --------------------------------------
  //
  // Degraded is not a Connection's Health state `error`: it means the control
  // plane cannot be trusted, so the switchboard must not render at all — an
  // empty healthy-looking panel would read as "all stopped", which is a lie.
  function degradedTitle(kind) {
    if (kind === "cli_missing") return "cloud-sql-tracker not found"
    if (kind === "cli_old") return "cloud-sql-tracker is too old"
    if (kind === "schema") return "Status document not understood"
    if (kind === "status_failed") return "Status check failed"
    // Required fallback: degraded.kind is a Tracker value, and a future kind
    // must not render a blank body.
    return "cloud-sql-tracker unavailable"
  }

  KeyboardPanel {
    id: keyboardPanel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // 380 x 560 is the shell default for list panels — 7 of 10 native panels
    // use 380. Both are caps fitted to the real screen, not fixed sizes.
    contentWidth: keyboardPanel.fittedContentWidth(Style.space(380))
    contentHeight: keyboardPanel.fittedContentHeight(bodyColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // First press only reveals the cursor, so the panel never opens with a
      // highlight already on screen (audio/Panel.qml does the same).
      //
      // Every branch below lands on a real target or leaves the cursor inert.
      // Degraded and empty have no targets at all (chrome.md §6), and going
      // active there used to leave cursorActive true with focusSection "" —
      // harmless on its own, since moveCursor and activateCursor both bail,
      // but the next document to arrive ran clampCursor, found "" not in
      // visibleSections, and painted a highlight on the first Group that
      // nobody had asked for.
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) {
          if (root.focusSection !== "") root.cursorActive = true
          else if (root.visibleSections.length > 0) root.setCursor(root.visibleSections[0], -1)
          else if (root.headerAvailable) root.setCursor("header", -1)
          return
        }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursor(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: bodyColumn
        width: parent.width
        spacing: Style.spacing.panelGap

        // ---------- Hero ----------
        PanelHero {
          id: hero
          width: parent.width
          title: "Cloud SQL Tracker"
          meta: root.runningCount + " of " + root.total + " running"
            + (root.errorCount > 0 ? " · " + root.errorCount + " error" : "")
          foreground: root.fg
          fontFamily: root.fontFamily
          iconOpacity: root.runningCount > 0 ? 1.0 : 0.5

          // The glyph needs an explicit box: OpticalGlyph is a bare Item whose
          // inner Text is anchors.centerIn, so unsized it is 0x0 — iconLoader
          // collapses, heroLabels anchors to x=0, and the glyph paints through
          // the title. The 2px lift is a deliberate optical shift, not a
          // metrics correction (the Nerd Font patcher already centres every
          // icon's ink on the Latin line box axis): the title/meta block is
          // top-heavy, so a geometrically centred icon reads low. chrome.md §4.
          iconComponent: Component {
            Item {
              implicitWidth: Style.font.display
              implicitHeight: Style.font.display

              OpticalGlyph {
                width: parent.width
                height: parent.height
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -Style.space(2)
                text: root.glyphCloud
                fontFamily: root.fontFamily
                fontSize: Style.font.display
                color: root.degraded !== null ? Color.urgent : root.fg
              }
            }
          }

          trailingControl: Component {
            Button {
              // One-way by design: a symmetric master toggle would put N proxy
              // processes and N GCP auth handshakes behind one click
              // (DESIGN.md "Stop all stays one-way").
              visible: root.headerAvailable
              text: "Stop all"
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              hasCursor: root.headerHasCursor
              // `enabled` is safe here — Button's implicitWidth/Height derive
              // from its content Row and padding, not from enabled. Deliberately
              // NO iconText swap for the busy state: Button's icon Text is
              // `visible: iconText !== ""` inside a Row with controlGap spacing,
              // so introducing a spinner glyph would widen the button, move
              // PanelHero.trailingInset, and reflow the title mid-action. Every
              // row spins on the next poll anyway, which is the better signal.
              // No opacity dimming while busy. An action is a sub-second CLI
              // round trip, so dimming every idle control for its duration
              // reads as the whole panel flashing. `enabled` alone blocks the
              // click and is visually silent on Button (its colours derive
              // from selected/foreground, never from enabled).
              enabled: !root.trackerBusy
              onHovered: function (on) { if (on) root.setCursor("header", -1) }
              onClicked: root.stopAll()
            }
          }
        }

        PanelSeparator {
          foreground: root.fg
        }

        // ---------- Degraded: replaces the switchboard entirely ----------
        Column {
          visible: root.degraded !== null
          width: parent.width
          spacing: Style.spacing.md

          Text {
            width: parent.width
            text: root.degraded ? root.degradedTitle(root.degraded.kind) : ""
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: root.degraded ? root.degraded.message : ""
            color: Util.alpha(root.fg, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Empty: no Connections configured ----------
        Column {
          visible: root.degraded === null && root.publishedCount === 0
          width: parent.width
          spacing: Style.spacing.md

          Text {
            width: parent.width
            text: "No connections configured."
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "Add connections with the CLI's config file:"
            color: Util.alpha(root.fg, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Selectable so the path can be copied rather than retyped. Text
          // only — the plugin never opens, reads, parses or writes
          // connections.json; it is CLI-owned (DESIGN.md, CONTEXT.md).
          TextEdit {
            width: parent.width
            text: "~/.config/cloud-sql-tracker/connections.json"
            readOnly: true
            selectByMouse: true
            color: Util.alpha(root.fg, 0.7)
            selectionColor: Style.selectionFill
            selectedTextColor: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: TextEdit.WrapAnywhere
          }
        }

        // ---------- Switchboard ----------
        ListView {
          id: rowList
          visible: root.degraded === null && root.publishedCount > 0
          width: parent.width
          // Own height, capped, so the enclosing Column keeps a finite
          // implicitHeight for fittedContentHeight above.
          height: visible ? Math.min(contentHeight, Style.space(440)) : 0
          spacing: Style.spacing.xs
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.flatRows
          currentIndex: root.cursorRow

          // Deferred by a turn: flatRows is rebuilt every time Tracker
          // publishes, and swapping the model resets the view out from under
          // an immediate call (bluetooth/Panel.qml hit the same thing).
          // Contain only moves when a row is actually clipped, so this never
          // lurches under a hovering mouse.
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(rowList.keepCursorVisible)
          function keepCursorVisible() {
            if (rowList.currentIndex >= 0)
              rowList.positionViewAtIndex(rowList.currentIndex, ListView.Contain)
          }

          delegate: Item {
            id: rowItem
            required property var modelData
            width: ListView.view ? ListView.view.width : 0
            implicitHeight: rowLoader.height
            height: implicitHeight

            Loader {
              id: rowLoader
              width: rowItem.width
              height: item ? item.implicitHeight : 0
              sourceComponent: rowItem.modelData.kind === "group" ? groupComp : connComp
            }

            // Declared inside the delegate so they can see rowItem lexically,
            // and behind a Loader so only the matching one is instantiated —
            // a ConnectionRow built for a group row would evaluate
            // modelData.conn.state against undefined.
            Component {
              id: groupComp
              GroupHeaderRow { rowData: rowItem.modelData }
            }

            Component {
              id: connComp
              ConnectionRow { rowData: rowItem.modelData }
            }
          }
        }
      }
    }
  }

  // ---- Group header row (chrome.md §4) -----------------------------------
  //
  // A CursorSurface in its own right: PanelSectionHeader is only a label with
  // no pointer handling, so the header needs its own surface for the cursor
  // to land on and for the actions to be revealed by.
  component GroupHeaderRow: CursorSurface {
    id: header
    required property var rowData

    readonly property var g: header.rowData.g
    readonly property string section: "group:" + header.rowData.group
    readonly property bool groupBusy: root.busyForKey(header.section)

    hasCursor: root.cursorActive && root.focusSection === header.section && root.selectedIndex === -1
    // current stays false: the persistent fill is reserved for running rows.
    foreground: root.fg
    accent: Color.accent
    implicitHeight: Math.max(headerLabel.implicitHeight, groupActions.implicitHeight)
      + Style.spacing.sm * 2

    MouseArea {
      id: headerMouse
      anchors.fill: parent
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.setCursor(header.section, -1)
    }

    Item {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      implicitHeight: Math.max(headerLabel.implicitHeight, groupActions.implicitHeight)

      PanelSectionHeader {
        id: headerLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: header.g.name.toUpperCase()
        foreground: root.fg
        fontFamily: root.fontFamily
      }

      Text {
        id: headerCounts
        anchors.right: groupActions.left
        anchors.rightMargin: Style.spacing.controlGap
        anchors.verticalCenter: parent.verticalCenter
        text: root.groupCounts(header.g)
        color: Util.alpha(root.fg, 0.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        id: groupActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md

        // Revealed by the cursor alone — CursorSurface's contract is that
        // hover writes the root cursor state rather than being read locally,
        // so hasCursor already covers mouse hover. Also revealed while this
        // Group is the busy target, so the spinner is visible without having
        // to keep the pointer on the row.
        //
        // Revealed by *opacity*, never `visible`: Row skips invisible children
        // entirely, so toggling visibility would collapse this Row — changing
        // the header's height and shifting the counts sideways every time the
        // cursor arrives. Opacity 0 items still take mouse input, so the
        // buttons gate on `enabled` instead, which disables their MouseAreas.
        //
        // `enabled` tracks the *reveal alone*, never `trackerBusy`.
        // PanelActionButton paints its icon `Qt.darker(foreground, 2.0)` when
        // disabled, and `groupBusy` is one of the two things that reveals this
        // Row — so gating on busy here dimmed the spinner for precisely as long
        // as it was spinning, against the "blocks clicks, dims nothing" rule
        // (DESIGN.md, chrome.md §5). Busy is swallowed in the command functions
        // instead, which also blocks the click *before* intent is recorded —
        // dropping the busy term from `enabled` on its own would let a click
        // through to a start Tracker silently ignores, stranding an intent.
        readonly property bool revealed: header.hasCursor || header.groupBusy
        opacity: revealed ? 1.0 : 0.0

        PanelActionButton {
          id: startBtn
          // Doubles as the busy indicator: busyKey names the Group, not which
          // verb was used, so there is nothing to attribute a dedicated
          // spinner control to — and adding one would change the Row's extent.
          iconText: header.groupBusy ? root.glyphStarting : root.glyphGroupStart
          tooltipText: header.groupBusy ? "Working…" : "Start group"
          foreground: root.fg
          fontFamily: root.fontFamily
          enabled: groupActions.revealed
          transformOrigin: Item.Center
          rotation: 0
          onHovered: function (on) { if (on) root.setCursor(header.section, -1) }
          onClicked: root.startGroup(header.g.name)

          // PanelActionButton has no spinning property (that is Button's
          // iconSpinning) and it is an Item, so rotate the button itself —
          // visually identical for a centred glyph.
          RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 900
            loops: Animation.Infinite
            running: header.groupBusy
            onRunningChanged: if (!running) startBtn.rotation = 0
          }
        }

        PanelActionButton {
          iconText: root.glyphGroupStop
          tooltipText: "Stop group"
          foreground: root.fg
          fontFamily: root.fontFamily
          enabled: groupActions.revealed
          onHovered: function (on) { if (on) root.setCursor(header.section, -1) }
          onClicked: root.stopGroup(header.g.name)
        }
      }
    }
  }

  // ---- Connection row (chrome.md §4) -------------------------------------
  component ConnectionRow: CursorSurface {
    id: row
    required property var rowData

    readonly property var conn: row.rowData.conn
    readonly property string section: "group:" + row.rowData.group
    // Not `state`: QQuickItem already has one (the state-machine name), and
    // shadowing it is both a qmllint property-override and a real footgun.
    readonly property string healthState: row.conn.state
    readonly property bool connEnabled: row.conn.enabled !== false

    // What the row *renders*. The polled Health state, except while a start we
    // asked for is still outstanding — then the row renders `starting`, so the
    // knob throw and every state channel agree that work is in flight.
    //
    // Needed because the CLI's own `starting` is nearly unreachable from a
    // panel action: `start` blocks until the port opens (--wait-ms, default
    // 10000), so the guaranteed post-action poll always observes the finished
    // state. Catching a real `starting` document needs a pollTimer tick inside
    // the ~1s start window against a 2s interval, which mostly does not happen.
    //
    // Truth still wins, it just lands second. The first document to arrive with
    // no action in flight drops the intent (settleIntents), so a start that
    // took resolves to `running` and one that failed resolves to `error`. The
    // resting pair is never knob-on + link-off.
    //
    // Only an intent to *start* projects. A stop keeps the polled state, so the
    // link glyph stays lit until a document confirms the proxy is really down —
    // "no link glyph" keeps meaning "nothing is established".
    readonly property string displayState: {
      if (!row.connEnabled) return "disabled"
      if (row.conn.state === "running" || row.conn.state === "starting") return row.conn.state
      if (root.hasIntent(row.conn.id) && root.intentFor(row.conn.id)) return "starting"
      return row.conn.state
    }
    readonly property string detail: root.errorDetail(row.conn)

    hasCursor: root.cursorActive && root.focusSection === row.section
      && root.selectedIndex === row.rowData.indexInGroup
    // The one persistent fill in the panel: running == on. Disabled never fills.
    current: row.connEnabled && row.healthState === "running"
    foreground: root.fg
    accent: Color.accent
    implicitHeight: Math.max(rowInfo.implicitHeight, toggle.implicitHeight, stateGlyph.height)
      + Style.spacing.md * 2

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.connEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(row.section, row.rowData.indexInGroup)
      // Guard the click rather than disabling the MouseArea: `enabled: false`
      // would kill hoverEnabled too, so the cursor would stop following the
      // mouse for as long as any action was in flight. Disabled rows are not
      // start targets (#26) — still hoverable for the cursor.
      onClicked: if (!root.trackerBusy && row.connEnabled) root.toggleConnection(row.conn)
    }

    // Full error.detail lives here, not on the row (chrome.md §4).
    PanelToolTip {
      visible: row.detail !== "" && rowMouse.containsMouse
      text: row.detail
      fontFamily: root.fontFamily
    }

    Item {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      implicitHeight: Math.max(rowInfo.implicitHeight, toggle.implicitHeight, stateGlyph.height)

      // OpticalGlyph, not Text: Nerd Font glyphs have painted bounds that
      // differ from their advance width by a different amount per glyph, so a
      // column of plain Texts visibly jitters. Explicitly sized — see the
      // hero note above. No vertical offset here: all four state glyphs share
      // one ink axis, and a per-glyph correction would introduce exactly the
      // drift OpticalGlyph exists to avoid (chrome.md §2).
      OpticalGlyph {
        id: stateGlyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        height: Style.font.heading
        text: root.stateGlyph(row.displayState)
        fontFamily: root.fontFamily
        fontSize: Style.font.heading
        color: root.stateColor(row.displayState)
        transformOrigin: Item.Center
        rotation: 0

        // Same idiom as Button.iconSpinning, and it needs the same reset the
        // Group button's spinner has: `RotationAnimation on rotation` is a value
        // source, so it takes the property over and *keeps its last value* when
        // it stops — the `rotation: 0` above is not restored. Without this, the
        // link glyph settles at whatever angle the spin happened to end on.
        // Latent until now only because `starting` was almost never rendered.
        RotationAnimation on rotation {
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
          running: row.displayState === "starting"
          onRunningChanged: if (!running) stateGlyph.rotation = 0
        }
      }

      Column {
        id: rowInfo
        anchors.left: stateGlyph.right
        anchors.leftMargin: Style.spacing.xl
        anchors.right: toggle.left
        anchors.rightMargin: Style.spacing.controlGap
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        // Display name, not id (DESIGN.md "Connection row detail").
        Text {
          width: parent.width
          text: row.conn.name
          color: root.nameColor(row.displayState)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.statusLine(row.conn, row.displayState)
          color: root.statusColor(row.displayState)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Intent holds the knob mid-flight and `busy` swallows further clicks.
      // Deliberately no `interactive` binding — see the note on it below, and
      // chrome.md §5.
      ToggleSwitch {
        id: toggle
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // Intent first, truth second: one clean slide on click, held until a
        // Status document confirms it (knob stays, glyph goes live) or denies
        // it (knob slides back). ToggleSwitch documents this as the intended
        // way to get an instant throw — see root.intents for why `busy` is the
        // wrong thing to key it on.
        checked: !row.connEnabled
          ? false
          : (root.hasIntent(row.conn.id)
            ? root.intentFor(row.conn.id)
            : (row.healthState === "running" || row.healthState === "starting"))
        // `busy`, not `interactive`. ToggleSwitch documents `interactive` as
        // "off when the surrounding row owns the click", and derives
        // `cursorRing` from it — so cursorRing false collapses _pad to 0 and
        // the control shrinks from 54x22+12 to 42x22. Because this row's
        // implicitHeight takes toggle.implicitHeight into account, and because
        // trackerBusy is a *panel-wide* condition, using `interactive` made
        // every row in the panel shrink 12px the instant any action started.
        // `busy` swallows clicks with no geometry or visual change at all,
        // which is exactly what the component's own docs recommend.
        // Disabled also uses busy so the switch stays full size and inert (#26).
        busy: root.trackerBusy || !row.connEnabled
        hasCursor: row.hasCursor
        foreground: root.fg
        accent: Color.accent
        onHovered: function (on) { if (on) root.setCursor(row.section, row.rowData.indexInGroup) }
        onToggled: if (row.connEnabled) root.toggleConnection(row.conn)
      }
    }
  }
}
