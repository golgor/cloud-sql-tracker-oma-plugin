#!/usr/bin/env node
// Node smoke check for Model.js — no QML runtime needed.
// Run: node scripts/check-model.js

"use strict"

var fs = require("fs")
var path = require("path")
var assert = require("assert")

var Model = require("../qml/Model.js")

function readFixture(name) {
  var file = path.join(__dirname, "..", "fixtures", name)
  return fs.readFileSync(file, "utf8")
}

function checkHappyFixture() {
  var result = Model.parseStatusDocument(readFixture("status.v1.happy.json"))

  assert.strictEqual(result.ok, true, "happy fixture should parse ok")
  assert.strictEqual(result.degraded, null)
  assert.strictEqual(result.version, 1)
  assert.strictEqual(result.cliVersion, "0.1.0")
  // Aggregates are enabled-only (#26). backend-prod is disabled in the fixture.
  assert.strictEqual(result.running, 1)
  assert.strictEqual(result.error, 2)
  assert.strictEqual(result.stopped, 3)
  assert.strictEqual(result.total, 6)
  assert.strictEqual(result.connections.length, 7)
  assert.deepStrictEqual(
    result.groups.map(function (g) { return g.name }),
    ["backend", "fe", "iot"],
    "group order should follow first appearance in connections"
  )

  var feDev = result.connections.filter(function (c) { return c.id === "fe-dev" })[0]
  assert.ok(feDev, "fe-dev connection should be present")
  assert.strictEqual(feDev.state, "error")
  assert.strictEqual(feDev.port, 15434)
  assert.strictEqual(feDev.address, "127.0.0.1")
  assert.strictEqual(feDev.error.code, "port_in_use")
  assert.strictEqual(feDev.enabled, true)

  var backendProd = result.connections.filter(function (c) { return c.id === "backend-prod" })[0]
  assert.ok(backendProd)
  assert.strictEqual(backendProd.enabled, false)

  var backend = result.groups.filter(function (g) { return g.name === "backend" })[0]
  assert.ok(backend)
  assert.strictEqual(backend.total, 1, "backend group total is enabled-only")
  assert.strictEqual(backend.running, 1)
  assert.strictEqual(backend.stopped, 0)

  // Missing enabled on a synthetic document defaults to true.
  var legacy = Model.parseStatusDocument(JSON.stringify({
    version: 1,
    ts: "t",
    cli_version: "0.1.0",
    running: 0,
    starting: 0,
    error: 0,
    stopped: 1,
    total: 1,
    groups: { g: { running: 0, starting: 0, error: 0, stopped: 1, total: 1 } },
    connections: [{
      id: "x", name: "X", group: "g", state: "stopped",
      port: 1, address: "127.0.0.1", error: null
    }]
  }))
  assert.strictEqual(legacy.ok, true)
  assert.strictEqual(legacy.connections[0].enabled, true)
  assert.strictEqual(legacy.total, 1)

  console.log("ok: happy fixture (7 connections, enabled-only totals, fe-dev error mapped)")
}

// Issue #44: group names are CLI-controlled free text. A bare {} used as a
// lookup map inherits Object.prototype, so a group named "constructor",
// "toString", or "__proto__" read as already-seen and never entered the
// group list, even though the connections were still counted in totals.
function checkPrototypePollutingGroupNames() {
  var doc = {
    version: 1,
    // Issue #47: groups must be a present object, so this synthetic doc
    // needs one even though the counters inside it are unused here (Model.js
    // computes group counters from `connections`, not from this map).
    groups: {},
    connections: [
      { id: "a", name: "A", group: "constructor", state: "running", port: 1, address: "127.0.0.1" },
      { id: "b", name: "B", group: "toString", state: "running", port: 2, address: "127.0.0.1" },
      { id: "c", name: "C", group: "__proto__", state: "running", port: 3, address: "127.0.0.1" },
      { id: "d", name: "D", group: "ok", state: "running", port: 4, address: "127.0.0.1" }
    ]
  }
  var result = Model.parseStatusDocument(JSON.stringify(doc))
  var names = result.groups.map(function (g) { return g.name })

  assert.deepStrictEqual(
    names,
    ["constructor", "toString", "__proto__", "ok"],
    "groups named after Object.prototype members must still appear"
  )
  assert.strictEqual(result.total, 4, "bar count must match the number of rows the panel can draw")

  console.log("ok: group names colliding with Object.prototype members are not dropped")
}

