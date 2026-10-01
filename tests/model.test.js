const assert = require("assert")
const Model = require("../Model.js")

// ---------------------------------------------------------------- stateRules

assert.deepStrictEqual(Model.stateRules("running"), {
  start: false, stopRestart: true, remove: false, active: true, pause: true, unpause: false, kill: true
})
assert.deepStrictEqual(Model.stateRules("paused"), {
  start: false, stopRestart: true, remove: false, active: true, pause: false, unpause: true, kill: false
})
assert.deepStrictEqual(Model.stateRules("restarting"), {
  start: false, stopRestart: true, remove: false, active: true, pause: false, unpause: false, kill: true
})
assert.deepStrictEqual(Model.stateRules("created"), {
  start: true, stopRestart: false, remove: true, active: false, pause: false, unpause: false, kill: false
})
assert.deepStrictEqual(Model.stateRules("exited"), {
  start: true, stopRestart: false, remove: true, active: false, pause: false, unpause: false, kill: false
})
assert.deepStrictEqual(Model.stateRules("dead"), {
  start: false, stopRestart: false, remove: true, active: false, pause: false, unpause: false, kill: false
})
assert.deepStrictEqual(Model.stateRules("removing"), {
  start: false, stopRestart: false, remove: false, active: false, pause: false, unpause: false, kill: false
})
// An unrecognised state offers nothing rather than guessing.
assert.deepStrictEqual(Model.stateRules("something-new"), {
  start: false, stopRestart: false, remove: false, active: false, pause: false, unpause: false, kill: false
})

// ------------------------------------------------------------------ parseList

const listRaw = [
  ["web", "nginx:alpine", "running", "Up 3 minutes", "myapp", "healthy", "0", "8080>80/tcp 8443>443/tcp"].join("\x1f"),
  ["db", "postgres:18-alpine", "running", "Up 3 minutes (unhealthy)", "myapp", "", "2", ""].join("\x1f"),
  ["worker", "myapp-worker", "restarting", "Restarting (1) 5 seconds ago", "", "", "7", ""].join("\x1f"),
  ["old", "alpine:latest", "exited", "Exited (0) 2 hours ago", "", "", "0", ""].join("\x1f"),
  // A short row — fewer than FIELDS entries — is a truncated read, dropped.
  ["broken", "image"].join("\x1f"),
  ""
].join("\n")

const rows = Model.parseList(listRaw)
assert.strictEqual(rows.length, 4)

assert.strictEqual(rows[0].name, "web")
assert.strictEqual(rows[0].health, "healthy")
assert.strictEqual(rows[0].active, true)
assert.strictEqual(rows[0].running, true)
assert.deepStrictEqual(rows[0].ports, [
  { host: 8080, container: 80, proto: "tcp" },
  { host: 8443, container: 443, proto: "tcp" }
])

// Health falls back to parsing the status string when the structured field
// (which docker leaves blank on older daemons) is empty.
assert.strictEqual(rows[1].health, "unhealthy")
assert.strictEqual(Model.needsAttention(rows[1]), true)

assert.strictEqual(rows[2].state, "restarting")
assert.strictEqual(rows[2].active, true)
assert.strictEqual(rows[2].running, false)
assert.strictEqual(Model.needsAttention(rows[2]), true)

assert.strictEqual(rows[3].active, false)
assert.strictEqual(Model.needsAttention(rows[3]), false)

assert.strictEqual(Model.findRow(rows, "db").name, "db")
assert.strictEqual(Model.findRow(rows, "nope"), null)

assert.strictEqual(Model.statusText({ status: "Up 3 minutes" }), "Up 3 minutes")
assert.strictEqual(Model.statusText({ status: "", state: "created" }), "Created")

// ------------------------------------------------------------------ parsePorts

assert.deepStrictEqual(Model.parsePorts("8080>80/tcp 5432>5432/udp  9000>9000/tcp"), [
  { host: 8080, container: 80, proto: "tcp" },
  { host: 9000, container: 9000, proto: "tcp" }
])
assert.deepStrictEqual(Model.parsePorts(""), [])
assert.deepStrictEqual(Model.parsePorts(">5432/tcp"), []) // an unresolved dynamic binding is skipped, not half-parsed

// ------------------------------------------------------------------ parseStats

