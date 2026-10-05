# 20 — Operations and release

## Server deployment

Two supported ways in V1:

1. **docker-compose** (`infra/development/` for dev, `packaging/server/compose/`
   for demo/prod-like): postgres, fbs, atticd, shepherd, shepherd-builder,
   central-agent, web-console, shepherd-derper, nanomdm, reverse proxy (Caddy)
   with TLS.
2. **NixOS module** `nixosModules.shepherd-server` that configures all the above
   as systemd services with state dirs, secrets paths, firewall, backups.

Ports: 443 (console via proxy, enroll, DERP, MDM — separate hostnames or
paths), UDP 3478 (STUN), internal ports bound to localhost/private network.

## Backups

- PostgreSQL: nightly `pg_dump` + WAL archiving optional.
- Config repo: git bundle nightly (also it's the source of truth for desired state).
- FBS: SQLite `.backup` + data dir snapshot; Attic DB (if SQLite/Postgres) dump.
- Secrets dir: offline backup procedure (manual, documented).
- Restore drill documented and executed once in weeks 11–12.

## Observability

- Prometheus scrape config + a Grafana dashboard JSON (optional) in
  `infra/observability/`; alert rules: control plane down, Attic/FBS down,
  deployments failing, nodes stale > threshold, DERP-only ratio spike.

## Packaging

| Artifact | Tooling |
|---|---|
| `shepherd-node` Windows MSI | WiX v4 (or go-msi) in `packaging/windows/` |
| `shepherd-node` macOS pkg | `pkgbuild`/`productbuild` in `packaging/macos/` (signing/notarization if certs available; else documented limitation) |
| NixOS | flake packages/modules |
| Server images | `packaging/server/` Dockerfiles or Nix `dockerTools` |
| ISOs | [16](16-enrollment-and-removal.md) |
| Checksums + signatures | release workflow, `cosign` or minisign |

## Release capability table [Platform limits, Release specifications]

`docs/release/capability-table.md` generated from
`packages/contracts/capabilities.yaml` + recorded evidence: for each platform
× edition × version tested: implemented operations, observed-state checks,
removal behavior, recovery support, known limitations. Only tested
combinations are listed as supported.

## Release evidence (per SRS)

`docs/release/v1-evidence.md`: dependency versions/revisions (Go modules,
pnpm lock, flake.lock, Tailcat revision, FBS revision/digest, Attic revision,
NanoMDM revision, Pi upstream commit), licenses/notices (Tailcat BSD-3,
FBS GPL-3.0 as separate service, Pi MIT, Attic Apache-2.0, NanoMDM MIT),
compatibility tests run, measured deployment/drift/recovery timings in the
lab, DEM evidence links.

## Runbooks (`docs/operations/`)

Install server, rotate plan key, rotate Attic token secret, renew APNs cert,
restore from backup, replace DERP certificate, handle stuck deployment,
recover a node that cannot reach the control plane, remove and re-enroll.

## Acceptance

- Fresh server deployed from compose and from NixOS module in the lab.
- Restore drill completes; machines continue heartbeating.
- Capability table and evidence documents complete for the release tag.
