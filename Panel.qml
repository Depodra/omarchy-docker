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

  function menuAction(item, name) {
    if (!root.hostWidget) return
    if (item.id === "logs") { root.hostWidget.openLogs(name); return }
    if (item.id === "shell") { root.hostWidget.openShell(name); return }
    if (item.id === "pause") { root.hostWidget.pauseContainer(name); return }
    if (item.id === "unpause") { root.hostWidget.unpauseContainer(name); return }
    if (item.id === "kill") { root.hostWidget.killContainer(name); return }
    if (item.id === "open") { root.hostWidget.openPort(name, item.arg); return }
  }

  function isBusy(name) {
    return root.busyAction !== "" && root.busyName === name
  }

  // A row can vanish from under an open block — containers come and go, and
  // the panel would otherwise keep an expandedName nothing renders.
  onRowsChanged: {
    if (root.expandedName !== "" && !Model.findRow(root.rows, root.expandedName)) root.expandedName = ""
    root.selectedIndex = Model.clampIndex(root.selectedIndex, root.rows.length)
  }

  // ----------------------------------------------------------------- cursor

  function hasCursorAt(index) { return root.cursorActive && root.selectedIndex === index }
  function takeCursor(index) { root.cursorActive = true; root.selectedIndex = index }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    var at = root.cursorActive ? root.selectedIndex : (delta > 0 ? -1 : 0)
    var next = ((at + delta) % root.rows.length + root.rows.length) % root.rows.length
    root.takeCursor(next)
  }

  function selectedRow() {
    if (!root.cursorActive) return null
    return root.rows[root.selectedIndex] || null
  }

  function activateCursor() {
    var row = root.selectedRow()
    if (row) root.toggleExpanded(row.name)
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
      onMoveRequested: function(dx, dy) { root.moveCursor(dx !== 0 ? dx : dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.removeSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") { root.refresh(); return }
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
              model: root.rows

              delegate: Column {
                id: rowEntry
                required property var modelData
                required property int index

                readonly property bool expanded: root.expandedName === modelData.name
                readonly property bool busy: root.isBusy(modelData.name)
                readonly property var stat: root.stats[modelData.name]

                width: parent.width
                spacing: Style.spacing.sm

                onExpandedChanged: if (expanded) Qt.callLater(function() { scrollArea.ensureVisible(rowEntry) })

                PanelRow {
                  id: containerRow
                  rowIndex: rowEntry.index
                  activeRow: rowEntry.expanded
                  implicitHeight: rowContent.implicitHeight + Style.spacing.xl
                  onActivated: root.toggleExpanded(rowEntry.modelData.name)

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
                      color: root.colorForRow(rowEntry.modelData)
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
                        text: rowEntry.modelData.name
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
                          : (Model.statusText(rowEntry.modelData) + (Model.rowStatLine(rowEntry.modelData, rowEntry.stat) !== "" ? " · " + Model.rowStatLine(rowEntry.modelData, rowEntry.stat) : ""))
                        color: Model.needsAttention(rowEntry.modelData) ? Color.urgent : root.faint
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
                        model: Model.rowActions(rowEntry.modelData)

                        delegate: PanelActionButton {
                          required property var modelData
                          iconText: modelData.icon
                          tooltipText: modelData.tooltip
                          foreground: root.foreground
                          hoverColor: modelData.urgent ? Color.urgent : Color.accent
                          fontFamily: root.fontFamily
                          onClicked: root.primaryAction(modelData.id, rowEntry.modelData.name)
                        }
                      }
                    }
                  }
                }

                // ------------------------------------------------ details
                Column {
                  visible: rowEntry.expanded
                  width: parent.width - root.detailIndent - Style.spacing.rowPaddingX
                  x: root.detailIndent
                  spacing: Style.spacing.sm

                  Text {
                    width: parent.width
                    text: rowEntry.modelData.image
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }

                  Text {
                    width: parent.width
                    visible: text !== ""
                    text: Model.expandedMeta(rowEntry.modelData)
                    color: Model.needsAttention(rowEntry.modelData) ? Color.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    width: parent.width
                    visible: text !== ""
                    text: rowEntry.modelData.ports.length > 0
                      ? "Ports: " + rowEntry.modelData.ports.map(function(p) { return p.host + "→" + p.container }).join(", ")
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
                      model: Model.rowMenuActions(rowEntry.modelData)

                      delegate: PanelActionButton {
                        required property var modelData
                        iconText: modelData.icon
                        tooltipText: modelData.label
                        foreground: root.foreground
                        hoverColor: modelData.urgent ? Color.urgent : Color.accent
                        fontFamily: root.fontFamily
                        onClicked: root.menuAction(modelData, rowEntry.modelData.name)
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            text: "Enter details · x remove · l logs · p pause/resume · k kill · o open port · r refresh · Esc close"
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
