# 14 — Networking

Shepherd's private network is built on **Tailcat**
(`github.com/tailscale/tailcat`, BSD-3-Clause): Tailscale's data plane
(magicsock, userspace WireGuard, gVisor netstack, DERP) without Tailscale's
control plane. Connection metadata is exchanged out of band — in Shepherd,
the control plane is that out-of-band coordinator [System architecture].

## Tailcat model recap

- A `tailcat.Server` has a node key (`Key key.NodePrivate`) and a WireGuard
  pre-shared key (`PresharedKey`); after `Start()` it publishes a
  `TailcatAddr()` string encoding its key, PSK, and DERP bootstrap region.
  Persisting `Key` and `PresharedKey` keeps the address stable across restarts.
- `AllowClient func(key.NodePublic) bool` is the admission hook; connected
  clients can be dropped with `DisconnectClient(k)`.
- `Server.Listen(ctx, "tcp", ":port")` returns a `net.Listener` inside the tunnel.
- A `tailcat.Client` is created with `NewClient(addr)`, has its own node key
  (`PublicKey()`), and dials ports with `DialTCPPort`/`Dial`.
- DERP region is selected from a DERP map (`DERPMapURL`) or a fixed `Region`.
  Direct UDP paths are upgraded automatically via disco; DERP is the fallback.

## Topology `[impl]`

```text
                    +----------------------------+
                    |  control plane             |
                    |  tailcat.Server (persist)  |  AllowClient = enrolled node keys
                    |  Listen :443 → node.v1     |
                    +-------------^--------------+
                                  | Client (each node)
     +------------------+         |          +------------------+
     | node A           |---------+----------| node B           |
     | tailcat.Client→CP|                    | tailcat.Client→CP|
     | tailcat.Server   |<----- peer --------| (peer client)    |
     |  Listen :7443    |    distribution    | tailcat.Server   |
     +------------------+                    +------------------+
                 \___________ DERP (self-hosted shepherd-derper) _____/
```

- **Node → control plane**: each node runs a `tailcat.Client` to the control
  plane's stable `TailcatAddr` (pinned in the enrollment bundle). The node's
  client key is registered at enrollment; `AllowClient` consults the
  `machine_keys` table (cached, with negative cache). Removal calls
  `DisconnectClient` [ADM-02].
- **Node → node (peers)**: each node also runs its own `tailcat.Server` with a
  persisted key/PSK; it reports its `TailcatAddr` to the control plane at
  enrollment and on change. The control plane pushes a signed `peer-list.v1`
  (peers in the same site/LAN group) to nodes; a node's peer server
  `AllowClient` admits only client keys listed in its current peer list.
- **Identity binding**: the control plane maps the connection's peer key
  (`Server.PeerKey(remoteAddr)`) to a machine id and rejects RPCs whose
  `machine_id` does not match.

## DERP

- Self-hosted relay `shepherd-derper` (wraps `tailscale.com/cmd/derper`) under
  `infra/networking/relays/` on TCP 443 with TLS (ACME or provided cert) and
  STUN on UDP 3478. `--verify-clients` is not usable without Tailscale's
  control plane; restrict via a mesh-key / allow list if supported by the
  pinned revision, otherwise rely on WireGuard encryption and rate limits
  (DERP sees only encrypted packets) — document the decision.
- The control plane serves a DERP map JSON at `https://<public>/derpmap.json`
  containing only Shepherd regions; nodes set `DERPMapURL` or a fixed
  `Region`. The public tailcat.dev relays are **never** used in production
  configuration (allowed only in dev with an explicit flag).

## Bootstrap and external ingress/egress [System architecture]

| Flow | Path | Why not mesh |
|---|---|---|
| Enrollment | HTTPS `enroll` listener | Node has no admitted key yet |
| Browser → console | HTTPS | Admins are not mesh nodes in V1 |
| Central agent → model provider | HTTPS egress from server | External service |
| NanoMDM → APNs, devices → NanoMDM | HTTPS | Apple protocol requirements |
| Node → Attic | Over mesh preferred (CP proxies or Attic reachable at a mesh address via a tailcat listener forwarding to atticd) `[impl]` | Keeps cache private |

## Connectivity modes to test (`tests/transport/`, `networking/tests/`)

1. Same LAN: direct UDP path established; peer transfers direct.
2. NAT'd WAN: hole-punched direct path.
3. UDP blocked (lab "isolated" network): DERP-only; all node.v1 RPCs still work
   (DEM-07 variant); metric `transport=derp`.
4. Control plane restart: nodes reconnect without re-enrollment (stable addr).
5. Node key not admitted: connection never established; server logs denial.
6. Removed node: disconnected within one heartbeat interval.

## Library boundary

`networking/` exposes a small Go API used by both control plane and daemon:

```go
package mesh
type ServerConfig struct { StateDir string; DERP DERPConfig; Allow func(key.NodePublic) bool; Logf ... }
func NewServer(cfg ServerConfig) (*Server, error)   // persists key/PSK, Start, Addr(), Listen, Disconnect, PeerKey
type ClientConfig struct { StateDir string; ServerAddr tailcat.Addr; DERP DERPConfig }
func NewClient(cfg ClientConfig) (*Client, error)   // persists client key, Dial, HTTPClient() for Connect
```

`Client.HTTPClient()` returns an `*http.Client` whose transport dials through
the tunnel so Connect-Go clients work unchanged.

## Acceptance

- Spike (week 1): control plane and a node exchange a Connect RPC over
  Tailcat with a self-hosted derper in docker-compose; persistence of key/PSK
  verified across restart.
- All six connectivity modes pass in the lab; results recorded.
- `AllowClient` rejects an unknown key; removal disconnects.
