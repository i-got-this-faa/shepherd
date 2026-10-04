# Central agent runner

Home for central agent workflows using the shared stripped-down Pi fork in
`packages/pi/`. Fleet coordination remains in `apps/control-plane/`.
Node-local workflows belong in `apps/node-agent/`.

No runner implementation exists yet. Agents inspect state, explain failures and
prepare drafts. The automatic-fix toggle authorizes endpoint drift repair only;
new configurations and upgrades retain approval requirements.
Current requirements: [SRS](../../docs/scope/SRS.md).
