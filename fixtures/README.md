# Fixtures

Status document (schema v1) samples for `Model.js`, not for the CLI itself.

- `status.v1.happy.json` — copy of the sibling `cloud-sql-tracker` golden
  (`examples/status.v1.json`). Update this file only by re-copying from that
  repo if the golden changes; do not hand-edit it out of sync.
- `status.v1.bad-version.json` — minimal document with `version: 2`, used to
  exercise the `degraded.kind === "schema"` path.

Used by [`scripts/check-model.js`](../scripts/check-model.js).
