# 02 — Contracts

All producer/consumer boundaries are defined in `packages/contracts/`.
Nothing crosses a process or network boundary without a schema here.

## Transports `[impl]`

| Boundary | Transport | Encoding | Auth |
|---|---|---|---|
| Browser → control plane | HTTPS (public ingress) | Connect RPC (protobuf, JSON on the wire for debuggability) | Admin session cookie + CSRF token |
| Node → control plane (steady state) | HTTP/2 over a Tailcat tunnel to the control plane's Tailcat server | Connect RPC | Tailcat node key admission (WireGuard) + per-request machine identity bound to node key |
| Node → control plane (bootstrap only) | HTTPS (public ingress, `/enroll`) | Connect RPC | One-time enrollment token; server identity pinned from the enrollment bundle |
| Node → node (peer distribution) | HTTP over Tailcat tunnel to the peer's Tailcat server | Range-capable HTTP + protobuf manifests | Peer admission list pushed by control plane |
| Node → Attic | HTTPS or HTTP over mesh (see [15](15-distribution.md)) | Nix binary cache protocol | Attic pull token scoped per node |
| Control plane → central agent | gRPC/Connect on localhost or private network | Connect RPC | mTLS or Unix socket |
| Daemon ↔ node agent | Local IPC (Unix socket / Windows named pipe) | Connect RPC over the pipe | OS ACL: SYSTEM/root and the daemon-spawned agent only |
| Control plane ↔ build worker | Job queue in PostgreSQL + Connect RPC callbacks | protobuf | Shared internal token on private network |

Connect works over HTTP/1.1 and HTTP/2, so it runs on any `net.Listener`,
including `tailcat.Server.Listen`.

## Protobuf packages

Under `packages/contracts/proto/shepherd/`:

