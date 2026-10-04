# 16 — Enrollment and removal

## Enrollment bundle

A JSON document (`enrollment-bundle.v1`) embedded in install media or passed to
`shepherd-node enroll --bundle`:

```json
{ "bundleVersion": 1, "server": { "enrollUrl": "https://shepherd.example/enroll",
  "tlsPin": "sha256/<spki>", "tailcatAddr": "tc...", "derpMapUrl": "https://.../derpmap.json" },
  "token": "<enrollment token>", "trust": { "planKeys": [ { "kid": "...", "pub": "..." } ],
  "atticCacheKey": "shepherd:..." }, "initialGroupId": "uuid|null" }
```

The token is the only secret; bundles expire with the token [ADM-04].

## Enroll protocol (`shepherd.enroll.v1.Enroll`)

1. Node generates identity key (Ed25519), Tailcat client key, and its own peer
   server key/PSK; collects inventory + capabilities + detected managers.
2. Calls `Enroll{token, identity_pub, tailcat_client_pub, peer_tailcat_addr,
   inventory, hardware_nix?}` over HTTPS with TLS pin check.
3. Server validates token (hash match, not expired/revoked, uses < max),
   creates `machines` + `machine_keys`, increments uses, adds to initial group,
   records audit, returns `{machine_id, key_set (signed), attic pull token,
   heartbeat interval}`.
4. Node persists identity, starts mesh client; control plane `AllowClient`
   now admits it.
5. If competing managers are detected, machine status is `blocked:
   competing-manager` and no target is dispatched until the admin resolves
   it in the console (mark resolved after removal, or remove machine) [ADM-03].

## Windows ISO [ADM-01]

`infra/enrollment/windows/`:

- Inputs: official Windows 11 ISO (admin supplies; never redistributed),
  enrollment bundle, `shepherd-node` MSI.
- Build script (`build-iso.sh` using `xorriso`/`wimlib` on Linux, or
  PowerShell + oscdimg on Windows) injects `autounattend.xml` +
  `$OEM$\$1\Shepherd\` payload: MSI + bundle. `SetupComplete.cmd` or
  `FirstLogonCommands` runs `msiexec /i shepherd-node.msi BUNDLE=...` which
  installs the service and runs enroll.
- Unattend: edition selection (Pro/Enterprise key or generic KMS key per
  admin input), local admin account policy, disk layout (wipe disk 0 — loud
  warning in docs), OOBE skip, region/time zone.
- MSI built with WiX v4 (or `go-msi`) in release workflow; service install,
  ACLs on state dir, uninstall removes service and state (machine state left).
- Also: an "existing machine" path — run the MSI with a bundle on an already
  installed Windows (needed for lab speed); same enroll protocol.

## NixOS ISO [ADM-01]

`infra/enrollment/nixos/`: a flake output `nixosConfigurations.installer`
building an ISO (`installation-cd-minimal` base) containing the bundle and an
unattended installer service:

1. disko layout (configurable; default single disk GPT + ESP + ext4 root,
   optional LUKS without unattended key in V1).
2. `nixos-generate-config --show-hardware-config` → captured.
3. Install a minimal base system with `shepherd-managed` module and the bundle
   in `/var/lib/shepherd/bundle.json`.
4. Reboot → `shepherd-node enroll` → control plane stores `hardware.nix` into
   `hosts/<machine-id>/` in the config repo → first target dispatched when a
   profile applies.

## macOS

MDM profile + pkg flow per [13](13-macos-backend.md). No custom ISO [ADM-01].

## Competing manager detection [ADM-03]

| Platform | Detected | Evidence |
|---|---|---|
| Windows | Intune/MDM enrollment, SCCM/ConfigMgr client, domain-joined GPO overlap on managed keys, Ansible/Chef/Puppet/Salt services, other RMM agents (list maintained in `packages/configuration/managers.yaml`) | registry enrollments, services, `dsregcmd` |
| NixOS | auto-upgrade timers, comin, deploy-rs/colmena markers, puppet/salt/chef services | systemd units |
| macOS | Other MDM enrollment (`profiles status -type enrollment`), Jamf/Munki/Kandji agents | profiles, launchd |

Detection runs at enrollment and every drift pass. Domain GPO overlap is a
per-resource `blocked` not a machine block.

## Removal [ADM-02, DEM-08]

Console action "Remove machine" (typed confirmation):

1. Server: mark `removed`, revoke keys, Attic token, delete `machine_targets`,
   cancel instructions, disconnect Tailcat client, remove from peer lists,
   audit event.
2. If online: send signed `Unenroll` instruction first; node stops applying,
   uploads journal summary, deletes identity, stops service (optionally
   uninstalls itself on Windows via scheduled uninstall).
3. Machine state remains as-is; no reinstall/restore promise (console text says so).
4. Any later heartbeat → `PERMISSION_DENIED`; no plan can be signed for a
   removed id (enforced in signer).
5. Re-enrollment requires a new token and creates a new machine id.

## Acceptance

- Windows VM enrolled from ISO end-to-end with no manual steps after boot.
- NixOS VM enrolled from ISO; `hardware.nix` committed to config repo.
- Expired/revoked/overused tokens rejected (tests).
- Intune-like detection fixture blocks dispatch until resolved.
- DEM-08 passes with evidence.
