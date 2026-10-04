# 12 — NixOS backend

`apps/node-daemon/internal/platform/linux/nixos/`. NixOS is the only managed
Linux in V1; other distributions must be reinstalled as NixOS [Release boundaries].

## Activation

Given a verified plan with `artifacts[0] = {kind: nix-closure, storePath, narHash}`:

1. **Fetch**: `nix-store --realise <storePath>` (or `nix copy --from
   <substituter>`) with substituters = peers first (local HTTP cache served by
   the distribution layer, [15](15-distribution.md)) then Attic. `trusted-public-keys`
   includes Attic's cache key only. Verify `nix path-info --json` narHash of
   the root equals the plan's `narHash` [DEP-01].
2. **Pin**: add GC root `/nix/var/nix/gcroots/shepherd/target`.
3. **Window**: wait for `applyAfter`/window.
4. **Activate**: `nix-env -p /nix/var/nix/profiles/system --set <storePath>`
   then `<storePath>/bin/switch-to-configuration switch`. Capture exit code and
   output (journal it). If the plan requires boot-only activation
   (kernel change and `rebootPolicy=next-boot`), use `boot` instead and report
   `rebootRequired`.
5. **Health**: run health checks: `systemctl is-system-running` ∈ {running}
   (degraded → unhealthy unless allow-listed units), declared critical units
   active, control plane reachable over the mesh, plus custom checks from
   `shepherd.nixos.healthChecks`. Timeout from plan.
6. **Commit**: on healthy, move GC root `last-working` to this path; report.
7. **Recover**: on failure/unhealthy, set system profile back to last working
   store path, `switch-to-configuration switch`, re-run health, report
   `recovered` or `recovery-failed` with `unrecovered` entries (mutable state
   is never claimed restored) [DEP-06].

Activation failure classes to test: activation script exits non-zero, unit
fails to start (health), network loss after switch (health: CP unreachable →
recover), daemon killed mid-switch (restart recovery: compare
`/run/current-system` with intent journal).

## Drift observation [DEP-03]

Nix evaluation is not drift detection. The node observes the running system
against `shepherdObservations` resources in the plan:

| Observation resource | How observed | Drift when |
|---|---|---|
| `nixos.system-generation` | `readlink /run/current-system` | not equal to target store path |
| `nixos.unit` | `systemctl show <unit> -p ActiveState,UnitFileState` (D-Bus via `go-systemd`) | declared active/enabled differs; unit masked manually |
| `nixos.etc-file` | sha256 of `/etc/<path>` vs store path target; detect replaced symlinks | file modified or symlink replaced |
| `nixos.user` | `getent passwd/group` | declared user/group missing or membership differs (mutableUsers=false recommended) |
| `nixos.firewall-port` | nftables/iptables rule listing | declared allowed port missing / extra Shepherd-chain rule |
| `nixos.imperative-packages` | `nix-env -q` for root and `nix profile list` | packages installed imperatively outside config (reported, not removed in V1) |

Repair = re-run `switch-to-configuration switch` for the current target
(restores etc, units, users declared) — only when auto-fix allows [AGT-04].

## Exclusive management [ADM-03]

Detect and report: `system.autoUpgrade` timers, `nixos-upgrade.service`,
cron/systemd timers running `nixos-rebuild`, other agents (Puppet, Salt,
Ansible pull, Chef, comin, colmena/deploy-rs activation users). The
`shepherd-managed` module disables auto-upgrade; detection catches imperative
changes. Blocking: daemon refuses to apply while a competing manager is
active and reports `blocked: competing-manager`.

## Enrollment image

See [16](16-enrollment-and-removal.md): a custom NixOS installer ISO that
partitions (disko), installs a minimal base with `shepherd-managed`, writes the
enrollment bundle, and on first boot enrolls; the control plane captures
`hardware.nix` from `nixos-generate-config --show-hardware-config` sent in the
enrollment inventory.

## Acceptance

- nixosTest (in `nix flake check`) covering activation success, failing unit →
  recovery to previous generation, drift on `/etc` file detected.
- Lab VM: DEM-01, DEM-02, DEM-06, DEM-07 on NixOS with evidence.
