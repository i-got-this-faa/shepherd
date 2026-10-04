# Shepherd software requirements specification

| Document field | Value |
|---|---|
| Product | Shepherd |
| Document version | 1.0 |
| Date | 2026-10-03 |
| Release scope | V1 |
| Status | Product requirements baseline |

This specification is self-contained. It defines product scope, architecture
constraints, required behavior, platform limits, and acceptance criteria. No
repository document or conversation history is needed to interpret it.

Requirements describe expected behavior, not completed implementation. The word
"must" identifies a mandatory requirement. Requirement identifiers support
traceability from implementation and tests to this specification. Release
capability tables, detailed protocols, and operational limits must be verified
before a release claims compliance.

## Purpose and users

Shepherd lets an administrator declare, deploy, observe, and recover machine
configuration through a GUI and agents. Programming knowledge is not required.
The initial operator role is administrator. Administrators can use agents or
complete supported operations manually without an AI provider.

## Terms and definitions

| Term | Meaning |
|---|---|
| Managed machine or node | An enrolled computer whose configuration Shepherd manages |
| Control plane | The central service that owns machine identities, approved targets, deployment state, and reports |
| Node daemon | The privileged machine service that observes state and executes validated platform operations |
| Agent | An AI worker that inspects information, explains results, prepares drafts, or requests authorized drift repair |
| Profile | A named desired configuration assigned to machines directly or through a group |
| Effective profile | The single profile selected after applying direct-assignment precedence |
| Desired state | The approved configuration a machine is assigned to maintain |
| Observed state | Machine state measured by supported platform providers |
| Drift | A difference between observed managed state and approved desired state |
| Draft | A proposed configuration change that has not been approved for deployment |
| Diff | A reviewable description of additions, changes, and removals between configurations or managed states |
| Generation | An identified configuration artifact and the metadata needed to activate and track it |
| Last working configuration | A retained generation whose activation and health checks succeeded |
| Nix Flake | The versioned Nix configuration and pinned inputs used to evaluate desired state |
| NixOS | The declarative Linux distribution required for managed Linux machines |
| nix-darwin | The Nix-based system configuration framework used for supported macOS settings |
| MDM | Mobile device management, used for Apple settings outside the supported nix-darwin configuration |
| APNs | Apple Push Notification service, used to notify Apple devices of MDM commands |
| NAR | Nix archive format used to distribute built store objects |
| Attic | The Nix binary cache that publishes and serves built artifacts |
| FBS | The self-hosted S3-compatible object storage service selected as Attic's storage backend |
| DERP | A relay used when the private network cannot establish a direct connection |
| OpenAI-compatible API | A model-provider interface configured for the agent runtime; actual feature support requires testing |

## Release boundaries

V1 includes the configurator, optional advanced Nix editing, manual management,
central and node agents, enrollment, inventory, configuration deployment, profile
assignment and switching, drift detection and optional repair, recovery, approved
updates, and reporting of operation results. The Go control plane,
headless Pi fork, Tailcat/WireGuard network with DERP fallback, peer distribution,
and Attic backed by self-hosted FBS remain architecture requirements.

V1 includes Windows, NixOS, macOS/nix-darwin and Apple MDM, AI explanations and
package drafts, and remote-machine operation. Their presence in scope does not
establish that their platform integrations already work.

Hardware tuning, federated learning, and lifecycle reports are V2. Management of
other Linux distributions in place is excluded for now; existing Linux machines
must be reinstalled as NixOS. The agent runtime has no terminal user interface.

Windows Enterprise and Pro receive primary support. Home receives secondary,
capability-dependent support with visible limitations. Exact tested OS versions,
editions, macOS versions and NixOS revisions belong in a release capability table;
no untested version is promised by this SRS.

## Technologies and dependencies

The following stack is selected for Shepherd. "Selected" specifies the intended
technology; it does not claim that a dependency has been imported, deployed, or
tested. Exact versions must be pinned with the implementation and release.

