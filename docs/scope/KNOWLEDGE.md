# Shepherd scope knowledge

Recorded on 2026-10-03 from the scope discussion and repository inspection.

This file consolidates the discussion. It distinguishes user decisions from
recommendations, open questions, and implementation evidence. It is not a claim
that the proposed system already exists or that the scope is finalized.

## Purpose and working agreement

### Monorepo architecture baseline — 2026-10-03

The user approved creating the complete folder structure and preserving empty
source folders with `.gitkeep`. This authorizes repository organization and
documentation; it does not claim that the planned services are implemented.

The following choices supersede the earlier presentation-only classification:

- One monorepo contains the Go control plane, web interface, build worker,
  central agent, node agents, node daemons, platform modules, networking,
  contracts, packaging, infrastructure, tests, and documentation. Turborepo is
  not a requirement. Build manifests and dependency locks are added when their
  actual implementations and versions are chosen.
- `packages/pi/` holds the custom stripped-down Pi fork. `ai/` owns model
  integration; `agent/` owns the headless agent loop, tools, and session runtime.
  The TUI is excluded. Central and node workflows use this shared fork under
  `apps/central-agent/` and `apps/node-agent/`. Agent mutation and approval
  authority remain open decisions.
- `apps/node-daemon/` owns the privileged node service, enrollment, IPC,
  validated plans, reconciliation, persistent journals, recovery, telemetry,
  and updates. Native provider folders cover Windows Registry, policies,
  packages, environment/PATH, services, tasks, firewall, networking, accounts,
  and updates; Linux NixOS and other-distribution profiles; and macOS Darwin
  activation and MDM coordination. The existing PowerShell implementation is
  preserved under `reference/powershell/`; a Go rewrite is not implemented.
- `networking/` is the backbone for internal control and data propagation,
  rather than an optional transport utility. It owns Tailcat, WireGuard,
  userspace netstack integration, identity, peer discovery, connectivity,
  access policy, transport, and DERP client/server integration. Enrollment
  bootstrap and relay deployment configuration live under `infra/networking/`.
  Direct LAN/WAN peers and restricted-network DERP fallback are explicit
  surfaces. Bootstrap traffic and external browser, model-provider, and Apple
  APNs connections need their own documented ingress/egress contracts; Apple
  APNs is not transported through the private mesh.
- `packages/distribution/` owns artifact selection, cache fetching, peer chunk
  transfer, and integrity checks over that network. The intended build path is
  Nix evaluation -> build worker -> signed NAR publication to Attic -> FBS
  object storage. Target hashes reach nodes over the mesh; nodes fetch missing
  cache objects or chunks from peers and verify them before activation.
- Self-hosted FBS is selected as Attic's planned S3-compatible storage service
  dependency. `infra/storage/fbs/` owns its pinned build/image, persistent disk,
  configuration, and deployment; `infra/storage/attic/` owns Attic. FBS remains
  an upstream dependency; its source has not been copied into this monorepo.
  No upstream revision or image digest has been selected yet. Attic remains
  the Nix cache layer; FBS supplies object persistence.
- FBS/Attic compatibility is not yet proven by a running integration. The
  acceptance home is `tests/storage/attic-fbs/`: SigV4, custom endpoint,
  path-style requests, object lifecycle, multipart upload/abort, presigned
  reads and node reachability, cache publication/substitution, persistence
  after restart, and failure handling. Direct object URLs returned by Attic
  must be reachable by enrolled nodes through the chosen network. FBS's
  single-node disk/SQLite design does not establish HA or backup guarantees.
- `nix/modules/` retains shared, NixOS, other Linux, Darwin, and Windows homes.
  `nix/templates/` separates GUI-generated, administrator-custom, and aggregator
  templates. `packaging/` separates server, Windows, Linux, macOS, and release
  artifacts. Academic PDFs, HTML, synopsis, diagram assets, and their generators
  remain together under `artifacts/academic/`.
- Patent surfaces retain explicit homes for health observations and forecasts,
  federated learning, agent assignment/withdrawal, lifecycle reporting,
  sustainability, and external asset-management integrations. Having a folder
  does not settle their pilot milestone or acceptance criteria.

The complete directory tree is in the [root README](../../README.md). The
[surface ledger](../development/layout-surfaces.md) maps the presentation,
patent, scope, and existing implementation to their owners.

### SRS status

This locks the agreed repository layout and the architecture choices above as
the current baseline. It does **not** lock a complete SRS. Platform milestones,
supported operations and capability handling, agent/deployment authority,
signing and enrollment trust, offline behavior, recovery guarantees by
operation, maintenance/reboot policy, scale, and measurable pilot acceptance
criteria still need explicit requirements. The open questions below remain
valid unless a later recorded user decision supersedes them.