const statsRaw = [
  "#meta\x1f8\x1f16000000",
  "web\x1f12.34%\x1f340MiB / 1.9GiB\x1f17.89%",
  "db\x1f0.50%\x1f81.72MiB / 1.9GiB\x1f4.20%",
  ""
].join("\n")

const stats = Model.parseStats(statsRaw)
assert.strictEqual(stats.nproc, 8)
assert.strictEqual(stats.memTotalBytes, 16000000 * 1024)
assert.strictEqual(Object.keys(stats.byName).length, 2)
assert.strictEqual(stats.byName.web.cpuPercent, 12.34)
assert.strictEqual(Math.round(stats.byName.web.memUsedBytes), Math.round(340 * 1024 * 1024))
assert.strictEqual(stats.byName.web.memPercent, 17.89)

// Missing the #meta line entirely still parses container rows, just with
// the safe defaults (1 core, no known total).
const statsNoMeta = Model.parseStats("web\x1f5.00%\x1f10MiB / 1GiB\x1f1.00%")
assert.strictEqual(statsNoMeta.nproc, 1)
assert.strictEqual(statsNoMeta.memTotalBytes, 0)
assert.strictEqual(Object.keys(statsNoMeta.byName).length, 1)

assert.strictEqual(Model.parseMemString("400KiB"), 400 * 1024)
assert.strictEqual(Model.parseMemString("1.658GiB"), 1.658 * 1024 * 1024 * 1024)
assert.strictEqual(Model.parseMemString("0B"), 0)
assert.strictEqual(Model.parseMemString("garbage"), 0)
assert.strictEqual(Model.parsePercentString("42.73%"), 42.73)
assert.strictEqual(Model.parsePercentString(""), 0)

// ------------------------------------------------------------------ totalStats

const total = Model.totalStats(stats.byName, stats.nproc, stats.memTotalBytes)
assert.strictEqual(total.containerCount, 2)
// 12.34 + 0.50 = 12.84, normalized against 8 cores.
assert.ok(Math.abs(total.cpuPercentOfSystem - 12.84 / 8) < 1e-9)
assert.ok(Math.abs(total.memUsedBytes - (stats.byName.web.memUsedBytes + stats.byName.db.memUsedBytes)) < 1)
assert.ok(total.memPercentOfSystem > 0 && total.memPercentOfSystem < 5)

// Never divides by zero cores or a zero total.
const zeroTotal = Model.totalStats({}, 0, 0)
assert.strictEqual(zeroTotal.cpuPercentOfSystem, 0)
assert.strictEqual(zeroTotal.memPercentOfSystem, 0)

// ------------------------------------------------------------------ formatting

assert.strictEqual(Model.formatPercent(12.6), "13%")
assert.strictEqual(Model.formatPercent(0), "0%")
assert.strictEqual(Model.formatBytes(0), "0 B")
assert.strictEqual(Model.formatBytes(512), "512 B")
assert.strictEqual(Model.formatBytes(1024), "1.00 KiB")
assert.strictEqual(Model.formatBytes(1536), "1.50 KiB")
assert.strictEqual(Model.formatBytes(1024 * 1024 * 340), "340 MiB")
assert.strictEqual(Model.formatBytes(1024 * 1024 * 1024 * 1.5), "1.50 GiB")

// -------------------------------------------------------------------- actions

const runningRow = { state: "running", running: true, ports: [{ host: 8080, container: 80, proto: "tcp" }] }
const runningActions = Model.rowActions(runningRow).map(a => a.id)
assert.deepStrictEqual(runningActions, ["restart", "stop"])

const exitedRow = { state: "exited", running: false, ports: [] }
assert.deepStrictEqual(Model.rowActions(exitedRow).map(a => a.id), ["start", "remove"])

const pausedRow = { state: "paused", running: false, ports: [] }
assert.deepStrictEqual(Model.rowActions(pausedRow).map(a => a.id), ["restart", "stop"])

const deadRow = { state: "dead", running: false, ports: [] }
assert.deepStrictEqual(Model.rowActions(deadRow).map(a => a.id), ["remove"])

const runningMenu = Model.rowMenuActions(runningRow).map(a => a.id)
assert.deepStrictEqual(runningMenu, ["logs", "shell", "pause", "kill", "open"])

