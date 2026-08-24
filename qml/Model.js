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
  // Only the shape of `groups` is checked here. Its values are headers only
  // — Model.js recomputes every counter from `connections` (groupEnabledCounts
  // below), so a wrong count inside `groups` cannot mislead the bar or panel.
  if (!parsed.groups || typeof parsed.groups !== "object" || Array.isArray(parsed.groups)) {
    return schemaFailure("Status document field \"groups\" must be an object.", 1)
  }

  var parsedConnections = parseConnections(parsed.connections)
  if (!Array.isArray(parsedConnections)) {
    // Guard the read: parseConnections always returns { error: string } on
    // failure, but this falls back instead of throwing if that ever slips.
    return schemaFailure(
      (parsedConnections && typeof parsedConnections.error === "string")
        ? parsedConnections.error
        : "A connection in the Status document is invalid.",
      1
    )
  }
  var connections = parsedConnections
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
  // No defensive fallback here: the caller (parseStatusDocument) already
  // rejected the document unless rawGroups is a plain object.
  var source = rawGroups
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

// Connection id charset (cloud-sql-tracker/docs/config.v1.md "Connection
// fields": id `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`, length 1-64 — this pattern is
// the same rule, just anchored with an explicit max length instead of `*`).
// A leading '-' or '--' would be read as a flag by argv parsing; the
// charset starts with an alnum so that can never happen (issue #47). Group
// charset enforcement is #49's slice (Tracker.qml's target guard), not here.
var CONNECTION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/

// Returns the parsed Connection list, or { error: message } if any element
// fails the contract's type/range for a field this plugin reads. A
// malformed Connection fails the whole document (issue #47) instead of
// being dropped or defaulted — a defaulted empty id/port/Group can
// otherwise reach _targetArgs and read as a healthy, empty setup. The
// message names the offending Connection (id when known, else its index)
// and the field, so the Degraded body the operator sees is actionable.
function parseConnections(rawConnections) {
  var out = []
  for (var i = 0; i < rawConnections.length; i++) {
    var raw = rawConnections[i]
    var result = parseConnection(raw)
    if (result.ok !== true) {
      return { error: "Connection at " + connectionRef(raw, i) + " has " + result.reason + "." }
    }
    out.push(result.connection)
  }
  return out
}

// A raw.id can be attacker- or bug-controlled and unbounded in length —
// this message reaches the Panel Degraded body and the shell-owned bar
// tooltip. Only use it when it is a string within config.v1.md's max id
// length (64); anything longer or non-string falls back to the index, and
// the 64-char slice is a defensive second bound on top of that check.
function connectionRef(raw, index) {
  if (raw && typeof raw === "object" && typeof raw.id === "string" && raw.id !== "" && raw.id.length <= 64) {
    return "id " + JSON.stringify(raw.id.slice(0, 64))
  }
  return "index " + index
}

// Checks only the fields Tracker/Panel read from a Connection: id, name,
// group, state, port, address, enabled, error. Fields the plugin never
// reads (instance, private_ip, source, pid, unit, port_open, uptime_sec)
// are ignored, per the Status document "ignore unknown fields" rule.
function parseConnection(c) {
  if (!c || typeof c !== "object" || Array.isArray(c)) {
    return { ok: false, reason: "a value that is not an object" }
  }
  if (typeof c.id !== "string" || !CONNECTION_ID_PATTERN.test(c.id)) {
    return { ok: false, reason: "a missing or invalid \"id\" field" }
  }
  if (typeof c.name !== "string") {
    return { ok: false, reason: "a missing or invalid \"name\" field" }
  }
  // group and address are non-empty per contract (config.v1.md); an empty
  // group renders as a header with no visible rows (Panel.flatRows skips
  // it) and an empty address renders as ":<port>" — both read as broken,
  // not merely unusual, so both fail the document rather than defaulting.
  if (typeof c.group !== "string" || c.group.length === 0) {
    return { ok: false, reason: "a missing or empty \"group\" field" }
  }
  if (typeof c.state !== "string") {
    return { ok: false, reason: "a missing or invalid \"state\" field" }
  }
  if (!isValidPort(c.port)) {
    return { ok: false, reason: "a missing or out-of-range \"port\" field" }
  }
  if (typeof c.address !== "string" || c.address.length === 0) {
    return { ok: false, reason: "a missing or empty \"address\" field" }
  }
  if (c.enabled !== undefined && typeof c.enabled !== "boolean") {
    return { ok: false, reason: "a non-boolean \"enabled\" field" }
  }
  var error = parseConnectionError(c.error)
  if (error === undefined) {
    return { ok: false, reason: "an invalid \"error\" field" }
  }

  return {
    ok: true,
    connection: {
      id: c.id,
      name: c.name,
      group: c.group,
      state: parseHealthState(c.state),
      port: c.port,
      address: c.address,
      // Missing field (older CLI) → true. Only explicit false is disabled.
      enabled: c.enabled === undefined ? true : c.enabled,
      error: error
    }
  }
}

// ES5 integer check (no Number.isInteger — this file is the only qml/ file
// that must also run outside Quickshell, and a missing builtin would throw
// outside parseStatusDocument's JSON.parse try/catch, freezing the widget
// on its last view instead of degrading).
function isValidPort(value) {
  return typeof value === "number" && value === Math.floor(value) && value >= 1 && value <= 65535
}

// state is a closed enum in v1 (status-document.v1.md); the additive rule
// never blesses new state values. A present-but-unrecognized value is out
// of contract, so the plugin degrades that one row to "error" rather than
// the whole document — fails visible, keeps the pre-existing
// KNOWN_HEALTH_STATES behavior. A state field that is not a string at all
// is a malformed document — parseConnection rejects that before this runs.
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
