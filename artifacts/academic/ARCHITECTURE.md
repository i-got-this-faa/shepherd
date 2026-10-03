# Fleet management system architecture

This document specifies the system architecture for the unified Fleet Management System.

---

## 1. System summary

Fleet gives organizations a central control plane to manage computers running Linux, macOS, and Windows. A single Nix Flake defines system state for all three operating systems.

| Platform | Control layer | Filesystem state | Rollback method |
| :--- | :--- | :--- | :--- |
| **Linux** | Native NixOS | `tmpfs` root at `/`, persistent state bound from `/persist` with impermanence, read-only `/nix/store` | Symlink profile switch |
| **macOS** | Embedded NanoMDM + `nix-darwin` | Signed System Volume (SSV) for `/System`, APFS `/nix` synthetic firmlink | Profile switch with `darwin-rebuild activate` |
| **Windows** | Server IR evaluator + `fleetd-windows` (Go) | Standard NTFS with `SYSTEM` access controls, declarative convergence | **Generation re-application**: re-running the generation $N-1$ bundle from `C:\ProgramData\Fleet\generations\` |

---

## 2. Build cache persistence and transfer

### 2.1 Compilation and signing
1. The central build server evaluates the unified Flake for each target machine.
2. Build workers compile packages into immutable store paths (`/nix/store/<hash>-<name>`).
3. Workers compress output archives with Zstandard.
4. An Ed25519 private key signs each `.narinfo` manifest.

### 2.2 Storage tier
* The central binary cache runs **Attic** backed by S3 or MinIO.
* The cache server deduplicates chunk storage using FastCDC.

### 2.3 Network channels, remote laptops, and local transfer
* **Unified Tailcat mesh overlay**: Endpoints run [tailscale/tailcat](https://github.com/tailscale/tailcat) embedded inside `fleetd` using userspace WireGuard and gVisor `netstack`.
  * **Target hashes via Tailcat**: The Fleet server dispatches desired-state hashes and activation triggers directly over the encrypted WireGuard overlay without exposing public ports.
  * **Telemetry via HTTP tunneling**: Live metrics, drift alerts, and heartbeats stream back over HTTP/gRPC tunneling with automatic fallback to HTTPS port 443 DERP relays.
  * **Remote laptop monitoring (WAN)**: Traveling workers on home or hotel Wi-Fi maintain persistent encrypted connections to the central server. If UDP is blocked, Tailcat encapsulates traffic inside HTTPS TLS tunnels through the server's embedded DERP relay.
  * **Local peer transfer (LAN)**: Machines on the same office network discover peers via Tailcat Disco and stream missing store chunks directly from each other over gigabit LAN, eliminating WAN bandwidth bottlenecks.


### 2.4 Windows package distribution
* Core corporate applications are mirrored directly in the central Attic S3 cache.
* Public utilities download from the Microsoft Winget CDN with SHA-256 hash checks pinned in the Flake manifest.

---

## 3. Windows generation engine and rollback

1. **Server-side evaluation**: The central server evaluates `fleet.windows` Nix modules into a typed JSON desired-state document.
2. **Local generation bundles**: The agent writes configurations to `C:\ProgramData\Fleet\generations\<hash>\`.
3. **Reconciliation sequence**:
   * **Registry**: Writes hive keys using Win32 API functions.
   * **Group policy**: Applies policy settings using LGPO `.pol` files.
   * **Packages**: Runs silent installations using Winget and MSIX.
   * **Services**: Configures Windows services and queries hardware state with WMI.
4. **Rollback by re-application**: If health checks fail during activation, `fleetd` re-applies the Generation $N-1$ bundle. Re-applying known-good state is idempotent, does not require restore points, and finishes without a reboot.

---

## 4. Database architecture and scaling

* **Database engine**: PostgreSQL 16.
* **Unified schema**: The server uses one SQL schema for node inventory, policies, and generations.
* **Scaling toggle**:
  * Fleets under 2,000 nodes use native PostgreSQL monthly table partitions.
  * Fleets over 10,000 nodes enable TimescaleDB hypertable compression with a configuration flag.

---

## 5. Dashboard and operational control

* **Web console**: Built with Next.js 15, React 19, and Tailwind CSS.
* **Deterministic alerts**: Prometheus rules detect node faults, update failures, and disconnected agents.
* **Incident summaries**: An LLM reads alert payloads and writes short plain-language root cause explanations.
* **One-click bulk revert**: Administrators review non-compliant nodes in the dashboard and click **Revert Selected** to re-apply the assigned generation.

---

## 6. Document and asset references

* Presentation source: [presentation.marp.md](presentation.marp.md)
* Presentation HTML: [presentation.html](presentation.html)
* Architecture overview diagram: [diagram_topology.svg](assets/diagram_topology.svg)
* Build cache sequence diagram: [diagram_cache_sequence.svg](assets/diagram_cache_sequence.svg)
* Linux workflow diagram: [diagram_linux_workflow.svg](assets/diagram_linux_workflow.svg)
* macOS workflow diagram: [diagram_macos_workflow.svg](assets/diagram_macos_workflow.svg)
* Windows workflow diagram: [diagram_windows_workflow.svg](assets/diagram_windows_workflow.svg)
* Canary deployment diagram: [diagram_canary_rings.svg](assets/diagram_canary_rings.svg)