const pausedMenu = Model.rowMenuActions(pausedRow).map(a => a.id)
assert.deepStrictEqual(pausedMenu, ["logs", "unpause"])

const exitedMenu = Model.rowMenuActions(exitedRow).map(a => a.id)
assert.deepStrictEqual(exitedMenu, ["logs"])

// A published port is never offered while the container is not running —
// nothing would be listening on it.
assert.deepStrictEqual(
  Model.rowMenuActions({ state: "exited", running: false, ports: [{ host: 8080, container: 80, proto: "tcp" }] }).map(a => a.id),
  ["logs"]
)

assert.strictEqual(Model.clampIndex(5, 3), 2)
assert.strictEqual(Model.clampIndex(-1, 3), 0)
assert.strictEqual(Model.clampIndex(1, 0), 0)

// ------------------------------------------------------------------ row text

// The row's own line is up-time plus live CPU/RAM, nothing else — no
// health, project, restarts, or ports. Those only show once expanded.
assert.strictEqual(Model.rowStatLine(runningRow, undefined), "")
assert.strictEqual(
  Model.rowStatLine(runningRow, { cpuPercent: 12.34, memUsedBytes: 1024 * 1024 * 340 }),
  "cpu 12% · 340 MiB"
)

assert.strictEqual(Model.expandedMeta({ active: false, health: "", project: "", restarts: 0 }), "")
assert.strictEqual(
  Model.expandedMeta({ active: true, health: "unhealthy", project: "myapp", restarts: 2 }),
  "unhealthy · myapp · 2 restarts"
)
// Health only means something while the container is active; a stopped
// container's last (possibly failing) probe isn't news.
assert.strictEqual(
  Model.expandedMeta({ active: false, health: "unhealthy", project: "", restarts: 0 }),
  ""
)
assert.strictEqual(Model.expandedMeta({ active: true, health: "healthy", project: "", restarts: 1 }), "1 restart")

assert.strictEqual(Model.busyLabel("stop"), "Stopping…")
assert.strictEqual(Model.busyLabel("nonsense"), "Working…")

// -------------------------------------------------------------------- summary

assert.strictEqual(Model.summary([]), "No containers")
assert.strictEqual(Model.summary([{ state: "running" }, { state: "running" }, { state: "exited" }]), "2 running · 1 stopped")
assert.strictEqual(Model.summary([{ state: "restarting" }, { state: "paused" }]), "1 restarting · 1 paused")

assert.strictEqual(Model.attentionCount(rows), 2) // db (unhealthy), worker (restarting)

// ----------------------------------------------------------------- errorText

assert.strictEqual(Model.errorText(""), "")
assert.strictEqual(Model.errorText("docker-missing"), "Docker is not installed")
assert.strictEqual(Model.errorText("daemon-unreachable"), "Docker daemon is not running")
assert.strictEqual(Model.errorText("not-removable:running"), "Stop the container before removing it")
assert.strictEqual(Model.errorText("compose-file-missing"), "The project's compose file no longer exists")
assert.strictEqual(Model.errorText("editor-missing"), "No editor launcher found")
assert.strictEqual(Model.errorText("group-edit-failed"), "Could not open the compose file")
assert.strictEqual(Model.errorText("not-removable:paused"), "Unpause the container before removing it")
assert.strictEqual(Model.errorText("not-removable:restarting"), "The container is restarting — stop it first")
assert.strictEqual(Model.errorText("not-removable:weird"), "Docker will not remove a container in state \"weird\"")
// docker's own stderr first line, forwarded verbatim by the helper for
// anything it has no name for.
assert.strictEqual(Model.errorText("port is already allocated"), "port is already allocated")
assert.strictEqual(Model.errorText("no-project"), "No compose project given")
assert.strictEqual(Model.errorText("compose-missing"), "Docker Compose is not installed")
assert.strictEqual(Model.errorText("group-stop-failed"), "Could not stop the project")

// --------------------------------------------------------------------- groups

const groupRows = Model.parseList([
  ["shop-web-1", "nginx", "running", "Up 1 minute", "shop", "", "0", ""],
  ["standalone", "alpine", "exited", "Exited (0) 1 hour ago", "", "", "0", ""],
  ["shop-db-1", "mysql", "exited", "Exited (0) 1 hour ago", "shop", "", "0", ""],
  ["api-app-1", "php", "restarting", "Restarting (1) 2 seconds ago", "api", "", "3", ""]
].map(f => f.join("\x1f")).join("\n"))

