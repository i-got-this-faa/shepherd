# Shepherd web console

The console owns operator views for enrollment, inventory, active generations,
drift, telemetry, rollout rings, AI explanations, proposed Flake diffs, and
one-click re-application of the assigned generation.

Operator approval flows call the Go control plane. The browser never holds
artifact-signing keys or endpoint credentials.
