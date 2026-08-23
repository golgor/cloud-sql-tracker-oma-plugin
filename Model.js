// Pure parse and mapping for the cloud-sql-tracker Status document (schema
// version 1). No QML imports, no Process, no file I/O — see docs/modules.md.
// Tracker.qml calls parseStatusDocument(text) with the raw stdout of
// `cloud-sql-tracker status --json` and uses the result to build its view.
// This file must stay callable from plain Node (see the module.exports
// guard at the bottom) so it can run outside the Quickshell runtime.

// Health state values recognized by the control plane
// (docs/status-document.v1.md, CONTEXT.md "Health state"). Any other value
// is unexpected — parseHealthState falls back to "error" rather than
// letting an unrecognized state look healthy.
var KNOWN_HEALTH_STATES = ["stopped", "starting", "running", "error"]

// Parse one `status --json` response into the shape Tracker needs.
//
// Success:
//   { ok: true, degraded: null, version: 1, ts, cliVersion,
//     running, starting, error, stopped, total, groups, connections }
//
// Failure (malformed JSON or unsupported schema version):
//   { ok: false, degraded: { kind: "schema", message }, version, ts: null,
//     cliVersion: null, running: 0, starting: 0, error: 0, stopped: 0,
//     total: 0, groups: [], connections: [] }
//
// Unknown fields anywhere in the document are ignored, per the Status
// document consumer checklist.
function parseStatusDocument(text) {
  var parsed
  try {
    parsed = JSON.parse(String(text))
  } catch (e) {
    return schemaFailure("Status document was not valid JSON.", null)
  }

  if (!parsed || typeof parsed !== "object") {
    return schemaFailure("Status document was not a JSON object.", null)
  }

  if (parsed.version !== 1) {
    return schemaFailure(
      "Status document version " + JSON.stringify(parsed.version) + " is not supported (expected 1).",
      typeof parsed.version === "number" ? parsed.version : null
    )
  }

  var connections = parseConnections(parsed.connections)
  // UI counts are enabled-only (issue #26). Document totals still include
  // disabled rows; consumers that need "is the list empty?" use
  // connections.length, not `total`.
  var aggregates = enabledAggregates(connections)

  return {
    ok: true,
    degraded: null,
    version: 1,
    ts: typeof parsed.ts === "string" ? parsed.ts : null,
    cliVersion: typeof parsed.cli_version === "string" ? parsed.cli_version : null,
    running: aggregates.running,
    starting: aggregates.starting,
    error: aggregates.error,
    stopped: aggregates.stopped,
    total: aggregates.total,
    groups: parseGroups(parsed.groups, connections),
    connections: connections
  }
}

function schemaFailure(message, version) {
  return {
    ok: false,
    degraded: { kind: "schema", message: message },
    version: version,
    ts: null,
    cliVersion: null,
    running: 0,
    starting: 0,
    error: 0,
    stopped: 0,
    total: 0,
    groups: [],
    connections: []
  }
}

// Group order follows first appearance in `connections` (the document's own
// stable config order), not object key order in `groups`, so panel sections
// match DESIGN.md even if a future producer reorders the `groups` map.
function parseGroups(rawGroups, connections) {
  var source = rawGroups && typeof rawGroups === "object" ? rawGroups : {}
  var names = []
  var seen = {}

  // Group order: first appearance in connections (including disabled), then
  // any orphan keys still present in the document's groups map.
  for (var i = 0; i < connections.length; i++) {
    var name = connections[i].group
    if (name !== "" && !seen[name]) {
      seen[name] = true
      names.push(name)
    }
  }

  for (var key in source) {
    if (Object.prototype.hasOwnProperty.call(source, key) && !seen[key]) {
      seen[key] = true
      names.push(key)
    }
  }

  return names.map(function (name) {
    return groupEnabledCounts(name, connections)
  })
}

// Per-group counters over enabled members only (#26). A group that only has
// disabled Connections still appears (total 0) so the panel can show them.
function groupEnabledCounts(name, connections) {
  var running = 0
  var starting = 0
  var error = 0
  var stopped = 0
  var total = 0
  for (var i = 0; i < connections.length; i++) {
    var c = connections[i]
    if (c.group !== name || !c.enabled) continue
    total++
    if (c.state === "running") running++
    else if (c.state === "starting") starting++
    else if (c.state === "error") error++
    else stopped++
  }
  return {
    name: name,
    running: running,
    starting: starting,
    error: error,
    stopped: stopped,
    total: total
  }
}

function enabledAggregates(connections) {
  var running = 0
  var starting = 0
  var error = 0
  var stopped = 0
  var total = 0
  for (var i = 0; i < connections.length; i++) {
    var c = connections[i]
    if (!c.enabled) continue
    total++
    if (c.state === "running") running++
    else if (c.state === "starting") starting++
    else if (c.state === "error") error++
    else stopped++
  }
  return {
    running: running,
    starting: starting,
    error: error,
    stopped: stopped,
    total: total
  }
}

function parseConnections(rawConnections) {
  var list = Array.isArray(rawConnections) ? rawConnections : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!c || typeof c !== "object") continue
    var id = typeof c.id === "string" ? c.id : ""
    out.push({
      id: id,
      name: typeof c.name === "string" ? c.name : id,
      group: typeof c.group === "string" ? c.group : "",
      state: parseHealthState(c.state),
      port: toCount(c.port),
      address: typeof c.address === "string" ? c.address : "",
      // Missing field (older CLI) → true. Only explicit false is disabled.
      enabled: c.enabled !== false,
      error: parseConnectionError(c.error)
    })
  }
  return out
}

function parseHealthState(value) {
  return KNOWN_HEALTH_STATES.indexOf(value) !== -1 ? value : "error"
}

function parseConnectionError(raw) {
  if (!raw || typeof raw !== "object") return null
  return {
    code: typeof raw.code === "string" ? raw.code : "unknown",
    detail: typeof raw.detail === "string" ? raw.detail : ""
  }
}

function toCount(value) {
  var n = parseInt(value, 10)
  return isNaN(n) ? 0 : n
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatusDocument: parseStatusDocument
  }
}