const itemLabels = items => items.map(i => i.kind + ":" + (i.kind === "group" ? i.key : i.row.name))

// Collapsed: one header per compose project, alphabetical, then every
// container without a project on its own.
const collapsed = Model.buildItems(groupRows, true, {})
assert.deepStrictEqual(itemLabels(collapsed), ["group:api", "group:shop", "container:standalone"])
assert.strictEqual(collapsed[1].expanded, false)
assert.deepStrictEqual(collapsed[1].rows.map(r => r.name), ["shop-db-1", "shop-web-1"])
assert.strictEqual(collapsed[2].depth, 0)
assert.strictEqual(collapsed[2].group, "")

// Expanded: the members follow their header, sorted by name, one level in.
const expandedItems = Model.buildItems(groupRows, true, { shop: true })
assert.deepStrictEqual(itemLabels(expandedItems),
  ["group:api", "group:shop", "container:shop-db-1", "container:shop-web-1", "container:standalone"])
assert.strictEqual(expandedItems[1].expanded, true)
assert.strictEqual(expandedItems[2].depth, 1)
assert.strictEqual(expandedItems[2].group, "shop")

// Grouping off is the plain list, in docker's own order.
const flatItems = Model.buildItems(groupRows, false, { shop: true })
assert.deepStrictEqual(itemLabels(flatItems),
  ["container:shop-web-1", "container:standalone", "container:shop-db-1", "container:api-app-1"])
assert.ok(flatItems.every(i => i.depth === 0 && i.group === ""))

// A project name is a label anyone can set; one that collides with an
// Object.prototype key must still group like any other.
const protoItems = Model.buildItems(Model.parseList(
  ["odd", "alpine", "exited", "", "__proto__", "", "0", ""].join("\x1f")), true, {})
assert.deepStrictEqual(itemLabels(protoItems), ["group:__proto__"])

assert.deepStrictEqual(Model.buildItems([], true, { gone: true }), [])
assert.deepStrictEqual(Model.buildItems(null, true, null), [])

assert.strictEqual(Model.groupIndexOf(expandedItems, "shop"), 1)
assert.strictEqual(Model.groupIndexOf(expandedItems, "nope"), -1)

// A group offers what its members would in aggregate: Start while anything
// could start, Restart and Stop while anything is up — after Edit, which
// any project offers whatever its state, so the lifecycle buttons keep
// their places at the end of the row.
const groupIds = rowsIn => Model.groupActions(rowsIn).map(a => a.id)
assert.deepStrictEqual(groupIds([{ state: "running" }, { state: "running" }]), ["edit", "restart", "stop"])
assert.deepStrictEqual(groupIds([{ state: "exited" }, { state: "created" }]), ["edit", "start"])
assert.deepStrictEqual(groupIds([{ state: "running" }, { state: "exited" }]), ["edit", "start", "restart", "stop"])
assert.deepStrictEqual(groupIds([{ state: "paused" }]), ["edit", "restart", "stop"])
// Nothing in a group of dead containers can be started or stopped, but its
// compose file can still be opened.
assert.deepStrictEqual(groupIds([{ state: "dead" }]), ["edit"])
assert.deepStrictEqual(groupIds([]), [])
assert.strictEqual(Model.groupActions([{ state: "running" }])[0].icon, Model.GLYPH.edit)

// A group's CPU/RAM is the sum of its members' — the same single-core
// relative CPU figure each row shows, so the header reads as their total.
const groupStats = {
  "shop-web-1": { cpuPercent: 10.2, memUsedBytes: 1024 * 1024 * 100 },
  "shop-db-1": { cpuPercent: 2.3, memUsedBytes: 1024 * 1024 * 50 },
  "api-app-1": { cpuPercent: 99, memUsedBytes: 1024 * 1024 * 999 }
}
assert.strictEqual(Model.groupStatLine(collapsed[1].rows, groupStats), "cpu 13% · 150 MiB")
assert.strictEqual(Model.groupStatLine(collapsed[1].rows, {}), "")
assert.strictEqual(Model.groupStatLine(collapsed[1].rows, undefined), "")

console.log("All Model.js tests passed")
