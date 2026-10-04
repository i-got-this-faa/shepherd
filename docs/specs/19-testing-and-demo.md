# 19 — Testing and demo

## Test layers

| Layer | Where | Runs in CI | Notes |
|---|---|---|---|
| Unit (Go) | next to code | ✅ | table tests; fakes for OS APIs |
| Unit (TS) | vitest | ✅ | console logic, agent workflows |
| Contract | `tests/contracts/` | ✅ | fixtures validated by Go + TS; fake ↔ real cross-checks |
| Nix | `nix/tests/`, `nix flake check` | ✅ | option evaluation goldens, nixosTest for node |
| Integration | `tests/integration/` (docker-compose) | label/nightly | Postgres, FBS, Attic, CP, fakenode, derper |
| Storage | `tests/storage/attic-fbs/` | label/nightly | see [08](08-build-and-artifacts.md) |
| Transport | `tests/transport/`, `networking/tests/` | partial (netns) | DERP-only via blocked UDP |
| Platform | `tests/platform/windows/`, `.../nixos/`, `.../macos/` | windows runner subset | provider conformance on VMs |
| Recovery | `tests/recovery/` | lab | crash-during-apply, failing health |
| E2E UI | Playwright in `apps/web-console/e2e/` | ✅ (against compose + fakenode) | |
| Demo | `tests/end-to-end/dem-0X/` | lab | scripted DEM scenarios with evidence capture |

## VM lab

| VM | Purpose |
|---|---|
| `win11-pro-1`, `win11-pro-2` | Primary Windows support, peer distribution |
| `win11-home-1` | Home limitations visibility |
| `nixos-1`, `nixos-2`, `nixos-3` | NixOS activation, peers |
| Mac (physical or VM) | nix-darwin, MDM |
| `server` (host or VM) | docker-compose stack or NixOS server module |

Snapshots: `clean` (fresh OS), `enrolled` (after enrollment). Scripts revert
snapshots between demo runs. Network profiles: `lan` (bridged/NAT), `isolated`
(UDP blocked → DERP only), `offline` (link down).

## Demo scenario scripts (DEM-01..08)

Each `tests/end-to-end/dem-0X/` contains `README.md` (manual steps),
`run.sh` (automation where possible via `shepherdctl` + Playwright + VM
commands), and `evidence/` captured per platform: console screenshots, report
JSON, endpoint command output proving observed state (e.g., `reg query`,
`systemctl show`, `defaults read`).

| DEM | Automation sketch |
|---|---|
| 01 | Playwright: create profile, add registry value + PATH entry + package (Windows), service + package (NixOS); approve; deploy; poll until healthy; endpoint check via WinRM-free method (guest agent / SSH on NixOS / `virsh qemu-agent-command` on Windows) |
| 02 | Endpoint: modify registry value / stop service; wait drift; assert finding with auto-fix off; enable auto-fix; assert repaired + repair report |
| 03 | Assign group profile A; then direct profile B; assert B active; remove direct; assert A active; assert no conflict state |
| 04 | Advanced editor: add conflicting custom definition; assert eval error located; assert machine target unchanged |
| 05 | Request unsupported setting (policy on Home with requireEngine) → omitted shown; agent proposes equivalent draft; assert not approved automatically |
| 06 | Profile with failing health check → deploy → assert recovered to last working; Windows: also a package install to show unrecovered effect |
| 07 | Switch VM network to offline; wait stale; change target; restore; assert converged and stale labels cleared |
| 08 | Remove machine in console; assert heartbeat denied and no target for identity |

Platform results are reported individually [Demo acceptance].

## Fakes

- `shepherd-fakenode`: enrolls N virtual machines, heartbeats, replays report
  fixtures (success, failure, drift) → lets Server lane test without VMs.
- `shepherd-fakecp`: serves fixture targets/plans signed with a test key,
  records reports → lets Node lane test without the control plane.

## Acceptance

- CI green on every PR with unit, contract, nix, e2e-against-fakes.
- DEM-01..08 evidence folders filled for Windows Pro, NixOS; Windows Home and
  macOS where applicable, by end of week 6.
