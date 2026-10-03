# Folder structure surface ledger

The repository provides a visible home for every component described in the
presentation, patent, confirmed scope, and current Windows implementation.
Coverage here means folder ownership, not implemented behavior. The monorepo,
headless Pi fork, networking backbone, and FBS-backed Attic are agreed baseline
choices. Unsettled product decisions remain unsettled.

## Source coverage

| Surface | Source | Ownership | Applicability |
|---|---|---|---|
| Administrator GUI and program controls | KNOWLEDGE configuration and Q25 | `apps/web-console/src/configurator/` | applies |
| Environment, system PATH, Registry, firewall, policy, services, networking, accounts | KNOWLEDGE managed state | configurator, `packages/configuration/`, platform daemons | applies; operation bounds open |
| Generated Nix, custom modules, aggregation | KNOWLEDGE configuration | `nix/templates/generated/`, `nix/templates/custom/`, `nix/modules/shared/` | applies |
| Precedence, conflicts, explicit overrides, capability handling | KNOWLEDGE Q22–Q24 | `packages/configuration/`, `apps/control-plane/internal/configuration/` | applies; semantics partly open |
| Enrollment, host keys, roles, targets, revocation | presentation slide 6; KNOWLEDGE trust questions | `apps/control-plane/internal/enrollment/` | applies |
| USB/PXE onboarding | presentation slide 6 | `infra/enrollment/` | applies as proposal |
| Flake evaluator and Windows JSON compilation | slides 5, 7, 11 | `apps/control-plane/internal/configuration/`, `nix/modules/windows/` | applies |
| Build farm and signing | slide 8 | `apps/build-worker/`, `apps/control-plane/internal/deployments/` | applies as proposal |
| Attic with self-hosted FBS object persistence | slides 7–8, 15; later user decision | `infra/storage/attic/`, `infra/storage/fbs/`, `packages/distribution/` | applies; compatibility untested |
| Signature and artifact verification | slides 5–11 | `packages/distribution/`, `apps/node-daemon/internal/service/`, platform daemons | applies |
| Linux closure, activation, health, recovery | slide 9 | `apps/node-daemon/internal/platform/linux/`, `nix/modules/nixos/` | applies |
| Ephemeral root and persistent configuration | slide 9; academic architecture | `nix/modules/nixos/` | applies as proposal |
| Other Linux profiles | KNOWLEDGE platforms | `nix/modules/linux/`, `apps/node-daemon/internal/platform/linux/` | applies; timing open |
| Darwin closure, firmlink, activation, launchd/plists/apps | slide 10 | `apps/node-daemon/internal/platform/macos/`, `nix/modules/darwin/` | applies; timing open |
| NanoMDM, APNs, FileVault, TCC | slides 7, 10 | `apps/control-plane/internal/mdm/`, `infra/mdm/`, macOS daemon | applies as proposal |
| Windows generation bundles and native resources | slide 11; existing PowerShell | `apps/node-daemon/reference/powershell/`, `nix/modules/windows/` | applies |
| Daemon lifecycle, IPC, journals, restart recovery, updates | KNOWLEDGE implementation gaps | `apps/node-daemon/internal/service/`, platform daemons | applies |
| Audit/enforce modes, undeclared resources, offline behavior | KNOWLEDGE Q19 and open questions | control-plane deployments, daemon shared lifecycle | applies; authority open |
| Tailcat, WireGuard, peer discovery | slides 7–8, 12; later user decision | `networking/` | applies as internal propagation backbone |
| WAN, restricted NAT, DERP fallback | slide 12 | `networking/`, `infra/networking/relays/`, control plane | applies; not implemented |
| LAN P2P chunk delivery | slides 8, 12 | `packages/distribution/`, `networking/` | applies as proposal |
| Telemetry, heartbeats, drift, inventory, generation state | slides 12–14 | `apps/control-plane/internal/telemetry/`, `apps/web-console/src/operations/` | applies |
| PostgreSQL and optional TimescaleDB | slides 7, 13, 15 | `infra/database/`, control-plane telemetry | applies as proposal |
| Prometheus alerts | slide 13 | `infra/observability/`, control-plane telemetry | applies as proposal |
| Nix drafts, incident summaries, hardware tuning | slides 13–14, 17 | `apps/central-agent/src/workflows/` | applies as proposal |
| Shared stripped-down Pi fork without TUI | current user instruction | `packages/pi/` | applies |
| Central and node-local agent workflows | current instruction and patent | `apps/central-agent/`, `apps/node-agent/` | applies; authority open |
| Health-based assignment, withdrawal, updates, hierarchy | patent 0058, 0060, 0071 | `apps/control-plane/internal/agents/` | applies as patent proposal |
| Performance preprocessing, health, forecasts, component trends | patent 0056–0057, 0068–0069 | `packages/health/`, telemetry, node workflows | applies as patent proposal |
| Local training and federated aggregation | patent 0059, 0061 | `packages/federated-learning/`, node-agent workflows, central agents | applies as patent proposal |
| Audit reports, repair/upgrade/replacement, sustainability, longevity, cost-benefit | patent 0065–0069 | `packages/lifecycle/`, central workflows, operations views | applies as patent proposal |
| Existing IT asset-management integrations | patent 0079 | `packages/integrations/` | applies as patent proposal |
| Canary gates and fleet promotion | separate canary diagram | `apps/control-plane/internal/deployments/`, operations views | applies as proposal |
| Revert, failed activation, maintenance, reboot | slides 9, 11, 13; KNOWLEDGE recovery questions | control-plane deployments, daemon lifecycle and providers | applies; guarantees open |
| Shared network and IPC contracts | all producer/consumer paths | `packages/contracts/` | applies |
| Platform and cross-component verification | presentation benchmarks; KNOWLEDGE acceptance | `tests/platform/`, `tests/contracts/`, `tests/pi/`, `tests/end-to-end/` | applies |
| Convergence, bandwidth, drift, recovery measurements | slides 17–18 | `tools/benchmarks/` | applies; targets open |
| Platform documentation and implementation evidence | existing Windows docs; future platforms | `docs/platforms/windows/`, `docs/platforms/linux/`, `docs/platforms/macos/` | applies |
| Presentation, synopsis, diagrams and generators | academic artifacts | `artifacts/academic/` | applies |
| Interactive Pi TUI | explicit user exclusion | no folder | does not apply |
| Native Windows provider categories | confirmed scope | `apps/node-daemon/internal/platform/windows/` | applies; PowerShell reference preserved separately |
| Headless model API and agent loop | user fork decision | `packages/pi/ai/`, `packages/pi/agent/`, `tests/pi/` | applies; fork import pending |
| Userspace netstack, identity, policy, bootstrap | mesh architecture | `networking/netstack/`, `networking/identity/`, `networking/policy/`, `infra/networking/bootstrap/` | applies; trust details open |
| Direct/relay transfer and failure modes | mesh producers and consumers | `tests/transport/`, `networking/tests/` | applies; runtime suite pending |
| Attic/FBS S3 lifecycle, restart, failure and signed reads | selected dependency | `tests/storage/attic-fbs/` | applies; runtime integration pending |
| Service installation, removal, updates and release artifacts | node/server lifecycle | `packaging/`, daemon service/updates, `tests/recovery/` | applies; guarantees open |
| Protocols, schemas and generated consumers | shared Go and TypeScript clients | `packages/contracts/proto/`, `schemas/`, `generated/`, `tools/codegen/`, `docs/contracts/` | applies; contracts not authored |
| CI, upstream maintenance and operations guidance | monorepo maintenance | `.github/workflows/`, `tools/upstream/`, `docs/operations/` | applies; jobs not authored |

## Checks

All ownership folders in this ledger exist. Local Markdown links resolve.
The moved Windows module and CLI imports resolve, and the elevated launcher's
targets exist. Presentation assets still resolve. Existing implementation was
preserved; new folders contain ownership notes or `.gitkeep` scaffolding only.

Runtime tests do not apply to new ownership notes. Windows runtime behavior was
not tested on this Linux host. No fork import, new daemon code, commit, push, or
deployment is part of this folder-only change.