function checkBadVersionFixture() {
  var result = Model.parseStatusDocument(readFixture("status.v1.bad-version.json"))

  assert.strictEqual(result.ok, false)
  assert.ok(result.degraded, "bad-version fixture should be degraded")
  assert.strictEqual(result.degraded.kind, "schema")
  assert.strictEqual(result.connections.length, 0)

  console.log("ok: bad-version fixture (degraded.kind === \"schema\")")
}

function checkEmptyFixture() {
  var result = Model.parseStatusDocument(readFixture("status.v1.empty.json"))

  // The distinction the Panel's empty body depends on: a valid document that
  // happens to describe nothing is *usable*, not Degraded. Getting this wrong
  // would make "no Connections configured" render as "control plane broken".
  assert.strictEqual(result.ok, true, "empty document is valid, not degraded")
  assert.strictEqual(result.degraded, null)
  assert.strictEqual(result.total, 0)
  assert.deepStrictEqual(result.groups, [])
  assert.deepStrictEqual(result.connections, [])

  console.log("ok: empty fixture (ok === true, total === 0, not degraded)")
}

function checkMalformedJson() {
  var result = Model.parseStatusDocument("not json")

  assert.strictEqual(result.ok, false)
  assert.strictEqual(result.degraded.kind, "schema")

  console.log("ok: malformed JSON input")
}

// Issue #47: `{"version":1}` must not read as a valid, empty setup. Before
// this fix, missing `connections`/`groups` defaulted to `[]`/`{}` and the
// document parsed as ok:true with total 0 — indistinguishable from a real
// empty setup. It must fail closed instead.
function checkVersionOnlyFixture() {
  var result = Model.parseStatusDocument(readFixture("status.v1.version-only.json"))

  assert.strictEqual(result.ok, false, "a document with only \"version\" must not parse as ok")
  assert.ok(result.degraded, "version-only fixture should be degraded")
  assert.strictEqual(result.degraded.kind, "schema")
  assert.strictEqual(result.total, 0)
  assert.deepStrictEqual(result.connections, [])
  assert.deepStrictEqual(result.groups, [])

  console.log("ok: {\"version\":1} alone is rejected (degraded.kind === \"schema\"), not shown healthy")
}

// Issue #47: `groups` present but the wrong shape (an array, or any
// non-object) must fail closed too — this branch is otherwise unreachable
// by the rest of the suite, which only varies `connections`.
function checkGroupsNotObjectFixture() {
  var result = Model.parseStatusDocument(JSON.stringify({ version: 1, connections: [], groups: "nope" }))

  assert.strictEqual(result.ok, false, "groups: \"nope\" must not parse as ok")
  assert.strictEqual(result.degraded.kind, "schema")

  console.log("ok: a non-object \"groups\" is rejected")
}

// Issue #47: a Connection missing `state` must fail the whole document, not
// get defaulted (empty id, port 0, state "error") and slip through as one
// bad row inside an otherwise-healthy view.
function checkBadConnectionFixture() {
  var result = Model.parseStatusDocument(readFixture("status.v1.bad-connection.json"))

  assert.strictEqual(result.ok, false, "a Connection missing \"state\" must not parse as ok")
  assert.ok(result.degraded, "bad-connection fixture should be degraded")
  assert.strictEqual(result.degraded.kind, "schema")
  assert.strictEqual(result.total, 0)
  assert.deepStrictEqual(result.connections, [])

  console.log("ok: a Connection missing \"state\" is rejected (degraded.kind === \"schema\"), not defaulted")
}

// Issue #47 item 5: an id outside the config.v1.md charset must be
// rejected, not passed through to reach _targetArgs (qml/Tracker.qml).
function checkInvalidConnectionIdCharset() {
  var doc = {
    version: 1,
    groups: {},
    connections: [{
      id: "-leading-hyphen", name: "Bad", group: "g", state: "stopped",
      port: 1, address: "127.0.0.1", error: null
    }]
  }
  var result = Model.parseStatusDocument(JSON.stringify(doc))

  assert.strictEqual(result.ok, false, "an id starting with '-' must be rejected")
  assert.strictEqual(result.degraded.kind, "schema")
  assert.ok(result.degraded.message.indexOf("-leading-hyphen") !== -1, "message should name the offending id")

  console.log("ok: a Connection id outside the config.v1.md charset is rejected")
}

