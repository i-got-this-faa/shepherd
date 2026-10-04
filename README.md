# Shepherd monorepo

One repository for the Go backend, web console, shared headless Pi fork,
central and node agents, privileged daemons, all platform backends, networking,
Nix modules, storage, packaging, tests, and academic artifacts. Turborepo is not
required. Empty source folders contain `.gitkeep`; folders with existing files
already remain in Git.

The current product requirements are in [SRS.md](docs/scope/SRS.md).
[KNOWLEDGE.md](docs/scope/KNOWLEDGE.md) records the scope decision history.
Folder ownership is mapped in the
[surface ledger](docs/development/layout-surfaces.md).

```text
fleet-management/
├── .github/
│   └── workflows/
├── apps/
│   ├── build-worker/
│   │   ├── cmd/
│   │   │   └── shepherd-builder/
│   │   └── internal/
│   │       ├── jobs/
│   │       ├── publication/
│   │       └── sandbox/
│   ├── central-agent/
│   │   └── src/
│   │       ├── sessions/
│   │       ├── tools/
│   │       └── workflows/
│   ├── control-plane/
│   │   ├── cmd/
│   │   │   └── shepherd/
│   │   ├── internal/
│   │   │   ├── agents/
│   │   │   ├── api/
│   │   │   ├── configuration/
│   │   │   ├── deployments/
│   │   │   ├── enrollment/
│   │   │   ├── identity/
│   │   │   ├── inventory/
│   │   │   ├── mdm/
│   │   │   ├── relay/
│   │   │   └── telemetry/
│   │   └── migrations/
│   ├── node-agent/
│   │   └── src/
│   │       ├── daemon-client/
│   │       ├── sessions/
│   │       ├── tools/
│   │       └── workflows/
│   ├── node-daemon/
│   │   ├── cmd/
│   │   │   └── shepherd-node/
│   │   ├── internal/
│   │   │   ├── enrollment/
│   │   │   ├── ipc/
│   │   │   ├── journal/
│   │   │   ├── plans/
│   │   │   ├── platform/
│   │   │   │   ├── linux/
│   │   │   │   │   ├── nixos/
│   │   │   │   │   └── profiles/
│   │   │   │   ├── macos/
│   │   │   │   │   ├── darwin/
│   │   │   │   │   └── mdm/
│   │   │   │   └── windows/
│   │   │   │       ├── accounts/
│   │   │   │       ├── environment/
│   │   │   │       ├── firewall/
│   │   │   │       ├── networking/
│   │   │   │       ├── packages/
│   │   │   │       ├── policy/
│   │   │   │       ├── registry/
│   │   │   │       ├── services/
│   │   │   │       ├── tasks/
│   │   │   │       └── updates/
│   │   │   ├── reconciliation/
│   │   │   ├── recovery/
│   │   │   ├── service/
│   │   │   ├── telemetry/
│   │   │   └── updates/
│   │   └── reference/
│   │       └── powershell/
│   │           └── Resources/
│   └── web-console/
│       ├── public/
│       └── src/
│           ├── agents/
│           ├── configurator/
│           ├── deployments/
│           ├── inventory/
│           ├── operations/
│           ├── reports/
│           └── settings/
├── artifacts/
│   └── academic/
│       ├── assets/
│       ├── scripts/
│       └── synopsis/
├── docs/
│   ├── architecture/
│   ├── contracts/
│   ├── development/
│   ├── operations/
│   ├── patent/
│   ├── platforms/
│   │   ├── linux/
│   │   ├── macos/
│   │   └── windows/
│   └── scope/
├── infra/
│   ├── database/
│   ├── development/
│   ├── enrollment/
│   ├── mdm/
│   ├── networking/
│   │   ├── bootstrap/
│   │   ├── deployment/
│   │   └── relays/
│   ├── observability/
│   └── storage/
│       ├── attic/
│       └── fbs/
├── networking/
│   ├── connectivity/
│   ├── derp/
│   │   ├── client/
│   │   └── server/
│   ├── discovery/
│   ├── identity/
│   ├── netstack/
│   ├── policy/
│   ├── tailcat/
│   ├── tests/
│   ├── transport/
│   └── wireguard/
├── nix/
│   ├── modules/
│   │   ├── darwin/
│   │   ├── linux/
│   │   ├── nixos/
│   │   ├── shared/
│   │   └── windows/
│   ├── templates/
│   │   ├── aggregator/
│   │   ├── custom/
│   │   └── generated/
│   └── tests/
├── packages/
│   ├── configuration/
│   ├── contracts/
│   │   ├── generated/
│   │   │   ├── go/
│   │   │   └── typescript/
│   │   ├── proto/
│   │   └── schemas/
│   ├── distribution/
│   ├── federated-learning/
│   ├── health/
│   ├── integrations/
│   ├── lifecycle/
│   └── pi/
│       ├── agent/
│       └── ai/
├── packaging/
│   ├── linux/
│   ├── macos/
│   ├── releases/
│   ├── server/
│   └── windows/
├── tests/
│   ├── contracts/
│   ├── end-to-end/
│   ├── fixtures/
│   ├── pi/
│   ├── platform/
│   │   ├── linux/
│   │   ├── macos/
│   │   └── windows/
│   │       ├── FleetTest/
│   │       ├── integration/
│   │       ├── system/
│   │       └── unit/
│   ├── recovery/
│   ├── storage/
│   │   └── attic-fbs/
│   └── transport/
│       ├── derp/
│       ├── discovery/
│       ├── peer-transfer/
│       └── wireguard/
└── tools/
    ├── benchmarks/
    ├── codegen/
    ├── probes/
    │   └── windows/
    └── upstream/
```

`networking/` owns the Tailcat/WireGuard backbone, userspace netstack, identity,
discovery, direct connectivity, transport policy, and DERP. Internal control,
telemetry, artifact distribution, and peer transfer use this network contract.
`packages/distribution/` owns the artifact protocol above it.

`packages/pi/` is reserved for the shared stripped-down Pi fork, with no TUI.
The central and node agents consume it. `apps/node-daemon/` owns privileged
machine operations; its native Windows, Linux, and macOS providers have separate
homes. The existing Windows PowerShell implementation is preserved under
`apps/node-daemon/reference/powershell/`.

`infra/storage/` contains deployment homes for Attic and self-hosted FBS as its
S3 backend. FBS is a planned pinned upstream service dependency; no source or
image has been imported. Their compatibility must be proven by the storage
integration suite before deployment.

NixOS, other Linux profiles, Darwin, and Windows modules are all represented.
MacOS MDM/APNs, FileVault and TCC belong to the macOS/MDM surfaces. Health,
federated learning, lifecycle/sustainability reports, and asset integrations
from the patent have explicit package owners. Their pilot milestones remain
open.

Only the Windows reference implementation currently contains application code.
The other folders are scaffolding, not completed features. Real build manifests,
lockfiles, upstream license notices, and CI jobs will be added with working
implementations; this task creates no fake build configuration.

Run the existing suite on Windows:

```powershell
tests\platform\windows\run.ps1
```

The structure and recorded architecture are the current baseline. The SRS is
not final until authority, supported operations, trust, recovery, scale, and
measurable acceptance criteria are settled.
