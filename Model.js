// Pure parsing, state rules, and formatting for the Docker panel. Deliberately
// free of Qt so the same file backs the QML plugin and the Node tests in
// tests/. Nothing here shells out to anything — that is bin/omarchy-docker-ctl's
// job alone.

// bin/omarchy-docker-ctl already bounds every read it produces; these bound
// what this file is willing to parse even if it were ever handed something
// else — a replaced helper, a stray file, a partial read.
var MAX_INPUT = 262144   // characters accepted from one helper run
var MAX_ROWS = 200       // rows kept
var MAX_FIELD = 512      // characters kept per field

var FIELDS = 8 // name, image, state, status, project, health, restarts, ports

var GLYPH = {
  docker: "󰡨",
  alert: "󰀦",
  start: "󰐊",
  stop: "󰓛",
  restart: "󰑓",
  remove: "󰩺",
  logs: "󰦪",
  shell: "󰆍",
  pause: "󰏤",
  play: "󰐊",
  kill: "󰚌",
  web: "󰖟"
}

function clean(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function clip(value) {
  return String(value === undefined || value === null ? "" : value).slice(0, MAX_FIELD)
}

function toInt(value, fallback) {
  var parsed = parseInt(value, 10)
  return isFinite(parsed) ? parsed : fallback
}

function toFloat(value, fallback) {
  var parsed = parseFloat(value)
  return isFinite(parsed) ? parsed : fallback
}

// -------------------------------------------------------------------- states

// What docker's container states actually permit. A single running/stopped
// guess produces wrong offers: a paused container cannot be started (only
// unpaused) and docker refuses to remove it, and a container mid restart
// loop is very much not "stopped" — which is also why `active` (occupies
// resources right now), not a running flag, is what the bar counts.
var STATES = {
  running:    { start: false, stopRestart: true,  remove: false, active: true,  pause: true,  unpause: false, kill: true },
  paused:     { start: false, stopRestart: true,  remove: false, active: true,  pause: false, unpause: true,  kill: false },
  restarting: { start: false, stopRestart: true,  remove: false, active: true,  pause: false, unpause: false, kill: true },
  created:    { start: true,  stopRestart: false, remove: true,  active: false, pause: false, unpause: false, kill: false },
  exited:     { start: true,  stopRestart: false, remove: true,  active: false, pause: false, unpause: false, kill: false },
  dead:       { start: false, stopRestart: false, remove: true,  active: false, pause: false, unpause: false, kill: false },
  removing:   { start: false, stopRestart: false, remove: false, active: false, pause: false, unpause: false, kill: false }
}

// An unknown state offers nothing rather than guessing — a future docker
// state should make the panel quiet, not make it propose actions docker
// would refuse.
var UNKNOWN_STATE = { start: false, stopRestart: false, remove: false, active: false, pause: false, unpause: false, kill: false }

function stateRules(state) {
  return STATES[String(state || "")] || UNKNOWN_STATE
}

// docker reports health twice: structurally (State.Health.Status, which the
// helper puts in field 5) and inside the status string ("Up 3m (unhealthy)").
// The structured field is authoritative; this is the fallback for a helper
// run against an older docker that left it blank.
function healthOf(status) {
  var text = String(status || "")
  if (text.indexOf("(unhealthy)") !== -1) return "unhealthy"
  if (text.indexOf("(health: starting)") !== -1) return "starting"
  if (text.indexOf("(healthy)") !== -1) return "healthy"
  return ""
}

// A row worth looking at: failing its healthcheck, stuck restarting, or
// dead. Drives both the row colour and the bar's urgent state. Health only
// means something while the container is up — docker keeps reporting the
// last verdict after a stop, and painting a deliberately stopped container
// red because its final probe failed would be noise, not news.
function needsAttention(row) {
  if (!row) return false
  if (row.state === "restarting" || row.state === "dead") return true
  return !!row.active && row.health === "unhealthy"
}

// --------------------------------------------------------------------- list

// "8080>80/tcp 5432>5432/tcp" -> [{host, container, proto}], read from
// HostConfig.PortBindings, which — unlike NetworkSettings.Ports — survives a
// stopped container. udp duplicates of a tcp port are dropped so they do not
// show as a second identical-looking entry.
function parsePorts(raw) {
  var out = []
  var seen = {}
  var parts = String(raw || "").trim().split(/\s+/)
  for (var i = 0; i < parts.length && out.length < 16; i++) {
    var m = /^(\d{1,5})>(\d{1,5})\/(tcp|udp)$/.exec(parts[i])
    if (!m) continue
    if (m[3] !== "tcp") continue
    if (seen[m[1]]) continue
    seen[m[1]] = true
    out.push({ host: parseInt(m[1], 10), container: parseInt(m[2], 10), proto: m[3] })
  }
  return out
}

// One line per container, \x1f separated:
//   name \x1f image \x1f state \x1f status \x1f project \x1f health \x1f restarts \x1f ports
// A short row is a truncated read, not a container: it is dropped rather
// than half-parsed.
function parseList(raw) {
  var rows = []
  var lines = String(raw || "").slice(0, MAX_INPUT).split("\n")
  for (var i = 0; i < lines.length && rows.length < MAX_ROWS; i++) {
    if (!lines[i]) continue
    var f = lines[i].split("\x1f")
    if (f.length < FIELDS) continue

    var state = clip(f[2])
    var status = clip(f[3])
    rows.push({
      name: clip(f[0]),
      image: clip(f[1]),
      state: state,
      status: status,
      project: clip(f[4]),
      health: clip(f[5]) || healthOf(status),
      restarts: Math.max(0, toInt(f[6], 0)),
      ports: parsePorts(f[7]),
      running: state === "running",
      active: stateRules(state).active
    })
  }
  return rows
}

function findRow(rows, name) {
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i]
  return null
}

