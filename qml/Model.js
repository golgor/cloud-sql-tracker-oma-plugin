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
// Failure (malformed JSON, unsupported schema version, or a document that
// does not match the contract shape — issue #47: a broken control plane
// must not read as a healthy, empty setup):
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

  // Fail closed on shape (issue #47): a document that only carries the right
  // `version` must not read as a valid, empty setup. `connections` must be
  // an array and `groups` must be an object, per
  // cloud-sql-tracker/docs/status-document.v1.md.
  if (!Array.isArray(parsed.connections)) {
    return schemaFailure("Status document field \"connections\" must be an array.", 1)
  }
  if (!parsed.groups || typeof parsed.groups !== "object" || Array.isArray(parsed.groups)) {
    return schemaFailure("Status document field \"groups\" must be an object.", 1)
  }

  var connections = parseConnections(parsed.connections)
  if (connections === null) {
    return schemaFailure("A connection in the Status document is missing a required field or has the wrong type.", 1)
  }
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
  // Object.create(null): group names are CLI-controlled free text (issue
  // #44) and a name matching an Object.prototype member ("constructor",
  // "toString", ...) would otherwise read as already-seen and drop the
  // Group before it is ever added.
  var seen = Object.create(null)

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

// CLI contract charset for id and Group targets (cli-contract.v1.md). A
// leading '-' or '--' would be read as a flag by argv parsing; the charset
// starts with an alnum so that can never happen (issue #47, agrees with #49).
var CONNECTION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/

// Returns the parsed Connection list, or null if any element fails the
// contract's type/range for a field this plugin reads. A malformed
// Connection fails the whole document (issue #47) instead of being dropped
// or defaulted — a defaulted empty id/port/Group can otherwise reach
// _targetArgs and read as a healthy, empty setup.
function parseConnections(rawConnections) {
  var out = []
  for (var i = 0; i < rawConnections.length; i++) {
    var connection = parseConnection(rawConnections[i])
    if (connection === null) return null
    out.push(connection)
  }
  return out
}

// Checks only the fields Tracker/Panel read from a Connection: id, name,
// group, state, port, address, enabled, error. Fields the plugin never
// reads (instance, private_ip, source, pid, unit, port_open, uptime_sec)
// are ignored, per the Status document "ignore unknown fields" rule.
function parseConnection(c) {
  if (!c || typeof c !== "object" || Array.isArray(c)) return null
  if (typeof c.id !== "string" || !CONNECTION_ID_PATTERN.test(c.id)) return null
  if (typeof c.name !== "string") return null
  if (typeof c.group !== "string") return null
  if (typeof c.state !== "string") return null
  if (!isValidPort(c.port)) return null
  if (typeof c.address !== "string") return null
  if (c.enabled !== undefined && typeof c.enabled !== "boolean") return null
  var error = parseConnectionError(c.error)
  if (error === undefined) return null

  return {
    id: c.id,
    name: c.name,
    group: c.group,
    state: parseHealthState(c.state),
    port: c.port,
    address: c.address,
    // Missing field (older CLI) → true. Only explicit false is disabled.
    enabled: c.enabled !== false,
    error: error
  }
}

function isValidPort(value) {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 65535
}

// A present-but-unrecognized state is a forward-compat future enum value
// (status-document.v1.md "additive" rule) and degrades to "error" per row,
// not a schema failure. A state field that is not a string at all is a
// malformed document — parseConnection rejects that before this runs.
function parseHealthState(value) {
  return KNOWN_HEALTH_STATES.indexOf(value) !== -1 ? value : "error"
}

// Returns null when there is no error (contract default), the parsed
// { code, detail } object, or undefined when `error` is present but does
// not match the contract shape — the undefined sentinel tells the caller
// to reject the whole document rather than default a row silently.
function parseConnectionError(raw) {
  if (raw === null || raw === undefined) return null
  if (typeof raw !== "object" || Array.isArray(raw)) return undefined
  if (typeof raw.code !== "string" || typeof raw.detail !== "string") return undefined
  return { code: raw.code, detail: raw.detail }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatusDocument: parseStatusDocument
  }
}
