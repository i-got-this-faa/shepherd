# 18 — Agents

## Pi fork (`packages/pi/`)

Upstream: `github.com/earendil-works/pi` (formerly `badlogic/pi-mono`),
pinned to release tag `v1.0.3` (`d78dc83d`). The file manifest, patches, and
evidence are in the [Pi fork spike](../spikes/pi-fork.md). Import only what
Shepherd needs:

- `packages/pi/ai` (`@shepherd/pi-ai`) ← upstream `packages/ai` (unified LLM
  API), trimmed to the import closure of the core entry point plus five wire
  APIs [AGT-02]:
  - `openai-completions`: OpenAI-compatible Chat Completions. Required; fully
    tested.
  - `anthropic-messages`, `bedrock-converse-stream`, `google-generative-ai`,
    `google-vertex`: native providers. Smoke-tested.

  Not imported: provider factories, the generated model catalog, subscription
  OAuth logins (`auth/oauth/*`; interactive and CLI-only), image and
  classifier APIs, and the `pi-ai` CLI.
- `packages/pi/agent` (`@shepherd/pi-agent`) ← upstream `packages/agent`
  (agent loop, tool execution, session state), imported whole. It contains no
  TUI, file-system, or shell tools. Those live in upstream `coding-agent`,
  which is excluded along with `tui` and the other upstream packages.
  Shepherd's node diagnostic tools ([below](#node-agent-appsnode-agent)) are
  Shepherd tools backed by daemon IPC, not upstream's local `bash`/`read`
  tools.
- Record upstream tag and commit, retained paths, license (MIT) notices, and
  local patches in `packages/pi/UPSTREAM.md`. The file manifest goes in
  `packages/pi/upstream-files.txt` and patches in `packages/pi/patches/`.
  `tools/upstream/pi-sync.sh <tag>` re-copies the manifest, checks the import
  closure, and re-applies the patches on a new upstream release tag.
- Shepherd behavior belongs in the runners, not in fork patches. Enforce max
  turns and token budget through the agent's `finishTurn` / `prepareRequest`
  hooks.
- Tests in `tests/pi/`:
  - Against a mock OpenAI-compatible server (recorded fixtures): tool call
    round trip, streaming, error on provider outage, max-turns and token
    budget enforcement.
  - Behind env flags: one real-provider smoke test each for OpenAI-compatible,
    Anthropic, Bedrock, Google, and Vertex.

## Model providers [AGT-02]

| `AGENT_PROVIDER` | Pi API | Credentials (server secrets) | V1 support |
|---|---|---|---|
| `openai-compatible` (default) | `openai-completions` | `AGENT_API_KEY`; `AGENT_BASE_URL`; optional `AGENT_COMPAT` | Supported: full `tests/pi` suite |
| `anthropic` | `anthropic-messages` | `AGENT_API_KEY` (Anthropic API key) | Smoke-tested |
| `bedrock` | `bedrock-converse-stream` | AWS credential chain: instance or IAM role, `AWS_PROFILE`, or access keys; `AGENT_AWS_REGION` | Smoke-tested |
| `google` | `google-generative-ai` | `AGENT_API_KEY` (Gemini API key) | Smoke-tested |
| `vertex` | `google-vertex` | Service-account JSON path; `AGENT_GCP_PROJECT`, `AGENT_GCP_LOCATION` | Smoke-tested |

- Common settings: `AGENT_MODEL`, timeouts, max tokens, max turns, and token
  budget. AI is disabled when the provider is unset or unconfigured, and the
  console then shows AI off [AGT-01].
- The runner builds a single Pi `Model` from config, with no catalog lookup.
  It passes credentials per request, never through the process environment,
  and sets `User-Agent: shepherd-agent/<version>`.
- `AGENT_COMPAT` (optional JSON) overrides Pi's `OpenAICompletionsCompat`
  flags. Pi treats an unrecognized base URL as real OpenAI (`developer` role,
  `store`, `max_completion_tokens`), and self-hosted endpoints (vLLM, Ollama,
  LiteLLM) often need these off. The AGT-02 provider test records which
  compat set passed.
- Personal subscription logins (Claude Pro/Max, ChatGPT, Copilot) are not
  supported. They need an interactive browser login, tie a team service to one
  person's account, and are generally outside those providers' terms for
  third-party products.
