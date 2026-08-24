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

checkHappyFixture()
checkBadVersionFixture()
checkEmptyFixture()
checkMalformedJson()

console.log("ok: all Model.js checks passed")