The next deliverable is a working campus pilot. Administrators are the primary
users. The user accepted verified configuration deployment as the principal
promise: deploy declared configuration, verify machine state, and make failures
visible. Recovery guarantees still need to be defined by operation.

There is no deadline or external promise yet. Contributor capacity, pilot
hardware, acceptance owner, and measurable acceptance criteria remain open.

The user requested a complete grilling session to define scope. The interview
works in rounds: ask decisions whose prerequisites are settled, provide a
recommendation, wait for answers, and then ask dependent questions. Find facts
in the repository rather than asking the user to supply discoverable facts.
The scope discussion is complete only when every branch has been addressed and
the user confirms shared understanding. The original interview did not authorize
implementation. The later monorepo baseline authorizes folder organization and
documentation, while feature implementation remains separate.

The user asked for multiple-choice question tools. Use those tools for future
question rounds. Nine question cards were presented, then presented again on
request. No answers to those cards have been received in this conversation.
Invoking `$grill-me` delegates to the grilling session.

## Confirmed scope and intended behavior

### Platforms

- Windows and Linux are the pilot platforms.
- NixOS is the first-class Linux target.
- Profiles should also be available for other Linux distributions and macOS.
  Their timing and supported operations are not settled. Do not interpret this
  as a confirmed macOS pilot commitment.
- Windows Pro and Enterprise must be supported. Windows Home must not be
  excluded or left without visibility. The exact Home capability commitment
  and behavior for unsupported settings remain open.
- Supported Windows versions and builds have not been selected.

### Configuration and administration

- Nix is a hard requirement, but administrators do not have to write it.
- A configuration GUI is required. It should offer simple controls such as
  enabling a program, setting an environment variable, and updating registry
  values.
- The configurator generates Nix from GUI options.
- The GUI owns its generated configuration.
- Users can add separate custom Nix modules through the GUI.
- The GUI's core aggregator includes those modules with generated configuration.
- Custom definitions normally take precedence. Conflicts produce warnings.
- Users can explicitly choose to overwrite custom definitions through the GUI.
  Whether this edits custom source or creates a separate override is unresolved.
- Configuration should express shared cross-platform intent and permit
  OS-specific separation where needed. The meaning and acceptance tests for a
  cross-platform guarantee are unresolved.

### Managed state

- Environment configuration includes environment variables and PATH.
- Environment variables and PATH are system-wide. The user explicitly avoided
  per-user environment management because of Windows complexity.
- Windows registry configuration is required.
- Administrators must be able to configure firewall, policies, services,
  networking, and user accounts.
- The supported operations within those categories have not been bounded.
- Avoid inferring that excluding per-user environment management excludes local
  user-account management. Those are separate decisions.

### Proposed deployment pipeline

- For Linux and macOS, the user proposed delivering a signed package containing
  the Nix configuration. The package format, build location, artifact contents,
  activation mechanism, and applicability to other Linux distributions remain
  unspecified.
- For Windows, the server generates a finalized signed JSON configuration.
- The Windows client/watchdog service applies that configuration as needed.
- Signing and endpoint verification are intended requirements, not implemented
  guarantees demonstrated by this conversation.
- Watchdog enforcement mode, polling/notification behavior, offline behavior,
  and recovery behavior remain open.

## Open questions and recommendations

Recommendations below are proposals from the assistant. They are not accepted
decisions unless explicitly recorded above. A preselected MCQ is not an answer.

### Q21. Profiles outside the pilot platforms

When must profiles for other Linux distributions and macOS work, and what do
they manage?

Presented choices:

1. Later milestone, packages and environment only. Recommended.
2. During the pilot, packages and environment only.
3. During the pilot, full system management.

### Q22. Explicit GUI overrides of custom modules

Custom Nix sets a value to A and the GUI sets it to B. The user has settled that
custom normally wins, with an explicit GUI overwrite available. The storage
and future conflict behavior of that overwrite remain open.

Presented choices:

1. Preserve custom source, store an override separately, and require review when
   the overridden definition changes. Recommended.
2. Edit the custom module directly.
3. Preserve custom source and keep the override until manually removed.

The earlier question also asked what happens when a custom module changes
after an override. No answer has been received.

### Q23. Cross-platform semantics and missing capabilities

The earlier interview asked whether the guarantee means equivalent behavior
for supported shared intent, every setting working everywhere, or shared
configuration with platform-specific sections.

Recommendation: shared intent with explicit platform-specific settings. Do not
silently omit settings on an unsupported platform.

The latest MCQ narrowed the deployment decision to a machine lacking a required
capability:

1. Block deployment to that machine; report missing optional capabilities
   separately. Recommended.
2. Apply supported settings and report partial completion.
3. Block deployment to the entire selected fleet.

Still open: how settings become required or optional, how equivalent behavior
is tested, and whether application selections use a shared catalog or separate
per-OS package selections.

