import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.majkelll.omarchy-docker"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Mirrored from BarWidget, which owns every docker read and write.
  property var rows: []
  property var stats: ({})
  property int statsNproc: 1
  property double statsMemTotalBytes: 0
  property string listError: ""
  property string actionError: ""
  property string busyAction: ""
  property string busyName: ""
  property string busyGroup: ""
  property bool groupByProject: true
  property string pendingRemove: ""

  readonly property var totals: Model.totalStats(root.stats, root.statsNproc, root.statsMemTotalBytes)
  readonly property bool haveStats: root.totals.containerCount > 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color faint: Qt.darker(foreground, 1.7)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Row content starts one dot column in from the row padding; the detail
  // block hangs under the same offset so it lines up under the name.
  readonly property real dotColumn: Style.space(18)
  readonly property real detailIndent: Style.spacing.rowPaddingX + dotColumn
  // A group's members sit one dot column in from its header, so their dots
  // line up under the project name.
  readonly property real groupIndent: dotColumn

  // Which compose projects are open. Kept across the popup closing — the
  // stack you were looking at is usually the one you come back for — but
  // never written anywhere, like the rest of the panel's state.
  property var expandedGroups: ({})

  // What the cursor walks: group headers, and the containers of every open
  // group (or every container, with grouping off).
  readonly property var items: Model.buildItems(root.rows, root.groupByProject, root.expandedGroups)

  // Stands in for a container on a delegate that is drawing a group header,
  // so the container block's bindings never read through null.
  readonly property var noRow: ({ name: "", image: "", state: "", status: "", project: "",
    health: "", restarts: 0, ports: [], running: false, active: false })
  readonly property var noItem: ({ kind: "container", row: root.noRow, group: "", depth: 0 })

  // A row is expanded or it isn't; opening one never fights the confirm
  // dialog for the keyboard, since the dialog blocks the row cursor outright
  // while it is up.
  property string expandedName: ""
  property string confirmName: ""
  property bool confirmOpened: false

  property int selectedIndex: 0
  property bool cursorActive: false

  function colorForRow(row) {
    if (Model.needsAttention(row)) return Color.urgent
    if (row.running) return Color.accent
    return root.faint
  }

  function colorForGroup(rows) {
    if (Model.attentionCount(rows) > 0) return Color.urgent
    for (var i = 0; i < rows.length; i++) if (rows[i].running) return Color.accent
    return root.faint
  }

  function open() {
    root.controller.show()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.controller.hide()
    root.cursorActive = false
    root.confirmOpened = false
    root.confirmName = ""
    root.expandedName = ""
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Arrives from an IPC `remove` call — puts the confirmation on screen
  // exactly the way a click on the row's own button would, then tells the
  // host to forget it so it cannot re-fire on the next mirror tick.
  onPendingRemoveChanged: {
    if (root.pendingRemove === "") return
    root.askRemove(root.pendingRemove)
    if (root.hostWidget) root.hostWidget.clearPendingRemove()
  }

  function askRemove(name) {
    root.confirmName = name
    root.confirmOpened = true
    // `selectedIndex: 0` in the dialog's declaration only sets the initial
    // value once; without resetting it here, a later remove would keep
    // wherever a previous confirm/cancel left the cursor.
    removeConfirm.selectedIndex = 0
  }

  function confirmRemove() {
    var name = root.confirmName
    root.confirmOpened = false
    root.confirmName = ""
    if (name !== "" && root.hostWidget) root.hostWidget.removeContainer(name)
  }

  function cancelRemove() {
    root.confirmOpened = false
    root.confirmName = ""
  }

  // While a row is being edited it owns the panel; expanding another row
  // would leave nothing to look at where the first one was.
  function toggleExpanded(name) {
    root.expandedName = root.expandedName === name ? "" : name
  }

  function setGroupExpanded(key, open) {
    // project names are labels anyone can set — no prototype to collide with
    var next = Object.create(null)
    for (var k in root.expandedGroups) if (k !== key) next[k] = root.expandedGroups[k]
    if (open) next[key] = true
    root.expandedGroups = next
  }

  function toggleGroup(key) {
    root.setGroupExpanded(key, root.expandedGroups[key] !== true)
  }

  function refresh() {
    if (root.hostWidget) root.hostWidget.refreshList()
  }

  function primaryAction(id, name) {
    if (!root.hostWidget) return
    if (id === "remove") { root.askRemove(name); return }
    if (id === "start") { root.hostWidget.start(name); return }
    if (id === "stop") { root.hostWidget.stop(name); return }
    if (id === "restart") { root.hostWidget.restart(name); return }
  }

  // Only what Model.groupActions offered for the group's current state, so
  // a key press can never ask compose for something the buttons would not.
  function groupAction(id, key, rows) {
    if (!root.hostWidget) return
    var offered = Model.groupActions(rows)
    for (var i = 0; i < offered.length; i++) {
      if (offered[i].id !== id) continue
      if (id === "edit") root.hostWidget.editGroup(key)
      else if (id === "start") root.hostWidget.startGroup(key)
      else if (id === "stop") root.hostWidget.stopGroup(key)
      else if (id === "restart") root.hostWidget.restartGroup(key)
      return
    }
  }

  function menuAction(item, name) {
    if (!root.hostWidget) return
    if (item.id === "logs") { root.hostWidget.openLogs(name); return }
    if (item.id === "shell") { root.hostWidget.openShell(name); return }
    if (item.id === "pause") { root.hostWidget.pauseContainer(name); return }
    if (item.id === "unpause") { root.hostWidget.unpauseContainer(name); return }
    if (item.id === "kill") { root.hostWidget.killContainer(name); return }
    if (item.id === "open") { root.hostWidget.openPort(name, item.arg); return }
  }

  // A container is busy for its own action, or for one on its whole project.
  function isBusy(row) {
    if (root.busyAction === "") return false
    if (root.busyName !== "" && root.busyName === row.name) return true
    return root.busyGroup !== "" && row.project === root.busyGroup
  }

  function isGroupBusy(key) {
    return root.busyAction !== "" && root.busyGroup === key
  }

  // A row can vanish from under an open block — containers come and go, and
  // the panel would otherwise keep an expandedName nothing renders.
  onRowsChanged: {
    if (root.expandedName !== "" && !Model.findRow(root.rows, root.expandedName)) root.expandedName = ""
  }

  onItemsChanged: root.selectedIndex = Model.clampIndex(root.selectedIndex, root.items.length)

  // ----------------------------------------------------------------- cursor

  function hasCursorAt(index) { return root.cursorActive && root.selectedIndex === index }
  function takeCursor(index) { root.cursorActive = true; root.selectedIndex = index }

  function moveCursor(delta) {
    var count = root.items.length
    if (count === 0) return
    var at = root.cursorActive ? root.selectedIndex : (delta > 0 ? -1 : 0)
    var next = ((at + delta) % count + count) % count
    root.takeCursor(next)
  }

  // Left and right walk the tree the way a file tree does: right opens a
  // closed group, left closes an open one or climbs from a container to its
  // group's header. Anywhere else they move the cursor, as they always did.
  function moveHorizontal(delta) {
    var item = root.selectedItem()
    if (item && item.kind === "group") {
      if (delta > 0 && !item.expanded) { root.setGroupExpanded(item.key, true); return }
      if (delta < 0 && item.expanded) { root.setGroupExpanded(item.key, false); return }
    } else if (item && delta < 0 && item.group !== "") {
      var header = Model.groupIndexOf(root.items, item.group)
      if (header >= 0) { root.takeCursor(header); return }
    }
    root.moveCursor(delta)
  }

  function selectedItem() {
    if (!root.cursorActive) return null
    return root.items[root.selectedIndex] || null
  }

  function selectedRow() {
    var item = root.selectedItem()
    return item && item.kind === "container" ? item.row : null
  }

  function activateCursor() {
    var item = root.selectedItem()
    if (!item) return
    if (item.kind === "group") root.toggleGroup(item.key)
    else root.toggleExpanded(item.row.name)
  }

  // u / d: up and down for whatever the cursor is on — the whole project on
  // a group header, the one container anywhere else.
  function upDownSelected(up) {
    var item = root.selectedItem()
    if (!item || !root.hostWidget) return
    if (item.kind === "group") {
      root.groupAction(up ? "start" : "stop", item.key, item.rows)
      return
    }
    var rules = Model.stateRules(item.row.state)
    if (up && rules.start) root.hostWidget.start(item.row.name)
    else if (!up && rules.stopRestart) root.hostWidget.stop(item.row.name)
  }

  // e: the compose files of whatever project the cursor is in — its header,
  // or any container that belongs to one (with grouping off too, since the
  // row still knows its project).
  function editSelected() {
    var item = root.selectedItem()
    if (!item || !root.hostWidget) return
    var key = item.kind === "group" ? item.key : item.row.project
    if (key !== "") root.hostWidget.editGroup(key)
  }

  function removeSelected() {
    var row = root.selectedRow()
    if (row && Model.stateRules(row.state).remove) root.askRemove(row.name)
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // One row of the panel's single cursor model. Visuals come from `hasCursor`
  // only — never from containsMouse — so mouse and keyboard can never light
  // up two rows at once.
  component PanelRow: CursorSurface {
    id: rowSurface

    required property int rowIndex
    property bool activeRow: false

    readonly property bool selected: root.hasCursorAt(rowIndex)

    signal activated()

    width: parent ? parent.width : 0
    hasCursor: selected
    current: activeRow
    foreground: root.foreground
    accent: Color.accent

    onSelectedChanged: if (selected) scrollArea.ensureVisible(rowSurface)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.takeCursor(rowSurface.rowIndex)
      onClicked: rowSurface.activated()
    }
  }

  // The one loud thing in the panel: no containers to talk about at all, or
  // docker itself out of reach.
  component StateBanner: BorderSurface {
    id: banner

    property color tone: root.foreground
    property string glyph: ""
    property string title: ""
    property string detail: ""

    width: parent ? parent.width : 0
    implicitHeight: bannerRow.implicitHeight + Style.spacing.xxl
    radius: Style.cornerRadius
    color: Style.hoverFillFor(banner.tone, banner.tone)
    borderSpec: Border.controlSpec("selected", banner.tone, banner.tone)

    Row {
      id: bannerRow
      anchors.centerIn: parent
      width: parent.width - Style.spacing.huge * 2
      spacing: Style.spacing.controlGap

      Text {
        text: banner.glyph
        color: banner.tone
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(28)
        spacing: Style.spacing.xxs
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          text: banner.title
          color: banner.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: banner.detail
          color: banner.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // A compact CPU/RAM readout — used for the panel's total; a full card per
  // row would be more chrome than a container list needs, so each row gets
  // Model.rowStatLine's plain text instead.
  component TotalStat: Column {
    property string label: ""
    property string value: ""
    spacing: Style.spacing.xxs

    Text {
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.0
    }
    Text {
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirmOpened
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.moveHorizontal(dx); else root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.removeSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") { root.refresh(); return }
        if (text === "u" || text === "U") { root.upDownSelected(true); return }
        if (text === "d" || text === "D") { root.upDownSelected(false); return }
        if (text === "e" || text === "E") { root.editSelected(); return }
        var row = root.selectedRow()
        if (!row || !root.hostWidget) return
        if (text === "l" || text === "L") {
          root.hostWidget.openLogs(row.name)
        } else if (text === "p" || text === "P") {
          var rules = Model.stateRules(row.state)
          if (rules.pause) root.hostWidget.pauseContainer(row.name)
          else if (rules.unpause) root.hostWidget.unpauseContainer(row.name)
        } else if (text === "k" || text === "K") {
          if (Model.stateRules(row.state).kill) root.hostWidget.killContainer(row.name)
        } else if (text === "o" || text === "O") {
          if (row.running && row.ports.length > 0) root.hostWidget.openPort(row.name, row.ports[0].host)
        }
      }

      Flickable {
        id: scrollArea
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        function ensureVisible(item) {
          if (!item || contentHeight <= height) return
          var top = item.mapToItem(contentColumn, 0, 0).y
          var margin = Style.spacing.lg
          if (top - margin < contentY) contentY = Math.max(0, top - margin)
          else if (top + item.height + margin > contentY + height)
            contentY = Math.min(contentHeight - height, top + item.height + margin - height)
        }

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: scrollArea.width
          spacing: Style.spacing.panelGap

          PanelHero {
            title: "Docker"
            meta: Model.summary(root.rows)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: Model.GLYPH.docker
                color: root.listError !== ""
                  ? Color.urgent
                  : (Model.attentionCount(root.rows) > 0 ? Color.urgent : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh now"
                foreground: root.foreground
                hoverColor: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }
            }
          }

          // The always-on totals line — CPU normalized against every core,
          // so a fully loaded machine reads close to 100% rather than
          // hundreds of percent, and RAM against the machine's own total.
          Row {
            visible: root.haveStats
            width: parent.width
            spacing: Style.spacing.huge

            TotalStat {
              label: "DOCKER CPU"
              value: Model.formatPercent(root.totals.cpuPercentOfSystem) + " of system"
            }
            TotalStat {
              label: "DOCKER RAM"
              value: Model.formatBytes(root.totals.memUsedBytes) +
                (root.totals.memTotalBytes > 0 ? " (" + Model.formatPercent(root.totals.memPercentOfSystem) + " of " + Model.formatBytes(root.totals.memTotalBytes) + ")" : "")
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: Model.errorText(root.actionError)
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "CONTAINERS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          StateBanner {
            visible: root.listError !== ""
            tone: Color.urgent
            glyph: "󰀦"
            title: Model.errorText(root.listError)
            detail: ""
          }

          Text {
            visible: root.rows.length === 0 && root.listError === ""
            text: "No containers found"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            visible: root.listError === ""
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: root.items

              // One delegate draws either a group header or a container row;
              // the other half stays hidden, and a hidden item takes no room
              // in a Column.
              delegate: Column {
                id: rowEntry
                required property int index

                // Read back out of root.items rather than off modelData:
                // the Repeater hands modelData over as a QVariant copy, whose
                // nested arrays come back as sequence wrappers that
                // Array.isArray — and so every Model.js helper — reads as
                // empty.
                readonly property var entry: root.items[index] || root.noItem
                readonly property bool isGroup: entry.kind === "group"
                readonly property var row: isGroup ? root.noRow : entry.row
                readonly property string groupKey: isGroup ? entry.key : ""
                readonly property var groupRows: isGroup ? entry.rows : []
                readonly property real indent: entry.depth * root.groupIndent

                readonly property bool expanded: !isGroup && root.expandedName === row.name
                readonly property bool busy: isGroup ? root.isGroupBusy(groupKey) : root.isBusy(row)
                readonly property var stat: isGroup ? undefined : root.stats[row.name]

                width: parent.width
                spacing: Style.spacing.sm

                onExpandedChanged: if (expanded) Qt.callLater(function() { scrollArea.ensureVisible(rowEntry) })

                // ---------------------------------------------- group header
                PanelRow {
                  id: groupRow
                  visible: rowEntry.isGroup
                  rowIndex: rowEntry.index
                  implicitHeight: groupContent.implicitHeight + Style.spacing.xl
                  onActivated: root.toggleGroup(rowEntry.groupKey)

                  Item {
                    id: groupContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: groupLabels.implicitHeight

                    Text {
                      id: chevron
                      text: rowEntry.isGroup && rowEntry.entry.expanded ? Model.GLYPH.expanded : Model.GLYPH.collapsed
                      color: root.colorForGroup(rowEntry.groupRows)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.left: parent.left
                      anchors.top: groupLabels.top
                      anchors.topMargin: Math.max(0, Math.round((groupTitle.implicitHeight - implicitHeight) / 2))
                      width: root.dotColumn
                    }

                    Column {
                      id: groupLabels
                      anchors.left: chevron.right
                      anchors.right: groupActionRow.left
                      anchors.rightMargin: Style.spacing.lg
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xxs

                      Text {
                        id: groupTitle
                        width: parent.width
                        text: rowEntry.groupKey
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        readonly property string statLine: Model.groupStatLine(rowEntry.groupRows, root.stats)
                        text: rowEntry.busy
                          ? Model.busyLabel(root.busyAction)
                          : Model.summary(rowEntry.groupRows) + (statLine !== "" ? " · " + statLine : "")
                        color: Model.attentionCount(rowEntry.groupRows) > 0 ? Color.urgent : root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      id: groupActionRow
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xs
                      visible: !rowEntry.busy

                      Repeater {
                        model: Model.groupActions(rowEntry.groupRows)

                        delegate: PanelActionButton {
                          required property var modelData
                          iconText: modelData.icon
                          tooltipText: modelData.tooltip
                          foreground: root.foreground
                          hoverColor: modelData.urgent ? Color.urgent : Color.accent
                          fontFamily: root.fontFamily
                          onClicked: root.groupAction(modelData.id, rowEntry.groupKey, rowEntry.groupRows)
                        }
                      }
                    }
                  }
                }

                // -------------------------------------------- container row
                PanelRow {
                  id: containerRow
                  visible: !rowEntry.isGroup
                  x: rowEntry.indent
                  width: rowEntry.width - rowEntry.indent
                  rowIndex: rowEntry.index
                  activeRow: rowEntry.expanded
                  implicitHeight: rowContent.implicitHeight + Style.spacing.xl
                  onActivated: root.toggleExpanded(rowEntry.row.name)

                  Item {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: labels.implicitHeight

                    Text {
                      id: dot
                      text: rowEntry.expanded ? "󰅀" : "●"
                      color: root.colorForRow(rowEntry.row)
                      font.family: root.fontFamily
                      font.pixelSize: rowEntry.expanded ? Style.font.caption : Style.font.bodySmall
                      anchors.left: parent.left
                      anchors.top: labels.top
                      anchors.topMargin: Math.max(0, Math.round((titleText.implicitHeight - implicitHeight) / 2))
                      width: root.dotColumn
                    }

                    Column {
                      id: labels
                      anchors.left: dot.right
                      anchors.right: actions.left
                      anchors.rightMargin: Style.spacing.lg
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xxs

                      Text {
                        id: titleText
                        width: parent.width
                        text: rowEntry.row.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        // Up-time and live CPU/RAM only — health, project,
                        // restarts, and ports are for the expanded row.
                        text: rowEntry.busy
                          ? Model.busyLabel(root.busyAction)
                          : (Model.statusText(rowEntry.row) + (Model.rowStatLine(rowEntry.row, rowEntry.stat) !== "" ? " · " + Model.rowStatLine(rowEntry.row, rowEntry.stat) : ""))
                        color: Model.needsAttention(rowEntry.row) ? Color.urgent : root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      id: actions
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xs
                      visible: !rowEntry.busy

                      Repeater {
                        model: Model.rowActions(rowEntry.row)

                        delegate: PanelActionButton {
                          required property var modelData
                          iconText: modelData.icon
                          tooltipText: modelData.tooltip
                          foreground: root.foreground
                          hoverColor: modelData.urgent ? Color.urgent : Color.accent
                          fontFamily: root.fontFamily
                          onClicked: root.primaryAction(modelData.id, rowEntry.row.name)
                        }
                      }
                    }
                  }
                }

                // ------------------------------------------------ details
                Column {
                  visible: rowEntry.expanded
                  width: parent.width - root.detailIndent - Style.spacing.rowPaddingX - rowEntry.indent
                  x: root.detailIndent + rowEntry.indent
                  spacing: Style.spacing.sm

                  Text {
                    width: parent.width
                    text: rowEntry.row.image
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }

                  Text {
                    width: parent.width
                    visible: text !== ""
                    text: Model.expandedMeta(rowEntry.row)
                    color: Model.needsAttention(rowEntry.row) ? Color.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    width: parent.width
                    visible: text !== ""
                    text: rowEntry.row.ports.length > 0
                      ? "Ports: " + rowEntry.row.ports.map(function(p) { return p.host + "→" + p.container }).join(", ")
                      : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.xs

                    Repeater {
                      model: Model.rowMenuActions(rowEntry.row)

                      delegate: PanelActionButton {
                        required property var modelData
                        iconText: modelData.icon
                        tooltipText: modelData.label
                        foreground: root.foreground
                        hoverColor: modelData.urgent ? Color.urgent : Color.accent
                        fontFamily: root.fontFamily
                        onClicked: root.menuAction(modelData, rowEntry.row.name)
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            text: root.groupByProject
              ? "Enter/→ open · ← close · u up · d down · e edit compose · x remove · L logs · p pause/resume · K kill · o open port · r refresh · Esc close"
              : "Enter details · u up · d down · e edit compose · x remove · L logs · p pause/resume · K kill · o open port · r refresh · Esc close"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    ConfirmDialog {
      id: removeConfirm
      anchors.fill: parent
      opened: root.confirmOpened
      // Starts on Cancel, not the component's own default — a stray Enter
      // must never be the thing that deletes a container.
      selectedIndex: 0
      message: "Remove " + root.confirmName + "? This cannot be undone; its image and volumes are kept."
      cancelText: "Cancel"
      confirmText: "Remove"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onCanceled: root.cancelRemove()
      onConfirmed: root.confirmRemove()
    }

    Item {
      id: confirmKeys
      anchors.fill: parent
      visible: root.confirmOpened
      focus: root.confirmOpened
      Keys.onPressed: function(event) { if (removeConfirm.handleKey(event)) event.accepted = true }
    }
  }

  onConfirmOpenedChanged: {
    if (root.confirmOpened) Qt.callLater(function() { if (root.confirmOpened) confirmKeys.forceActiveFocus() })
    else Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }
}
