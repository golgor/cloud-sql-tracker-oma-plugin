# Cloud SQL Tracker Omarchy plugin

Omarchy bar dropdown that drives the external `cloud-sql-tracker` control plane. Shows Connection health from a Status document and issues start/stop; never owns Proxy processes or the connections config file.

## Language

**Tracker**:
The in-shell module that polls the control plane, holds the last usable Status view, and runs start/stop. One instance per bar widget.
_Avoid_: Service (collides with Omarchy `kind: service` and systemd units), client, agent, wrapper, control plane (the CLI is the control plane)

**Control plane**:
The external `cloud-sql-tracker` CLI. Stateless short-lived invocations. This plugin only shells out to it.
_Avoid_: Calling the plugin or the Tracker the control plane

**Status document**:
The versioned JSON snapshot from `cloud-sql-tracker status --json` (schema `version` integer, currently `1`).
_Avoid_: State file, report, healthcheck response

**Connection**:
One configured Cloud SQL instance plus its fixed local listen endpoint, as listed in the Status document.
_Avoid_: Service, database (the remote DB), tunnel, row (UI-only)

**Health state**:
One of `stopped` | `starting` | `running` | `error` for a Connection.
_Avoid_: Status (ambiguous with Status document), phase

**Group**:
A display and bulk-action label on Connections (e.g. `fe`, `backend`, `iot`).
_Avoid_: Environment, project (GCP project is part of instance name)

**Degraded**:
A Tracker condition where the bar and panel must not pretend proxies are fine — CLI missing, CLI too old, Status schema mismatch, status command failure, or doctor hard-fail on panel open (`doctor_failed`).
_Avoid_: Error alone (reserved for Connection Health state `error`), broken, offline

**Action target**:
What a start or stop applies to: one Connection id, one Group name, or all Connections.
_Avoid_: Selector (CLI term unless quoting argv), query
