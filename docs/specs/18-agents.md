# 18 — Agents

## Pi fork (`packages/pi/`)

Upstream: `github.com/badlogic/pi-mono`. Import only what Shepherd needs:

- `packages/pi/ai` ← upstream `packages/ai` (unified LLM API). Keep the
  OpenAI-compatible provider (chat completions + tool calls + streaming);
  other providers may stay but are untested/unsupported in V1 [AGT-02].
- `packages/pi/agent` ← upstream `packages/agent` (agent loop, tool
  execution, session state). Remove TUI/coding-agent CLI, file-system and
  shell tools.
- Record upstream commit, retained paths, license (MIT) notices, local patches
  in `packages/pi/UPSTREAM.md`; `tools/upstream/pi-sync.sh` re-applies patches
  on a new upstream revision.
- Tests in `tests/pi/`: tool call round trip, streaming, error on provider
  outage, max-turns and token budget enforcement, against a mock
  OpenAI-compatible server (recorded fixtures) and one real provider smoke test
  behind an env flag.

## Central agent (`apps/central-agent/`)

Node.js service exposing `shepherd.agent.v1.CentralAgentService` to the
control plane only. The control plane is the **tool host**: the agent calls
tools via `ToolHostService`, and every tool call is authorized and recorded by
the Go side (`agent_tool_calls`).

Tools (all read-only unless stated):

| Tool | Returns / does |
|---|---|
| `fleet.summary` | counts, failing deployments, open drift |
| `machines.search(query)` / `machines.get(id)` | inventory, status, effective profile |
| `reports.get(machineId, kind, limit)` | recent reports (redacted) |
| `drift.list(filter)` | findings |
| `deployments.get(id)` | rollout state and failures |
| `profiles.get(id)` / `config.read(profileId, path)` | GUI model and custom modules (read) |
| `catalog.search(name)` | package catalog entries |
| `capabilities.matrix(platform)` | supported/unsupported settings |
| `drafts.create(profileId, guiModelPatch?, customModuleFiles?, rationale)` | **write**: creates a draft (state editing → evaluation runs). Never approves [AGT-03/05] |
| `nixpkgs.search(name)` | searches pinned nixpkgs index (server-side precomputed) for package drafts |

Workflows (`src/workflows/`): `explain-failure` (deployment or machine),
`explain-drift`, `propose-equivalent` for omitted settings [CFG-06, DEM-05],
`draft-package` (create a package entry/derivation draft), `fleet-qna`.

Prompt hygiene: machine-reported strings are wrapped as data in tool results;
system prompt states the authority limits; outputs are rendered as text.

Config: `AGENT_BASE_URL`, `AGENT_MODEL`, `AGENT_API_KEY` (from server secrets),
timeouts, max tokens. Disabled when unset → console shows AI off [AGT-01].

## Node agent (`apps/node-agent/`)

Short-lived Node.js process started by `shepherd-node` (`agentrunner`) on
demand (console request for machine-local analysis, or after a failed apply
when enabled). Runs as an unprivileged user (Windows: virtual service account
`NT SERVICE\shepherd-agent`; Linux/macOS: `_shepherd-agent`).

- Talks only to the daemon IPC ([10](10-node-daemon.md#local-ipc-for-node-agent-agt-06))
  and to the model endpoint through the control plane's model proxy
  (`AgentService.ProxyCompletion`) so nodes do not hold model API keys
  `[impl]`.
- Tools: `node.status`, `node.reports`, `node.drift`, `node.inventory`,
  `node.logs(redacted, tail)`, `node.requestRepair(resourceKeys, reason)`.
- `requestRepair` → daemon → `NodeService.RequestRepair` → server checks
  auto-fix + approved generation → signed `Reapply` or denial [AGT-04/06].
- Output (explanation) is uploaded as an `agent_sessions` record viewable in
  the machine page.

## Authority summary [AGT-01..06]

| Action | Admin | Central agent | Node agent | Daemon (auto-fix) |
|---|---|---|---|---|
| Read fleet state | ✅ | ✅ (tools) | own machine only | own machine |
| Create draft | ✅ | ✅ | ❌ | ❌ |
| Approve / deploy | ✅ | ❌ | ❌ | ❌ |
| Reapply approved generation | ✅ | ❌ | request only | ✅ if auto-fix on |
| Change auto-fix toggle | ✅ | ❌ | ❌ | ❌ |
| Hold keys / run shell | ❌ | ❌ | ❌ | provider-scoped only |

## Acceptance

- DEM-05: agent proposes an equivalent for an unsupported setting as a draft;
  approval still required; omitted setting not reported as enforced.
- Agent explains a failed deployment using real report data (recorded session).
- With AI disabled, DEM-01..04 still pass.
- Authorization tests: agent principal calling Approve/Deploy APIs → denied +
  audit event.
