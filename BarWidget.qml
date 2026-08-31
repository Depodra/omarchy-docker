import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Owns every read and write to docker: the container list, the CPU/RAM
// sample, and every lifecycle action, each through bin/omarchy-docker-ctl.
// There is nothing here that needs to run or alert while the popup is
// closed — unlike a health-check plugin, nobody needs telling the moment a
// container stops — so this plugin has no Service.qml. Panel.qml is a
// passive mirror, populated by injectPanel() below exactly the way
// omarchy-keymaps' BarWidget does it.
BarWidget {
  id: root
  moduleName: "io.github.majkelll.omarchy-docker"

  readonly property string ctlPath: String(Qt.resolvedUrl("bin/omarchy-docker-ctl")).replace(/^file:\/\//, "")

  property var rows: []
  property var stats: ({})
  property int statsNproc: 1
  property double statsMemTotalBytes: 0
  property string listError: ""
  property string actionError: ""
  property string busyAction: ""
  property string busyName: ""
  // Set by the `remove` IPC call so a keybinding cannot skip the
  // confirmation a click on the row's Remove button already goes through —
  // the panel watches this and puts the dialog on screen itself.
  property string pendingRemove: ""

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property int attentionCount: Model.attentionCount(root.rows)

  readonly property int listRefreshSec: Math.max(2, Number(root.setting("listRefreshSec", 5)) || 5)
  readonly property int statsRefreshSec: Math.max(5, Number(root.setting("statsRefreshSec", 10)) || 10)
  readonly property int stopTimeoutSec: Math.max(1, Number(root.setting("stopTimeoutSec", 10)) || 10)

  readonly property string tooltip: root.listError !== ""
    ? Model.errorText(root.listError)
    : Model.summary(root.rows)

  // State the panel mirrors, by the name it carries on both sides. The panel
  // is a separately loaded component, so each name is checked rather than
  // assumed present.
  readonly property var mirroredProperties: ["bar", "settings", "rows", "stats",
    "statsNproc", "statsMemTotalBytes", "listError", "actionError",
    "busyAction", "busyName", "pendingRemove"]

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    for (var i = 0; i < root.mirroredProperties.length; i++) {
      var name = root.mirroredProperties[i]
      if (name in target) target[name] = root[name]
    }
  }

  // -------------------------------------------------------------- refresh

  function refreshList() {
    if (listProc.running) return
    listProc.command = [root.ctlPath, "list"]
    listProc.running = true
  }

  function refreshStats() {
    if (!root.opened || statsProc.running) return
    statsProc.command = [root.ctlPath, "stats"]
    statsProc.running = true
  }

  function applyList(text, code) {
    if (code !== 0) {
      root.listError = Model.clean(text) || "daemon-unreachable"
      root.rows = []
    } else {
      root.listError = ""
      root.rows = Model.parseList(text)
    }
    root.injectPanel()
  }

  function applyStats(text, code) {
    if (code !== 0) return
    var parsed = Model.parseStats(text)
    root.stats = parsed.byName
    root.statsNproc = parsed.nproc
    root.statsMemTotalBytes = parsed.memTotalBytes
    root.injectPanel()
  }

  // -------------------------------------------------------------- actions

  // Refused rather than queued: a second click while one action is still in
  // flight would otherwise race it against a `list` refresh that has not
  // caught up yet.
  function runAction(action, name, extraArg) {
    if (root.busyAction !== "") return "busy"
    root.busyAction = action
    root.busyName = name
    root.injectPanel()
    var args = [root.ctlPath, action, name]
    if (extraArg !== undefined) args.push(String(extraArg))
    actionProc.command = args
    actionProc.running = true
    return "ok"
  }

  function start(name) { return root.runAction("start", name) }
  function stop(name) { return root.runAction("stop", name, root.stopTimeoutSec) }
  function restart(name) { return root.runAction("restart", name) }
  function pauseContainer(name) { return root.runAction("pause", name) }
  function unpauseContainer(name) { return root.runAction("unpause", name) }
  function killContainer(name) { return root.runAction("kill", name) }
  function removeContainer(name) { return root.runAction("remove", name) }

  function openLogs(name) { Quickshell.execDetached([root.ctlPath, "logs", name]) }
  function openShell(name) { Quickshell.execDetached([root.ctlPath, "shell", name]) }
  function openPort(name, port) { Quickshell.execDetached([root.ctlPath, "open", name, String(port)]) }

  // The panel calls this once it has put the confirmation dialog on screen
  // for a pending IPC-triggered remove, so the same request cannot re-open
  // the dialog on every mirror tick.
  function clearPendingRemove() {
    root.pendingRemove = ""
    root.injectPanel()
  }

  function requestRemove(name) {
    root.pendingRemove = name
    root.injectPanel()
    root.open()
  }

  // -------------------------------------------------------------- lifecycle

  function open() {
    if (panelLoader.item) panelLoader.item.open()
    root.refreshList()
    root.refreshStats()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  Component.onCompleted: root.refreshList()
  onBarChanged: root.injectPanel()
  onSettingsChanged: root.injectPanel()
  onOpenedChanged: if (root.opened) { root.refreshList(); root.refreshStats() }

  Timer {
    // Fast while the popup is open, backed off while it is closed — the bar
    // badge and urgent colour stay reasonably fresh either way without
    // paying the open cadence when nobody is looking.
    interval: (root.opened ? root.listRefreshSec : 30) * 1000
    repeat: true
    running: true
    onTriggered: root.refreshList()
  }

  Timer {
    // `docker stats` waits about two seconds for a sample no matter how many
    // containers exist, against tens of milliseconds for `list` — its own,
    // slower timer, and only while the popup is actually open to read it.
    interval: root.statsRefreshSec * 1000
    repeat: true
    running: root.opened
    onTriggered: root.refreshStats()
  }

  Process {
    id: listProc
    property string outText: ""
    property string errText: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: listProc.outText = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: listProc.errText = text }
    onExited: function(code) {
      root.applyList(code === 0 ? listProc.outText : listProc.errText, code)
      listProc.outText = ""
      listProc.errText = ""
    }
  }

  Process {
    id: statsProc
    property string outText: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: statsProc.outText = text }
    onExited: function(code) {
      root.applyStats(code === 0 ? statsProc.outText : "", code)
      statsProc.outText = ""
    }
  }

  Process {
    id: actionProc
    property string stderrText: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: actionProc.stderrText = text }
    onExited: function(code) {
      root.actionError = code === 0 ? "" : (Model.clean(actionProc.stderrText) || (root.busyAction + "-failed"))
      root.busyAction = ""
      root.busyName = ""
      actionProc.stderrText = ""
      root.injectPanel()
      root.refreshList()
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      // `bar` and `settings` are injected into this widget by the host and
      // can land after onLoaded.
      Qt.callLater(root.injectPanel)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "io.github.majkelll.omarchy-docker"
    function list(): string { return Model.summary(root.rows) }
    function refresh(): void { root.refreshList() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(name: string): string { return root.start(name) }
    function stop(name: string): string { return root.stop(name) }
    function restart(name: string): string { return root.restart(name) }
    function pause(name: string): string { return root.pauseContainer(name) }
    function unpause(name: string): string { return root.unpauseContainer(name) }
    function kill(name: string): string { return root.killContainer(name) }
    // Never removes outright — puts the confirmation dialog on screen, same
    // as a click on the row's own Remove button.
    function remove(name: string): void { root.requestRemove(name) }
    function logs(name: string): void { root.openLogs(name) }
    function shell(name: string): void { root.openShell(name) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.GLYPH.docker
    fontSize: Style.font.icon
    active: root.attentionCount > 0 || root.listError !== ""
    dimmed: root.rows.length === 0 && root.listError === ""
    tooltipText: root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        root.refreshList()
        return
      }
      root.toggle()
    }
  }
}
