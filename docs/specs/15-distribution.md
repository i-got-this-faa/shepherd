# 15 — Distribution

`packages/distribution/` (Go). Moves artifacts from Attic to nodes, using
peers on the same site to save WAN bandwidth, without changing artifact
identity or trust [DEP-01].

## Artifact kinds

| Kind | Identity | Verification |
|---|---|---|
| Nix store paths (NixOS/Darwin) | store path + NAR hash | Nix signature (Attic cache key) + narHash of closure root from signed plan |
| Windows files (daemon MSI/zip, package manifests, policy templates) | sha256 | sha256 in signed plan |

## Fetch order

1. Local cache (`cache/`).
2. Peers from the current signed `peer-list.v1`, ranked by RTT and
   advertised availability.
3. Attic (for Nix paths) or the control plane artifact endpoint (for files).

## Peer protocol

- Each node's peer server (Tailcat listener `:7443`, see [14](14-networking.md))
  serves:
  - **Nix binary cache protocol** read-only for paths it has in its local
    store (`/nix-cache-info`, `/<hash>.narinfo`, `/nar/<file>`), so NixOS
    peers can simply be listed as substituters → reuses Nix's own
    verification. Implemented with a small handler that streams `nix-store
    --dump`/`nix store dump-path` output, serving narinfo generated from
    `nix path-info --json` **including the original Attic signatures** (never
    re-signing).
  - **File chunks** for Windows artifacts: `GET /v1/files/<sha256>` with HTTP
    Range support; manifest `GET /v1/files/<sha256>/manifest` lists 4 MiB chunk
    hashes so a receiver can pull chunks from several peers in parallel and
    verify each chunk.
- Local substituter proxy: on NixOS/Darwin the daemon runs
  `http://127.0.0.1:37515` that fans out to peers then Attic; Nix uses it as the
  first substituter. This keeps Nix configuration static.
- A peer serves only artifacts referenced by the requesting node's plan?
  V1: peers serve anything in their cache to admitted peers in the same peer
  list (all are Shepherd-managed and admitted); sensitive artifacts do not
  exist in V1 because secrets are not distributed. Documented in threat model.

## Integrity rules

- Every chunk verified against manifest hash; manifest verified against the
  sha256 in the signed plan; Nix paths verified by Nix signatures and the root
  narHash. A peer serving bad data is marked bad for 1 h and reported.
- Peer delivery is a transport optimization only; a fetch failure from peers
  falls back to Attic transparently.

## Metrics

Bytes from peers vs Attic per deployment, per-node fetch time, bad-peer
events; exposed in reports (`fetch: {fromPeers, fromCache, durationMs}`) and
aggregated in the console deployment view.

## Acceptance

- Three NixOS VMs on one LAN: first fetches from Attic, the other two fetch
  ≥90 % bytes from peers (measured), all verify.
- Tampered peer (test hook that flips bytes) → verification fails, falls back,
  peer marked bad.
- Windows: daemon update artifact delivered from a peer with chunk
  verification.