| Area | Technology or dependency | Use and selection status |
|---|---|---|
| Control plane | Go | Selected implementation language for the central backend |
| Configuration | Nix, Flakes, and Nixpkgs | Required configuration language, pinned inputs, package definitions, and system evaluation/builds |
| Linux | NixOS | Required managed Linux OS; existing Linux installations are replaced |
| macOS configuration | nix-darwin | Selected framework for supported declarative macOS configuration |
| Apple management | NanoMDM and Apple APNs | Selected MDM integration and notification service for supported Apple profiles and commands |
| Agents | Shared stripped-down Pi fork | Selected TypeScript-based agent/model runtime for central and node workers, without the interactive TUI |
| Model access | OpenAI-compatible API | Required configurable provider interface; no specific provider or model is mandated |
| Database | PostgreSQL | Selected persistent store for inventory, assignments, deployments, and reports |
| Private networking | Tailcat and userspace WireGuard | Selected basis for internal control and data communication |
| Network relay | DERP | Required fallback for restricted networks where direct connectivity is unavailable |
| Network stack | Userspace netstack | Required network integration; exact library and revision remain to be selected |
| Nix binary cache | Attic | Selected cache layer for publication and retrieval of built Nix artifacts |
| Object storage | Self-hosted FBS with an S3-compatible interface | Selected Attic storage backend; compatibility must be proven before deployment |
| Windows configuration | Signed JSON plans and native Windows resource providers | Selected execution contract; provider implementation language and APIs require an implementation specification |
| Web console | Next.js 16 | Selected framework for the browser-based administrator GUI; exact 16.x release and UI component library remain to be selected |

Go, database, Nix, runtime, and platform versions are deliberately unspecified
until an implementation pins and tests them. Node.js versus another compatible
TypeScript runtime, RPC encoding, build tooling, and deployment
packaging are implementation choices. No framework or version is required merely
because it appeared in an earlier proposal.

### Deployment dependencies

The central installation needs the control plane, PostgreSQL, Nix build capacity,
the artifact cache/storage services, and the private network's bootstrap and
relay services. Build workers need the toolchains and inputs for their supported
target platforms. Platform-specific build placement must be validated; a single
host must not be assumed to build every target.

Managed machines need a Shepherd daemon and the platform components required to
apply their assigned settings. Node agents additionally need the shared agent
runtime and access to an authorized model service. macOS management requires
Apple enrollment prerequisites, MDM identity material, APNs credentials, and
connectivity to Apple services. Credentials must remain outside source control
and uploaded configuration documents.

AI-backed workflows need a configured model API endpoint and its authorization.
Manual configuration, deployment, drift observation, and deterministic repair
must not require a successful model API call.

### Dependency management and release evidence

Each release must record dependency versions or immutable revisions, runtime
requirements, licenses/notices, and relevant compatibility tests. Nix inputs must
be locked. Forked Pi source must retain its upstream license notices and revision
tracking. FBS and other deployed upstream services must have pinned source
revisions or image digests. Applicable language-package dependencies must use
their implementation's lock or checksum mechanism.

Attic/FBS acceptance must cover authenticated S3 requests, custom endpoints,
object upload/read/delete, multipart completion/abort, signed reads where used,
cache publication/substitution, persistence after restart, and endpoint
reachability. Choosing both services does not establish their interoperability.

Optional database extensions, monitoring products, container systems, and CI
services are not mandatory dependencies in this baseline. Their introduction
must identify their operational purpose and deployment requirements.

## System architecture and external interfaces