// docker's own status string is already the best description of a running
// container ("Up 13 minutes"); only the created case, which docker leaves
// blank, needs help.
function statusText(row) {
  if (!row) return ""
  if (row.status) return row.status
  return row.state === "created" ? "Created" : row.state
}

// -------------------------------------------------------------------- stats

// "12.8MiB" / "1.658GiB" / "400KiB" -> bytes. bash cannot do this math
// cleanly, so the helper leaves the strings alone and it happens here.
var MEM_UNITS = {
  b: 1,
  kib: 1024, mib: 1024 * 1024, gib: 1024 * 1024 * 1024, tib: 1024 * 1024 * 1024 * 1024,
  kb: 1000, mb: 1e6, gb: 1e9, tb: 1e12
}

function parseMemString(raw) {
  var text = clean(raw)
  var m = /^([0-9.]+)\s*([A-Za-z]+)$/.exec(text)
  if (!m) return 0
  var value = toFloat(m[1], 0)
  var mult = MEM_UNITS[m[2].toLowerCase()]
  return mult ? value * mult : 0
}

function parsePercentString(raw) {
  return toFloat(String(raw || "").replace("%", ""), 0)
}

// The `stats` output's first line is metadata, not a container:
//   #meta \x1f <nproc> \x1f <memTotalKB>
// Everything after is `name \x1f cpuPerc \x1f memUsage \x1f memPerc`, where
// memUsage is docker's own "<used> / <limit>" string. Only running
// containers appear here — docker stats says nothing about the others.
function parseStats(raw) {
  var lines = String(raw || "").slice(0, MAX_INPUT).split("\n")
  var nproc = 1
  var memTotalBytes = 0
  var start = 0

  if (lines.length > 0 && lines[0]) {
    var meta = lines[0].split("\x1f")
    if (clean(meta[0]) === "#meta") {
      nproc = Math.max(1, toInt(meta[1], 1))
      memTotalBytes = Math.max(0, toInt(meta[2], 0)) * 1024
      start = 1
    }
  }

  var byName = {}
  var kept = 0
  for (var i = start; i < lines.length && kept < MAX_ROWS; i++) {
    if (!lines[i]) continue
    var f = lines[i].split("\x1f")
    if (f.length < 4) continue
    var name = clip(f[0])
    if (name === "") continue

    var usage = String(f[2] || "").split("/")
    byName[name] = {
      cpuPercent: parsePercentString(f[1]),
      memUsedBytes: parseMemString(usage[0]),
      memLimitBytes: usage.length > 1 ? parseMemString(usage[1]) : 0,
      memPercent: parsePercentString(f[3])
    }
    kept++
  }

  return { nproc: nproc, memTotalBytes: memTotalBytes, byName: byName }
}

