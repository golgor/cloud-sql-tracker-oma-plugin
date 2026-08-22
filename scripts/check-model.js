#!/usr/bin/env node
// Node smoke check for Model.js — no QML runtime needed.
// Run: node scripts/check-model.js

"use strict"

var fs = require("fs")
var path = require("path")
var assert = require("assert")

var Model = require("../Model.js")

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
  assert.strictEqual(result.running, 1)
  assert.strictEqual(result.error, 2)
  assert.strictEqual(result.stopped, 4)
  assert.strictEqual(result.total, 7)
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

  console.log("ok: happy fixture (7 connections, 3 groups, fe-dev error mapped)")
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
