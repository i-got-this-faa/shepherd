# Shepherd control plane

Home for the central server. The presentation proposes Go; the scope knowledge
does not record that stack choice as accepted. It owns:

- enrollment, host identity, roles, and Flake targets
- Nix evaluation into Linux, macOS, and typed Windows target states
- target-hash dispatch over outbound mTLS gRPC
- inventory, generations, heartbeats, and drift history in PostgreSQL
- embedded Tailcat DERP fallback on HTTPS port 443
- embedded NanoMDM integration for APNs, FileVault escrow, and TCC profiles
- rollout rings, approvals, promotion, rollback, and audit logging

Build output belongs to the build worker and Attic. Endpoint mutation belongs
to the node daemon. AI drafting belongs to the central agent runner. Keeping
those boundaries separate prevents a model response from becoming an unsigned
deployment path.

No control-plane code exists yet. This directory records the server's ownership
before implementation begins.
