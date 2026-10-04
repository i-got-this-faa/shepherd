# Shepherd V1 implementation specifications

These specifications turn the [SRS](../scope/SRS.md) into buildable work for a
six-week V1 delivery by two developers working with coding agents. Every GitHub
issue on the **Shepherd V1** project links to one section of these files. The
SRS remains authoritative for *what* must happen; these files decide *how*.
When a spec and the SRS disagree, the SRS wins and the spec must be corrected
in the same pull request that discovers the conflict.

| # | Spec | Owns | Primary lane |
|---|---|---|---|
| 00 | [Delivery plan](00-delivery-plan.md) | Weeks, lanes, critical path, demo gates, board conventions | Both |
| 01 | [Repository and tooling](01-repository-and-tooling.md) | Go/TS workspaces, Nix dev shell, CI, codegen, lint, local lab | Both |
| 02 | [Contracts](02-contracts.md) | Protobuf APIs, plan/report/journal JSON schemas, versioning | Both |
| 03 | [Security and trust](03-security-and-trust.md) | Keys, signing, DSSE envelopes, admin auth, secrets, audit | Both |
| 04 | [Control plane](04-control-plane.md) | Go service layout, console API, node API, background workers | Server |
| 05 | [Database](05-database.md) | PostgreSQL schema, migrations, retention | Server |
| 06 | [Configuration pipeline](06-configuration-pipeline.md) | GUI model, generated Nix, config repo, evaluation, diffs, capability coverage | Server |
| 07 | [Nix modules](07-nix-modules.md) | `shepherd.*` options for Windows, NixOS, Darwin, shared intent | Server |
| 08 | [Build and artifacts](08-build-and-artifacts.md) | Build worker, signing, Attic, FBS, artifact identity | Server |
| 09 | [Deployment and recovery](09-deployment-and-recovery.md) | Approval, rollout, maintenance windows, health, last working generation | Server + Node |
| 10 | [Node daemon](10-node-daemon.md) | Go daemon core: service host, sync loop, reconciler, journal, drift, offline | Node |
| 11 | [Windows providers](11-windows-providers.md) | Registry, env/PATH, services, packages, firewall, accounts, policy, tasks, updates, network | Node |
| 12 | [NixOS backend](12-nixos-backend.md) | Closure fetch, activation, health, rollback, drift observation | Node |
| 13 | [macOS backend](13-macos-backend.md) | nix-darwin activation, NanoMDM, APNs, profiles | Node + Server |
| 14 | [Networking](14-networking.md) | Tailcat mesh, DERP, node identity, admission, discovery | Node |
| 15 | [Distribution](15-distribution.md) | Cache fetch, peer chunk transfer, integrity | Node |
| 16 | [Enrollment and removal](16-enrollment-and-removal.md) | ISO enrollment, bootstrap, exclusive manager, removal | Node + Server |
| 17 | [Web console](17-web-console.md) | Next.js 16 console, configurator, advanced editor, operations views | Server |
| 18 | [Agents](18-agents.md) | Pi fork, central agent, node agent, tools, authority | Server + Node |
| 19 | [Testing and demo](19-testing-and-demo.md) | Test pyramid, VM lab, DEM-01..08 automation | Both |
| 20 | [Operations and release](20-operations-and-release.md) | Packaging, deployment, observability, capability table, release evidence | Both |

## Reading order for a new contributor or agent

1. SRS, then [00-delivery-plan](00-delivery-plan.md).
2. [02-contracts](02-contracts.md) and [03-security-and-trust](03-security-and-trust.md): every component speaks these.
3. The spec for the issue you picked up.

## Conventions used in every spec

- **MUST / SHOULD / MAY** follow RFC 2119. Every MUST traces to an SRS ID in
  brackets, for example `[DEP-05]`, or is marked `[impl]` when it is an
  implementation decision made by this spec.
- Paths are repository-relative.
- "Node" means a managed machine running `shepherd-node`. "Server" means the
  control plane plus its build worker, database, Attic, FBS, and DERP relay.
- Spec section anchors are stable. Issues link to them; rename a heading only
  together with the issues that reference it.
- A spec section is "done" when its acceptance list passes on a real VM or
  machine, not when the code compiles [SRS: Demo acceptance].