// Docker's CPU% is relative to a single core, so a machine fully loaded by
// containers reads far past 100% before this normalizes it against the
// number of cores — the number this returns is "percent of the whole
// machine", which is what the popup's totals line claims to say.
function totalStats(byName, nproc, memTotalBytes) {
  var cpuSum = 0
  var memSum = 0
  var count = 0
  var rows = byName || {}
  for (var name in rows) {
    cpuSum += rows[name].cpuPercent || 0
    memSum += rows[name].memUsedBytes || 0
    count++
  }
  var cores = Math.max(1, Number(nproc) || 1)
  var memTotal = Math.max(0, Number(memTotalBytes) || 0)
  return {
    containerCount: count,
    cpuPercentOfSystem: cpuSum / cores,
    memUsedBytes: memSum,
    memTotalBytes: memTotal,
    memPercentOfSystem: memTotal > 0 ? (memSum / memTotal) * 100 : 0
  }
}

function formatPercent(value) {
  return Math.round(Number(value) || 0) + "%"
}

function formatBytes(value) {
  var bytes = Math.max(0, Number(value) || 0)
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var unit = 0
  while (bytes >= 1024 && unit < units.length - 1) {
    bytes /= 1024
    unit++
  }
  var precision = bytes >= 100 || unit === 0 ? 0 : (bytes >= 10 ? 1 : 2)
  return bytes.toFixed(precision) + " " + units[unit]
}

// ------------------------------------------------------------------- actions

// The row's own buttons, in the order they are drawn — Stop and Restart (or
// Start) work straight from the list, which is what answers "stop and reset
// it" without opening the row first. Remove is offered only where docker
// will actually allow it, so no click here can ask to destroy a container
// that is still doing something.
function rowActions(row) {
  if (!row) return []
  var rules = stateRules(row.state)
  var actions = []
  if (rules.stopRestart) {
    actions.push({ id: "restart", icon: GLYPH.restart, tooltip: "Restart", urgent: false })
    actions.push({ id: "stop", icon: GLYPH.stop, tooltip: "Stop", urgent: true })
  }
  if (rules.start) actions.push({ id: "start", icon: GLYPH.start, tooltip: "Start", urgent: false })
  if (rules.remove) actions.push({ id: "remove", icon: GLYPH.remove, tooltip: "Remove container…", urgent: true })
  return actions
}

// Everything that does not earn a permanent row button — shown once a row
// is expanded. Built from the container's state, so it never offers
// something docker would refuse.
function rowMenuActions(row) {
  if (!row) return []
  var rules = stateRules(row.state)
  var items = []

  items.push({ id: "logs", icon: GLYPH.logs, label: "View logs" })
  if (row.running) items.push({ id: "shell", icon: GLYPH.shell, label: "Open a shell" })
  if (rules.pause) items.push({ id: "pause", icon: GLYPH.pause, label: "Pause" })
  if (rules.unpause) items.push({ id: "unpause", icon: GLYPH.play, label: "Resume" })
  if (rules.kill) items.push({ id: "kill", icon: GLYPH.kill, label: "Kill now", urgent: true })

  // A published port survives a stop, but nothing is listening on it, so
  // the entry is offered only while the container is actually running.
  var ports = Array.isArray(row.ports) ? row.ports : []
  for (var i = 0; row.running && i < ports.length && i < 8; i++) {
    items.push({ id: "open", icon: GLYPH.web, label: "Open 127.0.0.1:" + ports[i].host, arg: String(ports[i].host) })
  }

  return items
}

// The second line under a container's name: docker's own status (uptime,
// or "Exited …") plus live CPU/RAM when known — nothing else. Health,
// compose project, restart count, and ports are only interesting once you
// have already decided to look closer, so they live in expandedMeta/the
// expanded row instead of crowding the list.
function rowStatLine(row, stat) {
  if (!stat) return ""
  return "cpu " + formatPercent(stat.cpuPercent) + " · " + formatBytes(stat.memUsedBytes)
}

