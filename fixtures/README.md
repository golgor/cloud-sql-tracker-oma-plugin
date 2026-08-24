# Fixtures

Status document (schema v1) samples for `Model.js`, not for the CLI itself.

- `status.v1.happy.json` — copy of the sibling `cloud-sql-tracker` golden
  (`examples/status.v1.json`). Update this file only by re-copying from that
  repo if the golden changes; do not hand-edit it out of sync.
- `status.v1.bad-version.json` — minimal document with `version: 2`, used to
  exercise the `degraded.kind === "schema"` path.
- `status.v1.empty.json` — valid v1 document describing zero Connections. Proves
  an empty Status document parses as usable (`ok: true`), **not** Degraded, which
  is what lets the Panel tell "nothing configured" apart from "control plane
  broken". Also the fixture behind the Panel's empty body.
- `status.v1.version-only.json` — `{"version": 1}` and nothing else. Issue
  #47: a document that only carries the right `version` must fail closed
  (`degraded.kind === "schema"`), not read as a healthy, empty setup.
- `status.v1.bad-connection.json` — otherwise well-formed document where the
  one Connection is missing `state`. Issue #47: a malformed Connection must
  fail the whole document, not get an empty id/port/Group and look healthy.

Used by [`scripts/check-model.js`](../scripts/check-model.js).
