# 13 — macOS backend

Two channels [Platform limits]: nix-darwin for declarative system
configuration applied by `shepherd-node`, and Apple MDM (NanoMDM + APNs) for
settings only MDM can manage. macOS does not get NixOS immutability or atomic
rollback guarantees.

## Requirements on the lab

- At least one Mac (Apple Silicon preferred) or a macOS VM on Apple hardware
  (UTM/Virtualization.framework). Record the exact model and macOS version in
  the capability table.
- An Apple Push Notification MDM certificate (requires Apple ID + vendor
  signing via mdmcert.download or an Apple Business Manager account).
  **Spike in weeks 1–2** confirms which path the team can obtain within the
  timeline; if neither is obtainable, MDM features are reported `unsupported`
  in the capability table, not faked.

## nix-darwin activation (`internal/platform/macos/darwin/`)

1. Nix installed (Determinate or upstream installer) during enrollment.
2. Fetch `darwinConfigurations.<host>.system` closure from peers/Attic; verify narHash.
3. Activate: `<storePath>/sw/bin/darwin-rebuild activate` equivalent —
   `nix-env -p /nix/var/nix/profiles/system --set <path>` then
   `<path>/activate` (as root; user activation where nix-darwin requires it).
4. Health: `shepherd-node` launchd job loaded, CP reachable, declared launchd
   daemons loaded, custom checks.
5. Recovery: re-activate last working generation; report unrecovered effects
   (e.g., `system.defaults` writes that user apps cached).

Drift observations: current system generation link, declared launchd daemons
loaded, `/etc` files managed by nix-darwin (hash), `defaults read` for
declared `system.defaults` keys, installed homebrew casks if homebrew module used.

## MDM (`apps/control-plane/internal/mdm/` + `infra/mdm/`)

- Deploy NanoMDM (pinned) behind the public ingress at `/mdm/` with its own
  TLS; SCEP via `micromdm/scep` or NanoMDM-compatible SCEP server for device
  identity certificates.
- Enrollment profile (`.mobileconfig`) generated per enrollment token, signed;
  contains SCEP payload, MDM payload (topic from APNs cert), and optionally a
  payload to install the `shepherd-node` pkg (`InstallEnterpriseApplication`
  command after enrollment).
- Control plane → NanoMDM API: enqueue commands (`InstallProfile`,
  `RemoveProfile`, `ProfileList`, `DeviceInformation`,
  `InstallEnterpriseApplication`), receive check-in/ack webhooks, map UDID ↔
  machine id.
- `shepherd.darwin.mdmProfiles` compile to profiles signed by the server; the
  set of installed Shepherd profiles is observed via `ProfileList` for drift.
- APNs traffic goes from NanoMDM to Apple directly over the internet, not the
  mesh [System architecture].

## Enrollment flow

1. Admin creates a macOS enrollment token → console offers the enrollment
   profile download and a signed `shepherd-node` pkg.
2. User/admin installs the profile (System Settings approval required for
   user-approved MDM) → NanoMDM check-in → control plane links device.
3. MDM pushes the pkg (or admin runs it) → `shepherd-node enroll` with the
   token embedded in the pkg postinstall → mesh identity created.
4. Inventory + capabilities reported; profile assignment proceeds as other platforms.

## Removal

Dashboard removal sends `RemoveProfile` for Shepherd profiles and the MDM
enrollment profile removal command if the profile is removable, revokes
identity; nix-darwin config stays (no restore promise) [ADM-02].

## Acceptance

- macOS DEM-01 (a `system.defaults` setting + package via nix-darwin) and
  DEM-02 (drift of a defaults key) on a real Mac with evidence.
- MDM: install and remove a configuration profile through NanoMDM; observed
  via `ProfileList` — or the documented `unsupported` result if APNs cert
  could not be obtained.
