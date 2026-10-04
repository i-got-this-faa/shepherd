# 04 — Control plane

The `shepherd` Go binary. One process in V1 with internal modules; the build
worker and central agent are separate processes.

## Package layout

```text
apps/control-plane/
  cmd/shepherd/            main: flags, config load, wiring, subcommands
                           (serve, migrate, admin create, keys ..., enroll-token ...)
  internal/
    api/                   Connect handlers for console.v1 (thin; call services)
    nodeapi/               Connect handlers for node.v1 and enroll.v1
    identity/              admins, sessions, machine identities, principals
    enrollment/            tokens, bootstrap bundles, ISO parameterization
    inventory/             machines, inventory docs, capabilities
    groups/                groups, membership
    profiles/              profiles, assignments, effective-profile resolution
    configuration/         config repo (git), GUI model → Nix rendering, evaluation orchestration, diffs
    deployments/           drafts → approvals → generations → targets → rollout
    telemetry/             heartbeats, reports, drift findings, freshness
    relay/                 Tailcat server, peer lists, DERP map publication
    mdm/                   NanoMDM integration
    agents/                central agent bridge, tool host, agent session records
    audit/                 audit event writer
    signing/               plan signer service (wraps internal/signing)
    jobs/                  PostgreSQL-backed job queue (river or hand-rolled SKIP LOCKED)
    db/                    sqlc queries, migrations (goose), tx helpers
    config/                server configuration struct + validation
  migrations/              SQL migrations
```

## Configuration

TOML or YAML file `/etc/shepherd/server.toml` plus env overrides `[impl]`:
listen addresses (console HTTPS, enroll HTTPS), public URL, database DSN,
secrets dir, config repo path, Attic endpoint + cache name, build worker
token, DERP map (self-hosted region), Tailcat state path, agent endpoint,
NanoMDM endpoint, maintenance defaults, freshness window (default 3 ×
heartbeat interval).

## Listeners

| Listener | Exposure | Serves |
|---|---|---|
| Console HTTPS `:8443` | Admin network / reverse proxy | console.v1 Connect API (the Next.js app calls it server-side and from browser) |
| Enroll HTTPS `:8444` | Public ingress | enroll.v1 only; rate limited per IP and per token |
| Tailcat listener | Mesh only | node.v1, distribution metadata; bound via `tailcat.Server.Listen(ctx, "tcp", ":443")` inside the tunnel |
| Internal `:9090` | localhost/private | build callbacks, agent bridge, Prometheus `/metrics`, `/healthz`, `/readyz` |

## Background workers (job queue)

| Job | Trigger | Does |
|---|---|---|
| `evaluate_revision` | draft saved / submitted | Runs evaluation via build worker for every affected platform; stores result, errors, plan previews, capability omissions |
| `build_generation` | approval | Builds closures / compiles Windows plans for the approved revision; publishes artifacts; creates `generations` |
| `dispatch_deployment` | generation ready | Resolves target machines (effective profile), applies rollout rules and windows, sets `machine_targets` |
| `freshness_sweep` | every 30 s | Marks machines offline/stale [DEP-04] |
| `drift_autofix` | drift report with auto-fix on | Issues signed `Reapply` for approved generation only [AGT-04] |
| `recovery_watch` | failed activation report | Ensures node recovered to last working; escalates if not |
| `peer_lists` | membership change | Recomputes peer admission lists per site |
| `retention` | daily | Prunes reports/heartbeats per [05](05-database.md) |

## Effective profile resolution [PRF-01..03]

```text
effective(machine) =
  direct_assignment(machine)                  if present
  else the single group profile among groups(machine) with a profile
  else none (machine is "unassigned"; no target)
error if more than one distinct group profile applies → machine status
"assignment-conflict", no dispatch, console shows the conflicting groups.
```

Resolution is a pure function in `profiles/resolve.go`, table-tested, and is
the only place precedence lives. Group priority is not supported in V1
(conflicts must be resolved by the admin) — matches PRF-03.

## Deployment orchestration

See [09](09-deployment-and-recovery.md) for the state machine. The control
plane is the only component that writes `machine_targets`.

## Node API behavior

- `Heartbeat` updates `machines.last_seen_at`, records active generation,
  returns target digest; if the digest differs the node calls `GetTarget`.
- `GetTarget/GetPlan` returns the signed envelope stored at dispatch time; the
  control plane never re-signs on read.
- `SubmitReport` validates schema, persists report + results, updates
  `machine_generations` (activation/health), creates `drift_findings`, emits
  audit events for failures, triggers jobs.
- Per-machine authorization: the Tailcat peer key of the connection
  (`Server.PeerKey(remoteAddr)`) MUST map to the `machine_id` in the request.

## Observability

- Structured logs (`log/slog`, JSON) with request ids.
- Prometheus metrics: enrolled/online/stale machines, deployments by state,
  evaluation/build durations, report ingest rate, drift findings open,
  plan signature operations, Tailcat connected peers, DERP vs direct ratio.
- OpenTelemetry tracing optional (post-V1).

## Acceptance

- `shepherd serve` starts with Postgres from docker-compose, applies
  migrations, exposes healthz/readyz.
- Console API integration tests (Go, against real Postgres) for every service.
- Node API tested with `shepherd-fakenode` replaying fixtures, including
  wrong-key requests and duplicate `request_id`s.
- Effective profile resolution table tests cover: direct only, group only,
  direct overrides group, removal restores group, two groups conflict, no
  assignment.
