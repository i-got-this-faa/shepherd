# Node agent

Home for node-local agent workflows using `packages/pi/`.
The node daemon remains a separate process responsible for platform observation
and privileged operations. Their shared messages belong in `packages/contracts/`.

No node-agent implementation exists yet. The automatic-fix toggle permits repair
of drift toward approved configuration only. It grants no new-deployment or
upgrade approval. Current requirements: [SRS](../../docs/scope/SRS.md).
