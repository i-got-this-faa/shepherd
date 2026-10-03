# Mesh transport

The internal control and data propagation backbone: Tailcat, WireGuard,
userspace netstack, node identity, discovery, connectivity, access policy,
transport, and DERP client/server integration. All internal callers share this
network contract. No networking implementation has been imported yet.

Direct LAN/WAN paths and restricted-network DERP fallback have separate test
homes under `tests/transport/`. Relay and bootstrap deployment configuration
belongs under `infra/networking/`; artifact fetching and peer chunk delivery
belong under `packages/distribution/`. Enrollment bootstrap and external APNs,
browser, and model-provider connections require explicit ingress/egress rules.
