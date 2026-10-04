# 07 — Nix modules

The `shepherd` flake (this monorepo) exports option modules consumed by the
config repo. They live in `nix/modules/` and are exported as
`lib.shepherd.modules.{shared,windows,nixos,darwin}`.

## Evaluation model for Windows

Windows is not a Nix system. `nix/modules/windows/` defines a standalone
module system evaluated with `lib.evalModules` (not NixOS), whose top-level
`config.shepherd.windows.plan.resources` is a list of resource attrsets that
serialize to the plan resource envelope ([02](02-contracts.md)). Shared intent
(`shepherd.shared.*`) is translated into Windows resources by
`nix/modules/windows/from-shared.nix`.

## Option tree

### `shepherd.shared.*` (all platforms)

| Option | Type | Windows mapping | NixOS mapping | Darwin mapping |
|---|---|---|---|---|
| `packages.<id>` | submodule {enable, version?, platforms} | `package.winget` | `environment.systemPackages` | `environment.systemPackages` / homebrew cask (if allowed) |
| `environment.variables.<name>` | str or {value, platforms} | `env.variable` (machine scope) | `environment.variables` | `launchd.user.envVariables` / `environment.variables` |
| `environment.path.append` / `.prepend` | list of str | `env.path` owned entries | `environment.extraInit` / `environment.systemPackages` profile paths | `environment.systemPath` |
| `services.<name>` | {state, startup} | `service.state` | `systemd.services.<name>.wantedBy` / enable | `launchd.daemons` (catalogued only) |
| `firewall.rules.<name>` | {direction, action, protocol, ports, remote?, program?} | `firewall.rule` | `networking.firewall.allowedTCPPorts/…` or nftables rules | `system.defaults.alf` (limited) + omitted |
| `accounts.<name>` | {ensure, groups, description} | `account.local` | `users.users.<name>` (isNormalUser, extraGroups) | `users.users` (limited; omitted where unsupported) |
| `network.dns`, `network.proxy` | list / submodule | `network.dns`, `network.proxy` | `networking.nameservers`, `networking.proxy` | `networking.dns` / omitted |
| `updates.policy` | {channel, deferDays, window} | `update.settings` | `system.autoUpgrade.enable = false` always [DEP-02]; upgrades via flake.lock | omitted / MDM |

### `shepherd.windows.*`

| Option | Resource | Notes |
|---|---|---|
| `registry.values.<name>` = {path, valueName, type, data, view, ensure} | `registry.value` | HKLM only in V1; HKCU/per-user omitted with reason |
| `registry.keys.<name>` = {path, ensure, view} | `registry.key` | |
| `env.variables.<name>` = {value, expand} | `env.variable` | Machine scope only [CFG-03] |
| `env.path.entries` = list | `env.path` | Shepherd-owned entries ([11](11-windows-providers.md#envvariable--envpath)) |
| `services.<name>` = {status, startupType} | `service.state` | |
| `packages.<id>` = {wingetId, version, scope} | `package.winget` | `version` required unless catalog pins |
| `firewall.rules.<name>` | `firewall.rule` | Rules tagged with Shepherd group |
| `accounts.<name>` = {ensure, groups, fullName, disabled} | `account.local` | No passwords in V1 |
| `policies.<name>` = {admxId?, registryPath, valueName, type, data, state, requireEngine} | `policy.setting` | Home: omitted unless `requireEngine = false`, then registry fallback marked `degraded` |
| `tasks.<name>` = {action, trigger, runAs: "SYSTEM"} | `task.scheduled` | |
| `updates` = {deferQualityDays, deferFeatureDays, targetReleaseVersion, activeHours, installInWindow} | `update.settings`, `update.install` | |
| `network.dns.<adapterMatch>` / `network.proxy` | `network.dns`, `network.proxy` | |
| `requireCapabilities` | list | Capabilities that must be present; otherwise the machine is blocked with a visible reason |

Each option module asserts types and produces `resources` entries with
`key`, `class`, `owner` (`gui` vs `custom` inferred from definition file
location via `options.<path>.files`), `dependsOn`.

### `shepherd.nixos.*`

A NixOS module (`nixosModules.shepherd-managed`) that:

- Enables and configures `shepherd-node` service (pinned package from the
  monorepo flake), its state dir, mesh settings, trusted keys, Attic
  substituter + public key.
- Disables competing auto-upgrade (`system.autoUpgrade.enable = false`) and
  nix-channel based updates [DEP-02, ADM-03].
- Sets `nix.settings.substituters` and `trusted-public-keys` from Shepherd.
- Keeps N=5 generations and never GC's the last working generation
  (`shepherd-node` pins it with a GC root) [DEP-05].
- Exposes `shepherd.nixos.healthChecks` (list of {name, command, timeoutSec})
  merged with defaults (system is `running` not `degraded`, `shepherd-node`
  can reach control plane, critical units active).
- Generates `shepherdObservations` from config: enabled systemd units,
  `/etc` managed files (hash), users and groups, firewall ports.

### `shepherd.darwin.*`

nix-darwin module:

- Installs `shepherd-node` launchd daemon.
- Maps `shepherd.shared` to nix-darwin options where possible.
- `shepherd.darwin.mdmProfiles` declares configuration profiles delivered by
  NanoMDM (payload type + content) — compiled into MDM commands by the control
  plane, not by nix-darwin ([13](13-macos-backend.md)).

## Testing

- `nix flake check` runs: option type tests, golden JSON for
  `shepherdWindows` from fixture profiles, NixOS VM test
  (`nixosTest`) that boots a machine with `shepherd-managed` and asserts
  `shepherd-node` starts, and a `darwin` eval-only check.
- Golden outputs live in `nix/tests/golden/` and are compared in CI.

## Acceptance

- A fixture profile using every `shepherd.shared` option evaluates on all
  three platforms; Windows output validates against `plan.v1` resource schema.
- Unsupported mappings appear in `omitted` with reason codes (not dropped).
- Conflicting GUI vs custom definition fails evaluation with a located error.