- Only the central agent service holds model credentials. Node agents reach
  the model through the [model proxy](#model-proxy-for-node-agents), so
  provider SDKs and keys never ship to endpoints.

## Central agent (`apps/central-agent/`)

Bun service exposing `shepherd.agent.v1.CentralAgentService` to the
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
| `findings.list(filter)` / `findings.get(id)` | node agent findings with evidence (machine-reported data) [AGT-08] |
| `node.investigate(machineId, question)` | **write**: asks the control plane to start a node agent on that machine (`RunAgent` instruction); the result arrives as a finding [AGT-07/08] |
| `escalations.create(findingIds, summary, recommendation)` | **write**: opens an escalation for administrators. The recommendation can be an explanation, a draft reference, a repair request, or a remediation proposal [AGT-08] |
| `remediation.propose(machineIds, steps, rationale, risk)` | **write**: creates a remediation proposal in state `proposed`. Never approves or dispatches [AGT-08] |

Workflows (`src/workflows/`):

- `explain-failure` (deployment or machine) and `explain-drift`.
- `propose-equivalent` for omitted settings [CFG-06, DEM-05].
- `draft-package` (create a package entry or derivation draft).
- `fleet-qna`.
- `triage-finding` [AGT-08], described in
  [Findings and escalation](#findings-and-escalation-agt-08).

Prompt hygiene:

- Machine-reported strings are wrapped as data in tool results. This includes
  node findings, probe output, and logs.
- The system prompt states the authority limits.
- Outputs are rendered as text.

## Node agent (`apps/node-agent/`)

A short-lived Bun process that `shepherd-node` (`agentrunner`) starts on
demand. Triggers:

- an admin request from the console
- the central agent's `node.investigate`, delivered as a `RunAgent`
  instruction
- a failed apply, when that option is enabled

It runs as an unprivileged user (Windows: virtual service account
`NT SERVICE\shepherd-agent`; Linux/macOS: `_shepherd-agent`). It has no
privileges of its own. **Everything privileged is executed by the daemon** and
requested over IPC [AGT-06/07].

- Talks only to the daemon IPC
  ([10](10-node-daemon.md#local-ipc-for-node-agent-agt-06)). Model calls are
  relayed by the daemon to the [model proxy](#model-proxy-for-node-agents), so
  nodes hold no model keys.
- Every tool call and its redacted output is recorded in the agent session
  (`agent_sessions` / `agent_tool_calls`) and is viewable on the machine page.

### Diagnosis tiers [AGT-07]

| Tier | Tool | Executed by | Guardrail | Approval |
|---|---|---|---|---|
| 1. Probes | `node.probe(probeId, args)` and `node.probes()` (catalog listing) | Daemon as root/SYSTEM, `internal/diag/probes` | Typed catalog; arguments validated per probe; output redacted and capped at 64 KiB | None |
| 2. Read-only shell | `node.shell(command, timeoutSec ≤ 60)` | Daemon, inside a read-only sandbox (`internal/diag/sandbox`) | The sandbox physically cannot write system state, reach the network, or read secrets | None |
| 3. Remediation | `node.proposeRemediation(steps, rationale, risk)` | Nothing at proposal time. The daemon runs the steps later, only from a signed `remediation.v1` instruction | Admin approves the exact steps per machine; signed, single-use, expires in 15 minutes or less | **Admin, per proposal** |

The node agent also keeps these existing tools:

- `node.status`, `node.reports`, `node.drift`, `node.inventory`
- `node.requestRepair(resourceKeys, reason)`: daemon → `NodeService.RequestRepair`
  → the server checks auto-fix and the approved generation → signed `Reapply`
  or denial [AGT-04/06]

The session ends with `node.submitFinding(finding)`.

**Tier 1 probe catalog (V1 minimum).** Each probe is a Go function per
platform. None spawns a shell:

| Area | Probes |
|---|---|
| Logs | `logs.journal(unit?, since, grep?)` (Linux), `logs.eventlog(channel, ids?, since)` (Windows), `logs.unified(predicate, since)` (macOS), `logs.file(path)` (allowlisted log roots) |
| Services | `services.list`, `services.status(name)`, `services.failed` |
| Processes | `processes.list(sort, limit)`, `processes.get(pid)` (cmdline redacted) |
| System | `system.info`, `system.uptime`, `system.load`, `memory.usage`, `disk.usage`, `disk.smart` (when available), `kernel.dmesg(since)` (Linux) |
| Network | `net.interfaces`, `net.routes`, `net.listeners`, `net.connections(limit)`, `net.dns.resolve(name)`, `net.reach(host, port)` (TCP connect only, to a control-plane-supplied allowlist), `net.mesh.status` (Tailcat) |
| Packages | `packages.list(filter)`, `packages.version(name)`, `nix.generations`, `nix.store.verify(path)` (NixOS/macOS), `winget.list` / `msi.products` (Windows) |
| Config | `file.read(path)` (allowlisted roots such as `/etc` and `C:\ProgramData`; secret paths denied), `registry.read(key)` (Windows; denylisted secret hives), `defaults.read(domain)` (macOS) |
| Updates | `updates.status` (Windows Update, `nixos-version`, `softwareupdate --list` via API) |
| Shepherd | `shepherd.journal(tail)`, `shepherd.lastPlan`, `shepherd.daemonLog(tail)` |

Windows and NixOS probes are P0 (#257). macOS probes are P1 (#263): if
they are cut from V1, macOS agents fall back to the existing `node.*` tools
and Tier 3.

**Tier 2 read-only sandbox.** The daemon runs the command and returns
stdout/stderr (redacted, 64 KiB cap) plus the exit code:

- **Linux (NixOS and others):** a transient unit via
  `systemd-run --wait --pipe --collect` with:
  - `User=_shepherd-diag` with `AmbientCapabilities=CAP_DAC_READ_SEARCH` (can
    read any file; can't write root-owned files)
  - `ProtectSystem=strict`, `ProtectHome=read-only`, `ReadOnlyPaths=/`,
    `PrivateTmp=yes`
  - `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`,
    `ProtectControlGroups=yes`, `NoNewPrivileges=yes`
  - `InaccessiblePaths=` the Shepherd state and secrets directories, SSH host
    keys, and `/etc/shadow`
  - `IPAddressDeny=any`, `RestrictAddressFamilies=AF_UNIX AF_NETLINK` (host
    network state is visible through netlink, but no packets leave)
  - `RuntimeMaxSec=60`, `MemoryMax=256M`, `CPUQuota=50%`

  Systemd and polkit deny mutating D-Bus calls from this user.
- **Windows:** a JEA endpoint `ShepherdDiag` (`NoLanguage` mode,
  `RunAsVirtualAccount`). The role capability allowlists read-only cmdlets
  (`Get-*` diagnostics, `Get-WinEvent`, `Get-Service`, `Get-Process`,
  `Get-NetIPConfiguration`, `Get-ItemProperty`, `Test-NetConnection`
  restricted to allowlisted hosts, …), with `ValidatePattern` /
  `ValidateSet` on paths and keys. `node.shell` takes a pipeline of
  allowlisted cmdlets, not arbitrary PowerShell. This is P1 (#264): if it
  is cut from V1, Windows uses Tier 1 and Tier 3 like macOS.
- **macOS:** no Tier 2 in V1. There is no supported sandbox
  (`sandbox-exec` is deprecated), so macOS uses Tier 1 and Tier 3.

**Tier 3 remediation.** The agent proposes; it never runs.

- `steps` is an ordered list of
  `{ shell: "sh" | "powershell", argv[] | script, runAs: "root" | "system", timeoutSec }`.
- The steps become a `remediation_proposal`. The flow after that is in
  [Remediation commands](#remediation-commands-agt-08).

### Findings and escalation [AGT-08]

1. **Node agent → control plane.** The session ends with a structured
   finding:

   ```json
   { "machineId": "…", "sessionId": "…", "summary": "…",
     "symptoms": ["…"], "suspectedCause": "…", "confidence": "low|medium|high",
     "evidence": [ { "toolCallId": "…", "excerpt": "…(redacted)", "outputDigest": "sha256:…" } ],
     "recommendations": [ { "kind": "none|repair|remediation|config-change|human",
                            "detail": "…", "remediationProposalId": "…?" } ] }
   ```

   The path is daemon IPC `SubmitFinding` → `NodeService.SubmitAgentFinding`
   → `agent_findings`. Evidence excerpts must reference the session's
   recorded tool calls; the control plane rejects unknown references.
2. **Control plane → central agent.** When AI is enabled, a new finding
   triggers `CentralAgentService.TriageFinding`. The `triage-finding` workflow:
   - reads the finding as untrusted data
   - looks for the same symptom on other machines
     (`findings.list`, `reports.get`, `drift.list`)
   - may run more investigations (`node.investigate`)
   - then picks **one** outcome:
     - close as explained
     - create a draft, if the root cause is configuration (normal approval
       path)
     - file a repair request (auto-fix rules apply)
     - open a remediation proposal
     - escalate as "needs human investigation"

   Every outcome other than "close" creates an escalation.
3. **Central agent → humans.** Escalations appear in the console inbox
   ([17](17-web-console.md)) and show:
   - the central agent's summary and the correlated machines
   - the raw finding evidence, next to the summary, never replaced by it
   - links to the sessions
   - any draft or remediation awaiting approval

   With AI disabled, admins can still read node findings that were recorded
   earlier, and every manual operation still works [AGT-01].

### Remediation commands [AGT-08]

- **States:** `proposed → approved | rejected → dispatched → succeeded |
  failed | expired`. One proposal lists explicit machine ids and exact steps.
- **Approval.** Only an admin can approve, through the console API. Approval
  is recorded in `remediation_proposals.approved_by` (admins only) and the
  audit log. Agent principals get `PERMISSION_DENIED` plus an audit event. The
  approve screen shows:
  - every step verbatim
  - the target machines
  - the evidence
  - a warning when a step touches a resource managed by the approved
    configuration: auto-fix may revert it, so a lasting fix needs a draft
- **Signing.** For each machine, the control plane signs a `remediation.v1`
  DSSE envelope ([03](03-security-and-trust.md)) containing:
  - `machineId`, `proposalId`, `nonce`
  - the steps
  - `createdAt` and `expiresAt` (15 minutes or less)

  It is delivered as a `RunRemediation` heartbeat instruction.
- **Execution.** The daemon verifies the envelope, rejects reused nonces, runs
  the steps as root/SYSTEM (stopping at the first failure), journals them, and
  submits a `remediation` report with redacted output and exit codes. The
  daemon never runs remediation that arrives over IPC.
- A remediation is not a configuration change. It grants no deployment
  authority, and the next drift pass reports any managed resource it changed
  [AGT-04/05].

### Model proxy for node agents

The path is: node agent → daemon IPC `ProxyCompletion` → (machine identity,
Tailcat) → `NodeAgentService.ProxyCompletion` on the control plane → the
control plane authorizes the session and records it → the central agent
service runs Pi `streamSimple` with the configured provider → events stream
back.

- The stream uses Pi's `ProxyAssistantMessageEvent` shape; see `proxy.ts` in
  the fork.
- The node agent's Pi `StreamFn` is modeled on `proxy.ts`.
- This works the same for every provider. Endpoints carry no provider SDKs or
  credentials.
- Rate limits and token budgets are enforced per machine and per session on
  the control plane.

## Authority summary [AGT-01..08]

| Action | Admin | Central agent | Node agent | Daemon |
|---|---|---|---|---|
| Read fleet state | ✅ | ✅ (tools) | own machine only | own machine |
| Privileged read of a machine (probes, read-only sandbox) | via console session view | via `node.investigate` only | ✅ own machine, executed by daemon | executes |
| Create draft | ✅ | ✅ | ❌ | ❌ |
| Approve / deploy | ✅ | ❌ | ❌ | ❌ |
| Reapply approved generation | ✅ | ❌ | request only | ✅ if auto-fix on |
| Change auto-fix toggle | ✅ | ❌ | ❌ | ❌ |
| Submit finding / escalate | — | escalates to admins | submits to central | relays |
| Propose remediation command | ✅ | ✅ | ✅ | ❌ |
| Approve remediation command | ✅ | ❌ | ❌ | ❌ |
| Run remediation command | ❌ | ❌ | ❌ | ✅ signed + unexpired only |
| Hold keys / unrestricted shell | ❌ | ❌ | ❌ | provider-scoped + signed remediation only |

## Acceptance

- DEM-05: agent proposes an equivalent for an unsupported setting as a draft;
  approval still required; omitted setting not reported as enforced.
- Agent explains a failed deployment using real report data (recorded session).
- With AI disabled, DEM-01..04 still pass.
- Authorization tests: an agent principal calling Approve/Deploy or
  ApproveRemediation is denied and an audit event is written.
- Diagnosis (VM evidence, Linux and Windows): a node agent finds the cause of
  a stopped service using probes. On Linux, attempts to write a file or reach
  the network from `node.shell` fail. A secret path read through `file.read`
  or `node.shell` is denied.
- Escalation: a node finding reaches the central agent. Triage opens an
  escalation with a remediation proposal. The step does not run until an admin
  approves it. An expired or replayed `remediation.v1` envelope is rejected by
  the daemon. The result report is visible on the machine page.
- Providers: `tests/pi` passes for OpenAI-compatible. Smoke tests pass for
  every provider whose credentials are configured in CI.