// The extra context shown only once a row is expanded: health (while it
// means something — active and not a plain "healthy"), compose project,
// restart count. Ports get their own line next to this, since there can be
// several.
function expandedMeta(row) {
  if (!row) return ""
  var parts = []
  if (row.active && row.health && row.health !== "healthy") parts.push(row.health)
  if (row.project) parts.push(row.project)
  if (row.restarts > 0) parts.push(row.restarts + (row.restarts === 1 ? " restart" : " restarts"))
  return parts.join(" · ")
}

function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function busyLabel(action) {
  switch (action) {
    case "start": return "Starting…"
    case "stop": return "Stopping…"
    case "restart": return "Restarting…"
    case "pause": return "Pausing…"
    case "unpause": return "Resuming…"
    case "kill": return "Killing…"
    case "remove": return "Removing…"
    default: return "Working…"
  }
}

// -------------------------------------------------------------------- summary

function summary(rows) {
  var list = Array.isArray(rows) ? rows : []
  if (list.length === 0) return "No containers"

  var running = 0, restarting = 0, paused = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i].state === "running") running++
    else if (list[i].state === "restarting") restarting++
    else if (list[i].state === "paused") paused++
  }
  var stopped = list.length - running - restarting - paused

  var parts = []
  if (running > 0) parts.push(running + " running")
  if (restarting > 0) parts.push(restarting + " restarting")
  if (paused > 0) parts.push(paused + " paused")
  if (stopped > 0) parts.push(stopped + " stopped")
  return parts.join(" · ")
}

function attentionCount(rows) {
  var list = Array.isArray(rows) ? rows : []
  var n = 0
  for (var i = 0; i < list.length; i++) if (needsAttention(list[i])) n++
  return n
}

// The helper speaks in short codes so the panel owns the wording.
function errorText(code) {
  switch (clean(code)) {
    case "": return ""
    case "docker-missing": return "Docker is not installed"
    case "daemon-unreachable": return "Docker daemon is not running"
    case "docker-permission": return "No permission on Docker's socket"
    case "no-container": return "No container given"
    case "no-such-container": return "Container no longer exists"
    case "container-not-running": return "Start the container first"
    case "terminal-missing": return "No terminal launcher found"
    case "browser-missing": return "No browser launcher found"
    case "start-failed": return "Could not start the container"
    case "stop-failed": return "Could not stop the container"
    case "restart-failed": return "Could not restart the container"
    case "pause-failed": return "Could not pause the container"
    case "unpause-failed": return "Could not resume the container"
    case "kill-failed": return "Could not kill the container"
    case "remove-failed": return "Could not remove the container"
    case "unknown-command": return "Internal error: unknown command"
    case "unknown-action": return "Internal error: unknown action"
    default:
      var text = clean(code)
      // The helper forwards docker's own first line for anything it cannot
      // name, plus `not-removable:<state>` for a state docker will not
      // let go.
      if (text.indexOf("not-removable:") === 0) {
        var state = text.slice("not-removable:".length)
        if (state === "paused") return "Unpause the container before removing it"
        if (state === "restarting") return "The container is restarting — stop it first"
        if (state === "running") return "Stop the container before removing it"
        return "Docker will not remove a container in state \"" + state + "\""
      }
      return text
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_INPUT: MAX_INPUT,
    MAX_ROWS: MAX_ROWS,
    MAX_FIELD: MAX_FIELD,
    FIELDS: FIELDS,
    GLYPH: GLYPH,
    clean: clean,
    clip: clip,
    stateRules: stateRules,
    healthOf: healthOf,
    needsAttention: needsAttention,
    parsePorts: parsePorts,
    parseList: parseList,
    findRow: findRow,
    statusText: statusText,
    parseMemString: parseMemString,
    parsePercentString: parsePercentString,
    parseStats: parseStats,
    totalStats: totalStats,
    formatPercent: formatPercent,
    formatBytes: formatBytes,
    rowActions: rowActions,
    rowMenuActions: rowMenuActions,
    rowStatLine: rowStatLine,
    expandedMeta: expandedMeta,
    clampIndex: clampIndex,
    busyLabel: busyLabel,
    summary: summary,
    attentionCount: attentionCount,
    errorText: errorText
  }
}