| Package | Services | Purpose |
|---|---|---|
| `shepherd.common.v1` | — | Ids, timestamps, Platform enum, Capability, ResourceRef, Error detail types |
| `shepherd.enroll.v1` | `EnrollmentService` | `Enroll`, `GetBootstrap` |
| `shepherd.node.v1` | `NodeService` | `Heartbeat`, `GetTarget`, `GetPlan`, `SubmitReport`, `SubmitInventory`, `SubmitDriftReport`, `RequestRepair`, `SubmitAgentFinding`, `ProposeRemediation`, `GetPeers`, `AckInstruction` |
| `shepherd.console.v1` | `InventoryService`, `GroupService`, `ProfileService`, `ConfigService`, `DraftService`, `DeploymentService`, `DriftService`, `AuditService`, `EnrollmentAdminService`, `AgentService`, `SettingsService`, `AuthService` | Browser API |
| `shepherd.agent.v1` | `CentralAgentService` (`Chat`, `TriageFinding`, `Complete` stream), `NodeAgentService` (`ProxyCompletion` stream, `UploadSession`), `ToolHostService` | Agent runtime ↔ control plane / daemon; daemon ↔ node agent IPC ([10](10-node-daemon.md#local-ipc-for-node-agent-agt-06)) |
| `shepherd.build.v1` | `BuildCallbackService` | Build worker results |
| `shepherd.distribution.v1` | `PeerService` (manifest + chunk metadata) | Peer transfer |

Rules:

1. `buf lint` with the DEFAULT rule set; `buf breaking` against `main` is a
   required check. Breaking change → new `v2` package.
2. Every RPC returns typed errors using Connect error details
   (`shepherd.common.v1.ErrorDetail{code, message, resource_ref}`).
3. Every list RPC is paginated (`page_size`, `page_token`).
4. Long-running operations (evaluation, build, deployment) return an
   `Operation{id, state}` and are observed with `Watch*` server-streaming RPCs.

## Node API semantics (`shepherd.node.v1`)

- `Heartbeat(HeartbeatRequest{machine_id, daemon_version, active_generation,
  pending_reboot, offline_since?, capabilities_digest})` → `HeartbeatResponse{
  target_generation_id, target_digest, instructions[], next_heartbeat_seconds,
  server_time}`. Default interval 30 s with ±20 % jitter `[impl]`.
- `GetTarget` returns the full `Target{generation_id, platform, artifact_ref,
  signed_envelope, apply_after, maintenance_window, reboot_policy, mode}`.
- `SubmitReport` accepts the report JSON (below) as `bytes` plus a parsed
  summary for indexing; server validates against the schema.
- `instructions[]`: `Reapply`, `Recover`, `RunDriftPass`, `Reboot` (only within
  window), `Unenroll`, `RotateKeys`, `RefreshPeers`, `RunAgent{sessionId,
  question}` [AGT-07], and `RunRemediation{signed remediation.v1 envelope}`
  [AGT-08]. Each carries an id and must be acknowledged with `AckInstruction`.
- `SubmitAgentFinding` accepts the finding JSON from
  [18](18-agents.md#findings-and-escalation-agt-08). The server rejects
  evidence that references tool calls not recorded for that session.
  Remediation results arrive as a report of kind `remediation`.
- Idempotency: every mutating node RPC carries `request_id` (UUIDv7); the server
  deduplicates for 24 h.

## Plan document v1 (cross-platform)

Extends the Windows schema in `docs/platforms/windows/plan-schema.md` to all
platforms. JSON Schema: `packages/contracts/schemas/plan.v1.schema.json`.

```json
{
  "planVersion": 1,
  "planId": "uuid",
  "generationId": "uuid",
  "configRevision": "git sha of the config repo commit",
  "profileId": "uuid",
  "machineId": "uuid",
  "platform": "windows | nixos | darwin",
  "createdAt": "RFC3339",
  "applyAfter": "RFC3339 | null",
  "expiresAt": "RFC3339",
  "mode": "apply | audit",
  "artifacts": [
    { "kind": "nix-closure | nix-darwin-closure | winget-manifest | file",
      "storePath": "/nix/store/...", "narHash": "sha256-...", "size": 0,
      "cache": "attic://shepherd/main" }
  ],
  "resources": [ ],
  "omitted": [
    { "resourceKey": "windows.policy:...", "reason": "unsupported-edition",
      "detail": "Windows Home has no Group Policy engine" }
  ],
  "health": { "checks": [ ], "timeoutSec": 300 },
  "recovery": { "lastWorkingGenerationId": "uuid | null" }
}
```

- `platform: windows` → `resources[]` is the typed resource list from
  [11](11-windows-providers.md); `artifacts` may carry winget manifests or files.
- `platform: nixos | darwin` → `resources[]` contains only **observation**
  resources used for drift (systemd unit state, file hashes, users, firewall
  rules) generated from the evaluated configuration (see [12](12-nixos-backend.md)); the
  closure in `artifacts[0]` is what gets activated.
- `omitted[]` implements [CFG-06]: unsupported settings are never silently
  dropped; they are listed so the console shows incomplete coverage.
- The plan is always delivered inside a DSSE envelope ([03](03-security-and-trust.md)); the
  node MUST verify before parsing beyond the envelope [DEP-01].

## Resource envelope

Same as the Windows schema with these additions:

| Field | Type | Notes |
|---|---|---|
| `key` | string | `"<resource>:<id>"`, globally unique within a plan; join key for reports, journal, drift, console |
| `owner` | `"gui" \| "custom" \| "shepherd"` | Which source defined it; used for diff display and ownership [CFG-07] |
| `destructive` | bool | True when the operation removes or overwrites non-Shepherd state; console requires explicit acknowledgement [CFG-07] |
| `class` | `"boot" \| "service" \| "package" \| "config" \| "update"` | Execution class ordering |
| `continueOnError` | bool | Default false |
| `reversible` | `"full" \| "partial" \| "none"` | Declared by the compiler from the provider capability table [DEP-06] |

## Report document v1

`packages/contracts/schemas/report.v1.schema.json`. Same shape as the Windows
report plus:

- `kind`: `apply | drift | inventory | recovery | repair`.
- `generationId`, `planId`, `trigger`: `target-change | reapply | drift-timer |
  autofix | recovery | manual`.
- `results[].status`: `applied | unchanged | drifted | failed | unsupported |
  blocked | skipped-dependency | reverted | revert-failed`. `drifted` is now
  part of the published list (closes the gap recorded in KNOWLEDGE.md).
- `results[].observed` and `results[].desired`: small JSON values (≤4 KiB each,
  redacted) so the console can render drift without a second round trip.
- `health`: `{ "status": "healthy | unhealthy | unknown", "checks": [ ... ] }`.
- `unrecovered[]`: effects a recovery could not reverse [DEP-06].
- `stale`: boolean set by the server, never by the node, when a report is
  older than the freshness window [DEP-04].

## Journal entry v1

As in the Windows schema plus `generationId`, `sequence` (monotonic per
node), and `state`: `intent | done | failed | reversed | reverse-failed`. The
journal is written to disk with `fsync` before the mutation [DEP-06].

## Inventory document v1

`inventory.v1.schema.json`: hardware (CPU, RAM, disks, serial, model), OS
(platform, edition, version, build), network adapters, installed packages
(source-tagged), detected configuration managers ([16](16-enrollment-and-removal.md)), capability
probes (e.g. `windows.gpo-engine: available | missing`, `winget: version`).

## Capability model

`capabilities` is a map `capability-id → {state: supported | unsupported |
degraded, reason}` reported by each node at enrollment and when it changes.
The compiler uses it to populate `omitted[]` per machine. Capability ids are
listed in `packages/contracts/capabilities.yaml` and mirrored into the release
capability table ([20](20-operations-and-release.md)).

## Fixtures

`packages/contracts/fixtures/` holds, per schema, at least:
valid minimal, valid maximal, each invalid case the validator must reject, and
one realistic document per platform. Both Go and TS test suites load every
fixture. Fakes (`shepherd-fakenode`, `shepherd-fakecp`) serve and consume these.

## Acceptance

- `buf generate` and schema codegen are reproducible; CI diff check passes.
- Go and TS validators accept every `valid/*` fixture and reject every
  `invalid/*` fixture with the expected error code.
- A plan generated by the Windows compiler and a report produced by the Windows
  reconciler both validate against v1 schemas in an integration test.
