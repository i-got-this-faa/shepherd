# Shepherd system architecture

This document records the earlier presentation-based proposal. Current product
requirements are in [SRS.md](../scope/SRS.md); it supersedes conflicting proposals
below, including draft-only agent scope and unconditional rollback claims.
Decision history is in [KNOWLEDGE.md](../scope/KNOWLEDGE.md). The current
folder layout is in the [root README](../../README.md). Pi now has a shared
stripped-down fork under `packages/pi/`, with central and node runners.
The later monorepo baseline confirms the Go backend, shared headless Pi fork,
central/node runners, top-level Tailcat/WireGuard backbone, and self-hosted FBS
behind Attic. Other restrictions, versions, and guarantees below remain
presentation-era proposals. Agent authority is not finalized.

## Source of truth

One Nix Flake defines the desired state for Linux, macOS, and Windows hosts.
Shepherd evaluates that source, builds signed artifacts, distributes target
hashes, verifies activation, and records drift. AI does not replace this path.

```text
Git Flake
  -> Nix evaluator
  -> build workers
  -> signed NARs in Attic
  -> target hash over Shepherd gRPC
  -> endpoint fetch from Attic or a LAN peer
  -> signature verification
  -> platform activation
  -> health check
  -> report active generation or restore generation N-1
```

## Central infrastructure

The Go 1.23 `shepherd` server owns enrollment, host targets, telemetry, drift,
rollout state, and audit logs. PostgreSQL 16 stores inventory, generations, and
drift history. The server embeds a Tailcat DERP relay for restricted networks
and NanoMDM for the Apple security channel.

Build workers evaluate and compile Nix derivations. They compress and sign NAR
metadata before publishing it to Attic backed by S3 or MinIO. The control server
sends hashes, not package payloads, to endpoints.

## Distribution network

Every node establishes an outbound mTLS connection. Target hashes and telemetry
travel over the Tailcat userspace WireGuard mesh. Restricted nodes fall back to
the embedded DERP relay on HTTPS port 443, so Shepherd needs no inbound endpoint
ports.

One lab node may fetch missing store paths from Attic. Other local nodes request
verified chunks from that peer over the LAN. Each receiving node verifies the
Ed25519 signature before activation. Peer delivery changes transport only. It
does not change artifact identity or trust.

## Platform activation

Linux nodes pull the signed closure into `/nix/store`, switch
`/run/current-system`, run the activation script, and restore the previous
symlink after a failed health check. A tmpfs root clears local changes on reboot.

macOS has two channels. NanoMDM sends APNs commands for FileVault escrow and TCC
profiles. The Shepherd agent pulls the nix-darwin closure through Tailcat or S3,
writes it through the APFS firmlink, and runs `darwin-rebuild activate`.

Windows receives a typed JSON intermediate representation produced by server-side
Nix evaluation. The local reconciler stores a generation bundle and applies
Registry, LGPO, Winget, services, update, task, and script resources. A failed
health check re-applies generation N-1.

## Rollout and console

Updates pass through rollout rings before general deployment:

1. Ring 0 deploys to 1 percent of the fleet for 24 hours. Any error reverts it.
2. Ring 1 deploys to 10 percent for 48 hours. Failed health checks revert it.
3. Ring 2 deploys to the general fleet after both gates pass.

The Next.js console shows inventory, active generations, drift, and telemetry.
Prometheus rules detect faults. Administrators approve configuration diffs and
can re-apply the assigned generation to selected drifting nodes.

## Pi's role

The presentation gives AI two jobs. It explains alerts and metric spikes, and it
drafts Nix derivations or hardware-matched Flake changes. Administrators review
every change. Drafts go through the same sandboxed build, reproducibility,
signature, rollout, health, and rollback checks as handwritten changes.

The Go server cannot embed Pi's TypeScript SDK in-process. Run Pi as a separate
TypeScript worker or launch its JSON/RPC mode behind a narrow internal protocol.
Its tools may read selected inventory, metrics, alerts, logs, and Flake context,
then return a draft or explanation. Pi must not receive these capabilities:

- endpoint shell or endpoint credentials
- artifact signing keys
- `dispatch`, `promote`, `revert`, or MDM command execution
- direct writes to the canonical Flake repository
- raw database access across organizations

The Go server validates the worker's structured output. An administrator accepts
or edits a proposed Git diff. Normal CI, Nix evaluation, signing, and rollout
then take over.

Pi documentation: <https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent>

## Patent extension

The patent adds health-based agent assignment, predictive failure analysis,
federated learning, lifecycle reports, and sustainability scoring. Build these
as an intelligence layer over Shepherd's verified observation and deployment
system. Do not reinterpret `shepherd-srv` as an unrestricted AI agent. The
endpoint service remains the trusted collector and deterministic reconciler.

Federated learning may later run a constrained local training worker beside the
endpoint service. It can read approved performance features and emit signed
model updates. It cannot mutate system state. The central coordinator aggregates
updates and publishes a versioned model through the same controlled rollout
mechanism.

## Repository ownership

| Component | Home |
|---|---|
| Go server, evaluator, NanoMDM integration | `apps/control-plane/` |
| Tailcat, WireGuard, userspace netstack, DERP, discovery | `networking/` |
| Pi reasoning worker | `apps/central-agent/` |
| Nix build executor | `apps/build-worker/` |
| Next.js console | `apps/web-console/` |
| Native platform reconcilers | `apps/node-daemon/internal/platform/` |
| Existing Windows PowerShell reference | `apps/node-daemon/reference/powershell/` |
| Unified Flake and host modules | `nix/` |
| Network and storage contracts | `packages/contracts/` |
| Database, Attic, FBS, relay and deployment configuration | `infra/` |