| Component | Responsibility |
|---|---|
| Web console | Configuration authoring, advanced Nix editing, inventory, assignment, approvals, deployment progress, drift, recovery, and removal |
| Go control plane | Enrollment, identity, configuration evaluation coordination, approved targets, deployment authorization, reports, and audit records |
| Build worker | Isolated Nix evaluation/build execution and publication of verified artifacts through the authorized signing process |
| Central agent | Fleet-level inspection, explanations, and configuration or package drafts |
| Node agent | Machine-local analysis and requests for authorized repair through the daemon |
| Shared headless Pi runtime | Model integration, agent sessions, tool execution, and common runtime behavior for central and node agents |
| Node daemon and platform providers | Privileged observation, artifact verification, activation, reconciliation, persistent operation records, and recovery |
| PostgreSQL | Persistent control-plane inventory, assignments, deployment state, and audit/report records |
| Attic and FBS | Signed Nix cache publication and persistent object storage |
| Tailcat, WireGuard, and DERP | Private control/data communication, direct connectivity, and restricted-network relay fallback |
| Apple MDM service | Apple configuration profiles and commands delivered through the supported MDM/APNs mechanism |

The configuration flow is:

1. An administrator uses the GUI or advanced Nix editor, or reviews an agent draft.
2. Shepherd resolves profile assignment and evaluates the Nix Flake.
3. Validation/build errors prevent publication of the invalid configuration.
4. An authorized approval permits publication and deployment of the selected
   configuration identity.
5. The server publishes signed artifacts and assigns an identified target.
6. A node obtains artifacts, verifies them, and activates the platform plan.
7. The node measures managed state and reports activation, health, and drift.
8. Failed activation initiates recovery toward the last working configuration,
   with any unrecovered effects reported separately.

NixOS receives built system configuration suitable for NixOS activation. macOS
uses nix-darwin artifacts and Apple MDM for supported settings. Windows receives
a finalized signed JSON plan produced from server-side Nix evaluation. Windows
providers apply its supported resources; Windows does not run NixOS activation.

Internal control, telemetry, artifact transfer, and peer distribution use the
private network contract. Nodes may obtain verified artifacts from the cache
or peers; direct and relay delivery must preserve artifact identity and trust.
Enrollment bootstrap, browser access, external model-provider requests, and
Apple APNs require separate authenticated ingress/egress interfaces. APNs traffic
is not carried as an internal private-mesh service.

The browser uses control-plane authorization for administrator operations.
Agents use bounded tools and a configurable model endpoint. Platform operations
cross the daemon boundary through validated requests. Neither interface may
bypass approval or artifact verification.

## Configuration and GUI

- CFG-01: The normal workflow must use structured GUI controls to author
  configuration. A hidden advanced editor must allow raw Nix when desired.
- CFG-02: GUI-generated configuration and administrator-custom modules must feed
  the same Nix evaluation and deployment pipeline. The GUI must not overwrite
  custom source merely because it renders or edits generated settings.
- CFG-03: The configurator must expose application configuration, services,
  policies, firewall, networking, local accounts, system environment/PATH, and
  Windows Registry settings through supported platform resources. Settings remain
  declared in Nix; Windows receives evaluated platform plans rather than running
  NixOS activation. Environment and PATH management are system-wide.
- CFG-04: Changes must be reviewable as diffs. Configuration edits, approval,
  deployment, and observed machine state must remain distinguishable.
- CFG-05: Incompatible Nix definitions must produce an evaluation/build error
  visible in the GUI and block publication of that invalid configuration. Normal
  Nix module priorities and explicitly authored overrides may resolve definitions;
  Shepherd must not silently discard a build conflict.
- CFG-06: Unsupported platform settings must be reported and omitted from that
  platform's application plan. Omission must be visible as incomplete capability
  coverage, rather than reported as successful enforcement of that setting. An
  agent may propose an equivalent; it must not silently change approved intent.
- CFG-07: Resource ownership and changes must be represented in the diff/plan.
  A diff alone must not be treated as evidence that an endpoint has converged.
  Destructive changes and resource removal must be explicit in the plan.

## Profiles and assignment

- PRF-01: An administrator must be able to assign a profile to a group or directly
  to a machine. A direct special profile must take precedence over its group
  profile. It replaces the effective group assignment, rather than implicitly
  merging conflicting settings.
