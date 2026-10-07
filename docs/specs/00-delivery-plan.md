# 00 — Delivery plan

## Timeline

Twelve weeks (2026-10-05 → 2026-12-27), run as six two-week iterations. All
SRS V1 scope is P0. The calendar is fixed; the order below exists so that
work that unblocks others lands first.

| Iteration | Dates | Theme | Exit gate (must be demonstrable on VMs) |
|---|---|---|---|
| Weeks 1–2 | 2026-10-05 → 2026-10-18 | Foundations | Monorepo builds in CI; contracts v1 generated for Go and TS; Postgres schema migrates; control plane and daemon skeletons talk over a Tailcat tunnel in the lab; signing library verifies a DSSE envelope; spikes for Pi, NanoMDM, Attic+FBS reported |
| Weeks 3–4 | 2026-10-19 → 2026-11-01 | First vertical slice | A Windows VM and a NixOS VM enroll with a token; a hand-written profile in the config repo evaluates; Windows gets a signed plan that sets a registry value and a PATH entry; NixOS gets a closure from Attic and activates it; reports appear in the console inventory |
| Weeks 5–6 | 2026-11-02 → 2026-11-15 | Configure, approve, drift | GUI configurator authors profiles without raw Nix; diffs and approvals gate publication; groups, direct assignment, precedence; drift detection on both platforms; auto-fix toggle; packages, services, firewall, accounts providers. **DEM-01, DEM-02, DEM-03 pass** |
| Weeks 7–8 | 2026-11-16 → 2026-11-29 | Failure paths and fleet transport | Evaluation failures block publication; health checks and last-working recovery; offline/reconnect; peer distribution over Tailcat; DERP self-hosted; ISO enrollment for Windows and NixOS; removal; competing manager detection. **DEM-04, DEM-06, DEM-07, DEM-08 pass** |
| Weeks 9–10 | 2026-11-30 → 2026-12-13 | Agents and macOS | Pi fork headless runtime; central agent explanations and drafts; node agent diagnosis (probes, read-only sandbox), findings escalation, approved remediation commands, and repair requests; unsupported-setting equivalents; nix-darwin activation; NanoMDM enrollment and profiles; advanced Nix editor. **DEM-05 passes; macOS DEM-01/02 pass** |
| Weeks 11–12 | 2026-12-14 → 2026-12-27 | Hardening and release | Key rotation, revocation, admin auth hardening, audit completeness, capability table, packaging, release evidence, full DEM-01..08 per platform recorded |

## Lanes

Two lanes let two developers (and their agents) work in parallel with the
contracts in [02](02-contracts.md) as the only shared interface.

| Lane | Owns | Typical areas |
|---|---|---|
| **Server** | Everything that runs centrally or in the browser | control plane, database, configuration pipeline, Nix modules, build worker, Attic/FBS, NanoMDM server side, web console, central agent |
| **Node** | Everything that runs on a managed machine or between machines | node daemon, Windows/NixOS/macOS providers, Tailcat mesh, DERP, distribution, ISO enrollment, node agent |
| **Shared** | Interfaces and cross-cutting work | contracts, security primitives, tooling/CI, test harness, demos, release |

Rules for parallel work:

1. A contract change is its own PR touching `packages/contracts/` only, reviewed
   by the other lane before either lane depends on it.
2. Each lane ships a **fake** for the other side in weeks 1–2: the Server lane ships
   `shepherd-fakenode` (replays fixture reports), the Node lane ships
   `shepherd-fakecp` (serves fixture plans and accepts reports). Neither lane
   waits on the other's real implementation to test.
3. Fixtures under `packages/contracts/fixtures/` are the source of truth for
   both fakes and both real implementations.
4. The end of each two-week iteration has a joint integration session against
   the VM lab.

## Critical path

```text
contracts v1 ─┬─> control-plane node API ──┬─> deployment state machine ──> DEM-01
              │                            │
signing lib ──┼─> plan signing ────────────┤
              │                            │
              └─> daemon sync loop ──> Windows reconciler + providers ──> DEM-01/02
nix modules (windows) ──> plan compiler ───┘
config repo ──> GUI generated Nix ──> configurator UI ──> DEM-01 without raw Nix
Attic+FBS ──> build worker ──> NixOS activation ──> DEM-01 (NixOS)
tailcat spike ──> mesh transport ──> peer distribution, offline (DEM-07)
```

Anything on this path that slips moves the next iteration's exit gate. Non-path work
(agents, macOS, advanced editor) is scheduled after the path is green but is
still V1 scope.

## Board conventions

The single GitHub project **Shepherd V1** carries every item. Fields:

| Field | Values | Meaning |
|---|---|---|
| Status | Backlog, Ready, In progress, In review, Blocked, Done | Workflow state |
| Type | Epic, Feature, Task, Spike, Test, Docs | Epic = parent of a spec area; Feature = user-visible capability; Task = implementation unit; Spike = time-boxed investigation with a written result |
| Lane | Server, Node, Shared | Parallelization lane |
| Area | one of the spec areas | Component |
| Priority | P0, P1, P2 | All V1 scope is P0; P1/P2 reserved for post-V1 discoveries |
| Size | XS (<2h), S (≤½d), M (≤1d), L (≤2d), XL (≤4d, split if possible) | Agent-assisted effort |
| Week | Iteration Weeks 1–2 .. Weeks 11–12 | Planned two-week iteration |
| Start / Target | dates | Roadmap bars |
| SRS | text | Requirement IDs covered |

Views: **Roadmap** (roadmap by Target, grouped by Area), **Planning** (table by
Week and Lane), **Features** (Epics and Features only), **Issues** (board by
Status, Tasks/Spikes/Tests), plus **Server lane** and **Node lane** boards.

Relationships: every Task is a sub-issue of exactly one Epic; Features are
sub-issues of their Epic; "blocked by" links encode the dependency graph
used above. Labels (`weeks:1-2` … `weeks:11-12`) and milestones mirror Type, Lane, Area,
and Week for filtering outside
the project.

## Definition of done (all issues)

- Code merged to `main` through a reviewed PR that references the issue.
- Unit tests for new logic; integration test or VM evidence for anything that
  touches a machine, the network, or the database.
- Contract fixtures updated when a payload changed.
- The spec section updated if the implementation decided something new.
- No secret, key, or token committed; `gitleaks` passes.
- For machine-facing behavior: evidence (command output, report JSON, or
  screenshot of the console showing observed state) attached to the issue.
