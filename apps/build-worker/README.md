# Shepherd build worker

Build workers receive pinned Flake targets from the control plane, evaluate and
compile derivations in a sandbox, and publish signed NARs to Attic. They return
the closure hash and build evidence. They do not choose rollout targets.