- PRF-02: Removing a direct assignment must restore the applicable group profile.
- PRF-03: A machine must have one unambiguous effective profile. Incompatible
  group assignments must be reported and resolved before dispatch; selection
  must not depend on incidental processing order.
- PRF-04: Switching profiles must produce a reviewed transition plan and expose
  the assigned target, active configuration, and transition result separately.

## Agents and manual operation

- AGT-01: Supported administrator operations must remain usable without AI.
  Disabling AI or losing its provider must not disable manual fleet management.
- AGT-02: Agents must use a configurable OpenAI-compatible API through the shared
  headless runtime. Compatibility must be tested against the selected provider;
  an API label alone does not establish support for its tools or streaming.
- AGT-03: Agents may inspect state, explain failures, and prepare configuration
  or package drafts. Drafts follow the same validation path as manual changes.
- AGT-04: The automatic-fix toggle authorizes repair of drift toward the current
  approved configuration only. It must not authorize approval, new configuration
  deployment, independent upgrades, or arbitrary changes in desired state.
- AGT-05: Deploying a new configuration requires approval. Admin/agent initiation
  must not bypass that requirement; the drift toggle grants no approval authority.
  Approval records and tool authorization must be explicit in the control plane.
- AGT-06: Privileged execution belongs to the daemon and validated platform
  providers. Agents and browsers must not obtain signing keys or bypass plan
  validation through an unrestricted privileged shell.

## Deployment, drift, and recovery

- DEP-01: The server must evaluate/build approved configuration, publish signed
  artifacts, assign targets, and record activation results. Nodes must verify
  artifact identity and authorization before applying them. Peer or relay delivery
  must not bypass verification.
- DEP-02: Applications must not independently upgrade outside Shepherd's
  configuration. Upgrades originate from the server after approval. OS and
  Shepherd component updates must also be controlled through Shepherd config.
- DEP-03: Nodes must observe managed state and report drift even when automatic
  repair is disabled. When enabled, repair must target approved desired state
  and report success or failure. Nix evaluation is not a drift observation.
- DEP-04: Offline operation must retain the last approved configuration. Offline
  status must be visible; cached reports must not be presented as fresh evidence.
  Reconnection must reconcile the latest authorized target without bypassing
  configured deployment or reboot restrictions.
- DEP-05: Recovery must target the last working configuration, verified through
  activation and health results, rather than simply the most recent attempted
  configuration. The last working configuration must remain available for recovery.
- DEP-06: A provider must report which effects it can restore and any failed or
  irreversible effects. Restoring a Nix generation must not claim restoration of
  mutable application data. Windows and macOS must not claim universal atomic
  rollback. Interrupted activation must retain enough durable state for recovery.
- DEP-07: Maintenance, reboot, and rollout rules must be configuration-driven and
  visible before execution. This specification does not mandate fixed canary
  percentages, timing defaults, or automatic promotion.

## Enrollment, removal, and management authority

- ADM-01: Windows and NixOS onboarding must support installation-image ISO
  enrollment that establishes the node daemon, machine identity, and server trust.
  macOS enrollment must use a platform-supported installation/MDM workflow;
  this SRS does not require a custom macOS installation ISO.
- ADM-02: Removing a machine from management must be an administrator dashboard
  action. The removed identity must cease receiving authorized new deployments.
  Removal does not promise OS reinstallation, restoration of pre-enrollment state,
  or automatic endpoint software uninstallation.
- ADM-03: Only one configuration manager may own a managed machine at a time.
  Shepherd must detect and block competing management before conflicting writes.
  This applies to configuration managers, not ordinary application software.
  Protected/domain-enforced policies require explicit ownership resolution;
  Shepherd must not pretend it can override an external authority it cannot disable.
- ADM-04: Enrollment must establish machine identity and authorized server trust.
  Revocation, signing-key rotation, secret storage, and administrator authentication
  must be specified and tested before deployment outside a controlled demo.
- ADM-05: Operator and machine actions must record actor, configuration identity,
  target, result, and failure reason without exposing credentials.