### Q24. PATH ownership

Machine-wide scope is settled. Ownership of the complete value is not.

Presented choices:

1. Manage only Shepherd-owned entries and preserve entries added by other
   installers. Recommended.
2. Replace PATH with the declared value.
3. Require administrator approval for each PATH change.

Recommendation: removal should remove only entries Shepherd owns.

### Q25a. Meaning of program controls

Does enabling a program mean installing it, making it available on PATH,
activating a service, launching it at login, or some combination? Does disabling
it uninstall it?

Presented choices:

1. Separate installation, removal, and service activation; preview removals.
   Recommended.
2. Enable installs and activates; disable uninstalls.
3. Manage installation only.

### Q25b. Program versions

Presented choices:

1. Pin versions where supported and approve upgrades explicitly. Recommended.
2. Automatically update to the latest available version.
3. Preserve existing versions unless an upgrade is requested.

### Q18. System-control boundaries

The proposed bounded catalog is:

- Named firewall allow/block rules.
- A selected catalog of named policies.
- Service running/stopped state and startup behavior.
- DNS and proxy settings.
- Local account presence and group membership.

Presented choices:

1. The bounded catalog is sufficient for the pilot. Recommended.
2. Also require static IP and Wi-Fi configuration.
3. Also require domain joining and password management.

These choices are suggestions, not a constraint that prevents selecting a
different combination. Arbitrary policy definitions, credentials, account
lifecycle, and exact required settings remain open.

### Q19. Watchdog authority and drift

Presented choices:

1. Administrators choose audit or enforce mode; default to audit. Recommended.
2. Always restore declared state automatically.
3. Report only; correction requires an explicit deployment.

All presented choices leave undeclared resources alone, but the user has not
yet accepted that ownership rule. Whether to remove undeclared software or
settings remains open.

### Q20. Pilot capacity

Presented test-fleet choices:

1. Four to six endpoints across Windows and NixOS, including physical hardware
   for both. Recommended.
2. Two virtual machines, one per OS.
3. Ten or more physical endpoints across both operating systems.

Still open: actual machine access, ability to repeatedly reboot and recover
machines, contributor count, skills, availability, budget, and who will operate
and accept the pilot. No deadline does not settle those questions.

## Earlier questions and unresolved commitments

The interview also raised the following decisions. Some depend on answers to
the current question round and have not yet been explored fully:

- Which administrator task provides the pilot's concrete acceptance scenario?
- What rollout, health-check, convergence, failure, and recovery measurements
  constitute success?
- Must existing Linux machines be reinstalled as NixOS, or are profiles enough
  for some pilot machines?
- Does Shepherd coexist with domain Group Policy or another management tool?
  Who owns a setting when those tools disagree?
- Is recovery bounded reversal, generation reapplication, or atomic rollback
  for each supported operation?
- Are arbitrary scripts allowed, and what guarantees apply to them?
- How are machines enrolled, authenticated, assigned configurations, updated,
  revoked, and removed?
- What are the deployment approval, maintenance-window, reboot, and offline
  rules?
- What access roles and secret-handling rules are needed for account and
  network administration?
- What exactly is signed, which identity signs it, and what does the endpoint
  validate before applying it?

The first round asked the user to classify three-OS support, Nix, machine
reset/immutability, Windows updates, Apple MDM, peer downloads, remote laptops,
AI summaries, AI package generation, and no-code configuration as required,
later, or removed. Only some have since been resolved. Nix, the GUI, Windows,
and Linux are required. The remaining feature classifications are open.

Earlier recommendations included a real campus pilot rather than a production
claim, a bounded typed resource catalog rather than arbitrary scripts, Git-
managed Nix, and audit-first rollout. Git-managed authoring was a recommendation
before the user established the GUI requirement; do not treat it as the agreed
administrator workflow.

## Repository findings

These are findings from read-only source and document inspection during the
conversation. No runtime tests were executed. Existing documentation reports
Windows probes; those reports are not new verification performed here.

### Implemented starting point

- A PowerShell Windows reference agent, resource providers, local CLI/service
  loop, journal/report output, drift audit, and probe/test harnesses exist.
- The service currently reads a local plan file and writes local reports.
- The repository inspection found no application Nix modules/evaluator, Linux
  or macOS agents, control server, dashboard, network enrollment/delivery,
  build-cache integration, plan-signature verification, or native service host.
- Documented Windows probe evidence came from a Windows 11 Home workgroup
  machine. It does not establish Pro/Enterprise, domain/MDM coexistence,
  production SYSTEM service behavior, or cross-platform fleet operation.

Sources: [agent README](../../apps/node-daemon/reference/powershell/README.md),
[service loop](../../apps/node-daemon/reference/powershell/agent-service.ps1), [test README](../../tests/platform/windows/README.md),
[Windows evidence](../platforms/windows/evidence.md).