// Issue #47 item 3: a port outside the contract's 1-65535 range is a wrong
// value for a field the plugin reads (and forwards to the CLI), not a
// harmless default.
function checkInvalidPortRange() {
  var doc = {
    version: 1,
    groups: {},
    connections: [{
      id: "backend-dev", name: "Backend Dev", group: "g", state: "stopped",
      port: 0, address: "127.0.0.1", error: null
    }]
  }
  var result = Model.parseStatusDocument(JSON.stringify(doc))

  assert.strictEqual(result.ok, false, "port 0 is outside the contract range and must be rejected")
  assert.strictEqual(result.degraded.kind, "schema")

  console.log("ok: a Connection port outside 1-65535 is rejected")
}

// Blocker 1 (rework #47): group: "" passes schemas/status.v1.json's
// minLength 1 check nowhere else, so it must be caught here. Left
// unrejected, every Connection sharing an empty Group would count toward
// the bar/panel aggregates while Panel.flatRows never draws that Group's
// rows — a healthy header over a blank body.
function checkEmptyGroupRejected() {
  var doc = {
    version: 1,
    groups: {},
    connections: [{
      id: "backend-dev", name: "Backend Dev", group: "", state: "stopped",
      port: 1, address: "127.0.0.1", error: null
    }]
  }
  var result = Model.parseStatusDocument(JSON.stringify(doc))

  assert.strictEqual(result.ok, false, "an empty group must be rejected")
  assert.strictEqual(result.degraded.kind, "schema")
  assert.ok(result.degraded.message.indexOf("\"group\"") !== -1, "message should name the \"group\" field")

  console.log("ok: a Connection with an empty \"group\" is rejected")
}

// Blocker 1 (rework #47): address: "" is the same minLength 1 contract gap
// as group, and renders as a bare ":<port>" address in the panel.
function checkEmptyAddressRejected() {
  var doc = {
    version: 1,
    groups: {},
    connections: [{
      id: "backend-dev", name: "Backend Dev", group: "g", state: "stopped",
      port: 1, address: "", error: null
    }]
  }
  var result = Model.parseStatusDocument(JSON.stringify(doc))

  assert.strictEqual(result.ok, false, "an empty address must be rejected")
  assert.strictEqual(result.degraded.kind, "schema")
  assert.ok(result.degraded.message.indexOf("\"address\"") !== -1, "message should name the \"address\" field")

  console.log("ok: a Connection with an empty \"address\" is rejected")
}

// Rework #47 blocker: an oversized id must not reach the Degraded message
// verbatim (it would blow up the Panel body and the bar tooltip). The
// message must fall back to "index N" instead of the raw id.
function checkOversizedIdFallsBackToIndex() {
  var oversizedId = new Array(201).join("a") // 200 chars, over config.v1.md's 64-char max
  var doc = {
    version: 1,
    groups: {},
    connections: [{
      id: oversizedId, name: "Bad", group: "g", state: "stopped",
      port: 1, address: "127.0.0.1", error: null
    }]
  }
  var result = Model.parseStatusDocument(JSON.stringify(doc))

  assert.strictEqual(result.ok, false, "an oversized id must still be rejected")
  assert.strictEqual(result.degraded.kind, "schema")
  assert.ok(result.degraded.message.indexOf("index 0") !== -1, "message should fall back to the index")
  assert.ok(result.degraded.message.indexOf(oversizedId) === -1, "message must not carry the oversized id")
  assert.ok(result.degraded.message.length < 200, "message must stay bounded")

  console.log("ok: an oversized id falls back to \"index N\" in the message")
}

checkHappyFixture()
checkPrototypePollutingGroupNames()
checkBadVersionFixture()
checkEmptyFixture()
checkMalformedJson()
checkVersionOnlyFixture()
checkGroupsNotObjectFixture()
checkBadConnectionFixture()
checkInvalidConnectionIdCharset()
checkInvalidPortRange()
checkEmptyGroupRejected()
checkEmptyAddressRejected()
checkOversizedIdFallsBackToIndex()

console.log("ok: all Model.js checks passed")