## Platform limits

NixOS declaratively reproduces system configuration but excludes mutable state.
nix-darwin covers part of macOS configuration; MDM supplies additional platform
management. Shepherd must verify supported managed state rather than infer
convergence from a build, package installation, or declaration alone.

The release capability table must name implemented operations, platform/edition
restrictions, observed-state checks, removal behavior, and recovery support.
Arbitrary scripts, credential management, domain joining, and unsupported policy
operations are not implied merely by a broad category in CFG-03.

Supporting references: [NixOS configuration model](https://nixos.org/guides/how-nix-works/),
[nix-darwin](https://github.com/nix-darwin/nix-darwin/blob/master/README.md), and
[Apple device management](https://support.apple.com/guide/deployment/intro-to-device-management-profiles-depc0aadd3fe/web).
The requirements and limits above are stated within this document. These
optional references provide background and are not required to interpret it.

## Release specifications and verification obligations

The following release details remain to be specified and verified. Their values
must be published with the release; this document does not invent defaults or
claim that untested integrations work.

| Area | Required release detail |
|---|---|
| Platform compatibility | Tested OS versions and editions, supported resource operations, and explicit Home limitations |
| Management ownership | Detectable competing managers and the supported process for establishing exclusive ownership |
| Configuration changes | Resource ownership, PATH update semantics, removal effects, and profile transition validation |
| Enrollment and identity | Bootstrap authentication, approval, credential storage, revocation, and platform-specific enrollment steps |
| Artifact trust | Signed payloads, trust roots, key rotation, verification, and rejection of unauthorized targets |
| Deployment policy | Maintenance windows, reboot permissions, approval authorization, rollout rules, and cancellation behavior |
| Recovery | Health checks, last-working-generation retention, durable restart recovery, and reversible effects per provider |
| Model compatibility | Tested providers/models, supported tools, streaming behavior, and handling of unavailable providers |
| Storage and distribution | Verified Attic/FBS compatibility, authenticated object operations, integrity checks, peer/relay behavior, and backup/restore procedures |
| Operational capacity | Measured deployment, drift, recovery, and fleet-scale results for the tested environment |

Implementation must preserve the mandatory requirements while specifying these
details. Any change to release scope or mandatory behavior requires a revised
version of this SRS.

## Demo acceptance

No particular hardware model is required. Acceptance must use running managed
machines and observed endpoint results, not screenshots of planned UI alone.

| ID | Scenario | Required observable result |
|---|---|---|
| DEM-01 | Author and deploy through the GUI without AI or raw Nix | Reviewed config reaches a machine; actual managed state matches; dashboard reports its active configuration |
| DEM-02 | Introduce drift in a supported setting | Drift appears with automatic repair disabled; enabling repair restores the approved value and records the result |
| DEM-03 | Assign a group profile, then a direct special profile | Direct profile takes effect; removing it restores the group profile without an ambiguous target |
| DEM-04 | Submit an incompatible Nix configuration | Evaluation/build fails visibly; no invalid target replaces the machine's working configuration |
| DEM-05 | Request an unsupported setting | Limitation is visible; the agent may propose an equivalent; omitted settings are not reported as enforced |
| DEM-06 | Fail an activation | Last working configuration is recovered where supported; unrecovered effects remain visible |
| DEM-07 | Disconnect and reconnect a node | Last approved state remains available; offline status is visible; reconnection reconciles an authorized target |
| DEM-08 | Remove a machine in the dashboard | Managed inventory reflects removal; its identity cannot obtain a new authorized deployment |

The primary demo story is deployment, drift detection/repair, and profile
switching. The additional cases verify the related failure and reverse paths.
Platform results must be reported individually. A Windows Home demonstration
does not establish Enterprise/Pro support; a NixOS result does not establish macOS
or Windows behavior. Timing and fleet-scale targets require measurements before
they are advertised; this SRS invents no endpoint count or latency commitment.
