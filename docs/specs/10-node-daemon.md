# 10 — Node daemon (`shepherd-node`)

One Go binary for Windows, NixOS, and macOS. It is the only privileged
Shepherd component on a machine [AGT-06]. The PowerShell agent in
`apps/node-daemon/reference/powershell/` is the behavioral reference and the
test oracle for Windows providers; it is not shipped.

## Package layout

```text
apps/node-daemon/
  cmd/shepherd-node/        main + subcommands: run, enroll, status, drift, apply-local (debug), support-bundle, uninstall
  internal/
    service/                OS service integration (x/sys/windows/svc, systemd notify, launchd)
    config/                 local config file + state dir layout
    enrollment/             bootstrap: token exchange, key generation, server pinning
    mesh/                   Tailcat client to control plane + own Tailcat server for peers (wraps networking/)
    sync/                   heartbeat loop, target fetch, instruction handling, report queue
    plans/                  envelope verification, schema validation, storage of verified plans/targets
    reconcile/              engine: ordering, dependency gating, modes, timeouts, reports
    journal/                durable append-only journal with fsync, replay, reversal
    drift/                  timers, event triggers, drift reports
    recovery/               last-working tracking, recovery orchestration, restart recovery
    health/                 health check runner
    inventory/              inventory + capability probes
    managers/               competing configuration manager detection [ADM-03]
    ipc/                    local API for node agent (named pipe / unix socket)
    agentrunner/            launches node agent process with restricted env
    platform/
      windows/<provider>/   one package per provider ([11])
      linux/nixos/          activation backend ([12])
      macos/darwin/, macos/mdm/   ([13])
    selfupdate/             daemon updates delivered through Shepherd config [DEP-02]
```

## State directory

| OS | Path |
|---|---|
| Windows | `C:\ProgramData\Shepherd\` (ACL: SYSTEM full, Administrators read) |
| Linux | `/var/lib/shepherd/` (root 0700) |
| macOS | `/Library/Application Support/Shepherd/` (root 0700) |

Contents: `identity/` (keys), `trust/` (key set, server pin, Tailcat addr),
`targets/current.dsse`, `plans/<generation>.dsse`, `generations/` (Windows
generation bundles), `journal/` (JSONL segments), `queue/` (pending reports),
`cache/` (artifacts, peer chunks), `logs/`.

## Main loop

```text
start → load identity (or idle in "unenrolled" state) → restart recovery check
      → start mesh client (+ own peer server) → loop:
          heartbeat every N s (jitter)
            if target digest changed: GetTarget → verify → store → schedule apply (respect applyAfter/window)
            process instructions (verify signature each) → ack
          drift timer → drift pass → report
          report queue flush with backoff
```

Concurrency rule: one **mutation lock**; apply, reapply, recovery, and repair
never run concurrently. Drift passes run read-only and may run concurrently
with nothing mutating.

## Reconciler engine (fixes gaps listed in KNOWLEDGE.md)

1. **Default mode is audit** when the plan omits `mode` — the opposite of the
   PowerShell reference. Schema makes `mode` required anyway.
2. Order: by `class` (boot, service, package, config, update), then
   topological by `dependsOn` within the class.
3. **Dependency gating**: a resource whose dependency is not
   `applied|unchanged` reports `skipped-dependency` and is not executed.
4. **Fail-stop**: first `failed` resource stops the pass unless
   `continueOnError`; `unsupported`/`blocked` never stop.
5. Each resource runs with `timeoutSec` via context; process-spawning providers
   run in a Windows Job Object / Linux process group killed on timeout.
6. Per resource: `Observe → Compare → (audit: report drifted|unchanged) →
   Journal(intent, fsync) → Apply → Observe again (verify) → Journal(done|failed)`.
   Report `applied` only when the post-apply observation matches desired.
7. Health checks after the pass; result goes in the report.
8. On failure or unhealthy: recovery per [09](09-deployment-and-recovery.md).

## Provider interface (Go)

```go
type Provider interface {
    Kind() string                                   // "registry.value"
    Validate(r plan.Resource) error                 // payload schema + semantic checks
    Capabilities(ctx context.Context) Capability    // supported/unsupported + reason on this machine
    Observe(ctx context.Context, r plan.Resource) (Observed, error)
    Diff(desired plan.Resource, obs Observed) (Diff, bool)
    Apply(ctx context.Context, r plan.Resource, obs Observed) (journal.Previous, error)
    Reverse(ctx context.Context, e journal.Entry) error   // ErrIrreversible allowed
}
```

Errors: `ErrUnsupported{reason}`, `ErrBlocked{blocker}`, `ErrIrreversible`.
A provider conformance test suite (`internal/reconcile/conformance`) runs every
provider through: observe on clean machine, apply, verify, idempotent re-apply
(`unchanged`), drift injection detected, reverse restores prior state.

## Journal

- JSONL segment files, one entry per line, `fsync` after each write; segment
  rotation at 10 MiB; monthly archive.
- Entries keyed by `(generationId, resourceKey, sequence)`.
- Restart recovery: on start, scan for `intent` without terminal state →
  treat the plan as interrupted → run recovery toward last working [DEP-06].
- Reversal marks entries `reversed`/`reverse-failed` durably (fixes the
  in-memory-only reversal in the reference).
- No secrets: providers declare sensitive fields; journal stores a redaction
  marker and a hash.

## Local IPC for node agent [AGT-06]

Named pipe `\\.\pipe\shepherd-node` (Windows, ACL SYSTEM + the agent's
service SID) / Unix socket `/run/shepherd/node.sock` (root 0600, agent runs as
a dedicated user added via socket credentials check). Methods: `GetStatus`,
`GetLastReports`, `GetDriftFindings`, `GetInventory`, `ReadLogs(redacted)`,
`RequestRepair(resourceKeys, reason)`. No method executes arbitrary commands
or applies a plan the server has not signed.

## Self-update [DEP-02]

The daemon version is part of the desired configuration (Windows: a
`shepherd.daemon` resource with MSI/zip artifact + hash; NixOS/Darwin: part of
the closure). Windows self-update: download → verify signature → stage →
service restart via a helper (`shepherd-node update-helper`) → health check →
roll back binary if unhealthy.

## Logs and support bundle

`log/slog` JSON to state dir with daily rotation, 30-day retention; Windows
Event Log source `Shepherd` for start/stop/crash/apply summary.
`shepherd-node support-bundle` zips redacted logs, last reports, journal
summary, inventory.

## Acceptance

- Cross-compiles for windows/amd64, linux/amd64, darwin/arm64.
- Runs as Windows service (SCM start/stop/recovery), systemd service, launchd daemon.
- Reconciler unit tests: ordering, gating, fail-stop, audit side-effect-free
  (asserts zero journal writes), timeout kill, verify-after-apply.
- Kill -9 during apply → restart → recovery runs and reports.
- Conformance suite passes for every provider on its platform.