### Gaps relevant to the proposed scope

- There is no dedicated environment-variable or PATH resource. Generic
  registry writes do not supply PATH ownership, merge behavior, propagation,
  or environment-specific validation.
- There are no firewall, network-configuration, or user-account providers.
  Inventory reads network adapter details but does not configure networking.
- The policy provider has a Home fallback that writes policy registry values.
  This does not establish that every policy is enforced on Home.
- User-scoped policy is explicitly unsupported in the implementation.
- There is no typed ADMX policy catalog/compiler. The published contract names
  ADMX identifiers, while the provider accepts raw registry values.
- The published `script.fleet.runAs` and `service.state.account` fields are not
  implemented as the advertised execution-identity controls.

Sources: [registry provider](../../apps/node-daemon/reference/powershell/Resources/Registry.Operations.ps1),
[inventory provider](../../apps/node-daemon/reference/powershell/Resources/Inventory.Report.ps1),
[policy provider](../../apps/node-daemon/reference/powershell/Resources/Policy.Setting.ps1),
[task/script provider](../../apps/node-daemon/reference/powershell/Resources/Task.And.Script.ps1),
[service provider](../../apps/node-daemon/reference/powershell/Resources/Service.State.ps1),
[plan schema](../platforms/windows/plan-schema.md).

### Contract and implementation disagreements

| Area | Documented proposal | Inspected implementation or disagreement |
| --- | --- | --- |
| Native Windows host | Architecture says Go; runtime document says Rust or C# | Current implementation is PowerShell |
| Transport | Embedded Tailcat mesh versus pinned outbound HTTPS | Current service uses local files |
| Windows rollback | Previous generation reapplication without reboot | Package undo cannot restore an already-installed previous version; updates and arbitrary scripts are not generally reversible |
| Journal durability | Persistent journal-driven reversal | JSONL is written, but undo uses the in-memory journal and reversal flags are not persisted for restart recovery |
| Initial rollout | Audit-first | Missing plan mode defaults to apply |
| Dependency execution | Dependencies must succeed before dependents | Ordering is dependency-based, but earlier failure does not gate dependent execution |
| Execution controls | Fixed resource classes, expiry, delayed apply, timeouts, failure stopping, automatic reversal | These guarantees are not implemented generally in the current executor |
| SYSTEM packages | winget COM under SYSTEM | Provider invokes winget CLI |
| Signed plans | Signature verification and unsigned-plan gate | Config placeholders are not wired into verification |
| Reports | Published status list | Executor also emits `drifted`, omitted from that list |
| Drift timing | Presentation claims three seconds; runtime describes four-hour audits | Detection and recovery acceptance targets remain unsettled |
| Immutability | Original brief asks for read-only root on every OS | Windows assessment replaces that promise with convergence and drift reporting |

Sources: [architecture](../../artifacts/academic/ARCHITECTURE.md),
[presentation](../../artifacts/academic/presentation.marp.md),
[Windows runtime](../platforms/windows/agent-runtime.md),
[executor](../../apps/node-daemon/reference/powershell/FleetAgent.psm1),
[package provider](../../apps/node-daemon/reference/powershell/Resources/Package.Winget.ps1),
[sample configuration](../../apps/node-daemon/reference/powershell/config.sample.json),
[Windows assessment](../platforms/windows/assessment.md).

### Broader ideas in the existing documents

The original brief and presentation describe a substantially wider system:
three OS backends, immutable/resetting Linux roots, Apple MDM, central build
workers, Attic/S3 caching, signed artifacts, Tailcat/WireGuard networking, peer
distribution, remote laptops, a database-backed dashboard, telemetry, AI
incident summaries, AI package drafts, and hardware-tuning proposals.

Those documents also name Go, PostgreSQL, Next.js/React, NanoMDM, optional
TimescaleDB, and a semester timeline. The later monorepo baseline accepts the
Go backend, headless Pi fork, networking backbone, and FBS-backed Attic storage
direction. Exact versions, scaling thresholds, optional components, frontend
framework, and timeline commitments remain unresolved.

Sources: [original brief](../../artifacts/academic/what-this-is.md), [architecture](../../artifacts/academic/ARCHITECTURE.md),
[presentation](../../artifacts/academic/presentation.marp.md).

## Next interview round

Collect answers to Q18–Q25 using the question tools. Then expand the interview
into application mappings, profile assignment and precedence, deployment
artifacts, approval and enforcement, capability detection, recovery, trust,
and concrete pilot acceptance tests. Do not mark the scope finalized until the
remaining branches are settled and the user confirms shared understanding.

The original scope interview made no implementation changes. The later
monorepo task reorganized files, repaired references, added placeholder folders,
and updated documentation. No new service implementation, commit, push, or
deployment is included in that task.
