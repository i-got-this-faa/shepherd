# Contracts

This package will own versioned data that crosses a process or network boundary.
The first contracts should cover:

- device enrollment and identity
- Flake target assignment and evaluated target hashes
- capability reports
- performance observations
- health assessments and evidence
- signed execution plans
- per-resource execution results
- NAR and peer-chunk manifests
- heartbeats, telemetry, and drift events
- rollout ring state and promotion decisions
- MDM command and acknowledgement metadata
- agent task assignments
- model-update metadata for federated learning
- audit and lifecycle reports

The current Windows plan and report shapes are documented in
[plan-schema.md](../../docs/platforms/windows/plan-schema.md). Move them here as
machine-readable schemas when the control plane starts consuming them. Keep the
existing major-version rejection rule.
