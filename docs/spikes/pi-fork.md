# Spike: Pi fork import plan

| | |
|---|---|
| Issue | #53 (`T18.00`), unblocks #189 |
| Spec | [18 — Agents](../specs/18-agents.md) (§ Pi fork, Model providers, Node agent) |
| SRS | AGT-02, AGT-06..08 |
| Date | 2026-10-05 (revised 2026-10-06 after scope review) |
| Decision | **Go.** Fork 61 files of `packages/ai` (OpenAI-compatible plus Anthropic, Bedrock, Google, and Vertex) and all 6 files of `packages/agent`, with one 4-line patch. Do not import subscription OAuth, Pi's coding tools, or the TUI. |

## Scope decisions (reviewed with the team)

| Question | Decision | Why |
|---|---|---|
| Providers | Keep `openai-completions` (required, fully tested) plus the native `anthropic-messages`, `bedrock-converse-stream`, `google-generative-ai`, and `google-vertex` (smoke-tested). | Native APIs give prompt caching, thinking, and accurate usage. Each one is lazily imported, and keeping them *shrinks* the patch queue (see [Local patches](#local-patches)). |
| OAuth | Do not import `auth/oauth/*`. Use server-held API keys and cloud credentials: AWS credential chain for Bedrock, a service account for Vertex. | Pi's OAuth is personal subscription login (Claude Pro/Max, ChatGPT, Copilot). It runs a browser flow with a localhost callback server, and the code says *"only intended for CLI use"*. That doesn't work for a headless team service, depends on one person's account, and is generally outside the providers' terms for third-party products. |
| Tools | Keep the agent's tool *machinery*. Do not import Pi's local `bash` / `read` / `write` / `edit` tools. Node agents diagnose through **daemon-executed** tools in three tiers: typed probes, a read-only sandbox shell, and admin-approved remediation. Findings go to the central agent, which escalates to humans. | An agent reading logs that anyone can write to must not hold a writable root shell: prompt injection would become fleet-wide root code execution. Diagnosis needs privileged *reads*; changes stay behind human approval. These are now SRS AGT-07/08 and are specified in [18](../specs/18-agents.md#diagnosis-tiers-agt-07). |
| TUI / coding-agent CLI | Do not import. | Shepherd is headless. |

## Pinned upstream

| Field | Value |
|---|---|
| Repository | <https://github.com/earendil-works/pi>. `github.com/badlogic/pi-mono` now redirects here; the packages were renamed from `@mariozechner/*` to `@earendil-works/*`. |
| Revision | tag `v1.0.3`, commit `d78dc83d633229d12f8b79631384c4c2717c399f` (2026-10-05) |
| Packages | `@earendil-works/pi-ai@1.0.3` (`packages/ai`), `@earendil-works/pi-agent-core@1.0.3` (`packages/agent`) |
| License | MIT, `Copyright (c) 2025 Mario Zechner`. The repository has one root `LICENSE`. The retained files have no per-file headers and no third-party notices. |
| Runtime | `engines.node >= 22.19.0`. The `.nvmrc` from #23/#254 (`22`) must resolve to 22.19 or later. |

Pin release tags only, never `main`. Upstream moves fast: `packages/ai` and
`packages/agent` received 189 commits in the 30 days before the pin, and 29 of
them touched the core files we keep.

## What upstream contains

The monorepo has 13 packages: `agent ai chord client codemode coding-agent
durable env evals mcp protocol server telemetry tui`.

- `packages/agent` (6 source files, 2,513 LOC) is already headless. It
  contains the agent loop, the stateful `Agent`, tool execution with schema
  validation, steering and follow-up queues, and an HTTP proxy stream
  function. **It has no TUI, CLI, file-system, or shell tools.** Those live in
  `packages/coding-agent`.
- `packages/ai` (≈230 source files, 77k LOC including tests) ships 10 wire
  APIs, about 40 provider factories, OAuth flows, image and classifier APIs, a
  generated model catalog, and the `pi-ai` CLI. Its core entry point
  `src/index.ts` is side-effect free. Each wire API sits behind a lazy
  `import()`.

## Retained files

### `packages/pi/agent/src/` ← upstream `packages/agent/src/` (keep all)

| File | LOC | Role |
|---|---|---|
| `agent-loop.ts` | 940 | `agentLoop` / `runAgentLoop`: turns, tool batches, `finishTurn` / `prepareRequest` hooks |
| `agent.ts` | 613 | Stateful `Agent`: subscribe, prompt, steer, follow-up, abort |
| `types.ts` | 529 | `AgentTool`, `AgentEvent`, `AgentLoopConfig`, `StreamFn` |
| `proxy.ts` | 406 | `streamProxy`: an SSE stream function for routing model calls through a server. It is the template for the node agent's `ProxyCompletion` stream function. |
| `stream-fn.ts` | 20 | `setDefaultStreamFn` |
| `index.ts` | 5 | Barrel |

Do not import `examples/`, `CHANGELOG.md`, or the npm `README.md`.

### `packages/pi/ai/src/` ← upstream `packages/ai/src/` (61 files, 18.7k LOC)

These files are the full import closure, value and type imports, of
`index.ts` plus the five retained wire APIs and their `.lazy.ts` loaders.

**Core (41 files, ≈9k LOC):**

```text
index.ts  types.ts  models.ts  models-store.ts  session-resources.ts
api/lazy.ts  api/simple-options.ts  api/transform-messages.ts  api/constrained-sampling.ts
api/openai-prompt-cache.ts  api/github-copilot-headers.ts
auth/context.ts  auth/credential-store.ts  auth/helpers.ts  auth/resolve.ts  auth/types.ts
providers/faux.ts
utils/abort.ts  utils/assistant-message-frame.ts  utils/diagnostics.ts  utils/error-body.ts
utils/estimate.ts  utils/event-stream.ts  utils/hash.ts  utils/headers.ts  utils/json-parse.ts
utils/model-operations.ts  utils/models-error.ts  utils/overflow.ts  utils/pi-user-agent.ts
utils/provider-env.ts  utils/provider-retry.ts  utils/retry.ts  utils/sanitize-unicode.ts
utils/text.ts  utils/transcript.ts  utils/typebox-helpers.ts  utils/uuid.ts  utils/validation.ts
api/openai-completions.ts  api/openai-completions.lazy.ts
```

**Supported native providers (9 files, ≈4.6k LOC):**

```text
api/anthropic-messages.ts  api/anthropic-messages.lazy.ts
api/bedrock-converse-stream.ts  api/bedrock-converse-stream.lazy.ts
api/google-generative-ai.ts  api/google-generative-ai.lazy.ts
api/google-vertex.ts  api/google-vertex.lazy.ts  api/google-shared.ts
```

**Carried for types only (11 files, ≈5k LOC):**

```text
api/azure-openai-config.ts  api/azure-openai-responses.ts  api/mistral-conversations.ts
api/openai-codex-responses.ts  api/openai-responses.ts  api/openai-responses-shared.ts
api/pi-messages.ts  compat/extension-oauth-types.ts  env-api-keys.ts
utils/abort-signals.ts  utils/node-http-proxy.ts
```

`types.ts` and `index.ts` import option *types* from every upstream wire
API, so these files must exist for `tsc` to succeed. They are never
registered or selected by the runners, and they are unsupported. Trimming them
would cost a second patch that conflicts on most syncs. Keeping them is the
cheaper trade. `compat/extension-oauth-types.ts` contains type declarations
only; no OAuth implementation is imported.

Notes on the less obvious files:

- `providers/faux.ts` is upstream's in-process fake provider. Keep it: it
  gives runner unit tests a model with no HTTP mock.
- `api/github-copilot-headers.ts` (37 LOC) is imported unconditionally by
  `openai-completions.ts` but only takes effect when
  `provider === "github-copilot"`.
- `env-api-keys.ts` resolves cloud credentials from the environment: the AWS
  chain and `GOOGLE_APPLICATION_CREDENTIALS`. Bedrock and Vertex rely on it by
  design. Everywhere else the runners pass keys explicitly.

### Runtime dependencies (upstream pins)

| Package | Version | Needed by |
|---|---|---|
| `openai` | 7.19.0 | `openai-completions` |
| `@anthropic-ai/sdk` | 0.129.0 | `anthropic-messages` |
| `@aws-sdk/client-bedrock-runtime`, `@smithy/node-http-handler` | 3.1127.0, 4.12.1 | `bedrock-converse-stream` |
| `@google/genai` | 2.21.0 | `google-generative-ai`, `google-vertex` |
| `http-proxy-agent`, `https-proxy-agent` | 9.1.0 | Corporate HTTP(S) proxy support for the SDKs |
| `typebox` | 1.3.27 | Tool parameter schemas and validation |
| `partial-json` | 0.1.7 | Streaming tool-call argument parsing |

`@earendil-works/pi-telemetry` is dropped by patch 0001. The provider SDKs
total about 60 MB in `node_modules`, but only the **central agent service**
installs them. The node agent bundles only `@shepherd/pi-agent`, the
`ProxyCompletion` stream function, and the agent core, so endpoints ship no
provider SDKs and no credentials.

## Removed parts

| Upstream path | Reason |
|---|---|
| `packages/coding-agent`, `tui`, `chord`, `client`, `server`, `protocol`, `durable`, `env`, `evals`, `mcp`, `codemode`, `telemetry` | Interactive CLI/TUI, local coding tools (fs, shell, edit), RPC server and client, durable sessions, MCP, evals. Shepherd's tools are hosted by the control plane or the daemon. |
| `ai/src/auth/oauth/*`, `oauth.ts`, `bun-oauth.ts`, `utils/oauth-page.ts` | Personal subscription OAuth logins (see [Scope decisions](#scope-decisions-reviewed-with-the-team)). |
| `ai/src/providers/*` except `faux.ts`, and `providers/data/*.json` | Built-in provider factories and the generated model catalog. Shepherd builds one `Model` from its own config. |
| `ai/src/api/*` other than the files above | Cloudflare, OpenRouter images, llama.cpp classify, typesafe classifiers. |
| `ai/src/compat.ts`, `legacy-api-aliases.ts`, `cli.ts`, `bedrock-provider.ts`, `images*.ts`, `image-models.ts`, `model-catalog.ts`, `models.generated.ts` | Deprecated global API, CLI, image generation, catalog. |
| `ai/scripts/*` | Model catalog generation from models.dev and OpenRouter. |

## Local patches

Each patch lives in `packages/pi/patches/NNNN-*.patch` and is applied in
order by `tools/upstream/pi-sync.sh`:

| Patch | File | Change | Size |
|---|---|---|---|
| `0001-ai-drop-telemetry-dependency.patch` | `ai/src/types.ts` | Replace the type-only `import type { TelemetryContext } from "@earendil-works/pi-telemetry"` with a local 3-line `TelemetryContext` interface. | −1 / +4 lines |

Some changes are mechanical transforms, not patches. The sync script applies
them before the patches:

- Rewrite `@earendil-works/pi-ai` → `@shepherd/pi-ai` in `agent/src`. These
  are the names already used by the #254 placeholders.
- Do not take upstream `package.json`, `tsconfig*.json`, or vitest configs.
  Those files are Shepherd-owned and stay outside the sync.

Policy: **Shepherd behavior goes in the runners (`apps/central-agent`,
`apps/node-agent`), not in fork patches.** Add a new patch only when no hook
or wrapper can do the job. Examples of such jobs: a security fix, or an
upstream bug that blocks a test.

### Behavior that needs no patch

| Spec requirement | Upstream mechanism |
|---|---|
| Max turns | `AgentOptions.finishTurn` returns `{ action: "end" }` after N turns. |
| Token budget | Sum `turn.message.usage.totalTokens` in `finishTurn` and end when the budget is reached. For a hard cap before each request, also clamp `maxTokens` in `prepareRequest`. |
| Timeouts / cancel | `Agent.abort()` and `AbortSignal` flow through to the HTTP request. |
| Provider outage | The stream function never throws. The final `AssistantMessage` has `stopReason: "error"` and `errorMessage`, so the runner maps it to a typed error. |
| Tool authorization and recording | `beforeToolCall` / `afterToolCall` hooks. The central agent's tools call `ToolHostService`; the node agent's tools call daemon IPC. |
| Node diagnosis tiers | Plain `AgentTool`s whose `execute` calls daemon IPC (`RunProbe`, `RunReadOnlyShell`, `ProposeRemediation`). Nothing in the fork changes. |
| Prompt hygiene | Tools return content blocks that the runner builds. Machine strings are wrapped there. |

## Provider notes

**OpenAI-compatible (`openai-completions`):**

- `POST {baseUrl}/chat/completions`, `stream: true`,
  `stream_options.include_usage`. Tool calls stream as argument deltas and are
  parsed incrementally.
- The `finish_reason` values `stop`, `tool_calls`, and `length` map to `stop`,
  `toolUse`, and `length`. A `length` stop fails every tool call in that
  message instead of running calls with truncated arguments.
- **Compat flags matter.** `detectCompat()` recognizes about a dozen hosted
  vendors by URL. Any other base URL is treated as real OpenAI: `developer`
  role, `store`, `max_completion_tokens`, and `reasoning_effort` are all on.
  vLLM, Ollama, LiteLLM, and llama.cpp often reject one or more of these, so
  spec 18 adds `AGENT_COMPAT`. Strict tool schemas are off by default.

**Native providers:**

- **Anthropic:** `anthropic-messages` with an API key.
- **Bedrock:** `bedrock-converse-stream` with the AWS credential chain
  (instance or IAM role, profile, access keys) and a region.
- **Google:** `google-generative-ai` with a Gemini API key.
- **Vertex:** `google-vertex` with a service account, project, and location.

Each one has upstream unit tests for message and tool conversion, and those
tests port unchanged ([Evidence](#evidence)). V1 adds one real smoke test per
provider behind an env flag.

**Model object and ambient inputs:**

- The runner builds a single `Model` from `AGENT_PROVIDER` / `AGENT_MODEL` /
  credentials, with no catalog lookup.
- Retained code reads `PI_CACHE_RETENTION` and, for Bedrock and Vertex only,
  the cloud credential variables.
- It sends `User-Agent: pi (<os> <release>; <arch>)`. The runners override it
  through `model.headers` with `shepherd-agent/<version>`.

## Node agent transport

Spec 18 keeps `ProxyCompletion` and specifies it end to end:

1. The node agent calls daemon IPC.
2. The daemon relays to `NodeAgentService.ProxyCompletion` on the control
   plane.
3. The control plane authorizes and records the call, then forwards it to the
   central agent service.
4. The central agent service runs Pi `streamSimple` with whichever provider is
   configured, and the events stream back.

The node agent's `StreamFn` is modeled on `proxy.ts`. The first draft of this
spike recommended an OpenAI-compatible passthrough instead. With native
providers in scope, that would force the control plane to translate between
APIs, so `ProxyCompletion` is the better fit: it works the same for every
provider and keeps SDKs and keys off endpoints.

## Workspace integration constraints (from #23 / #254)

- **TypeScript flags.** Upstream sources use `.ts` import specifiers, so the
  Pi packages' `tsconfig.json` must set `allowImportingTsExtensions` and
  `rewriteRelativeImportExtensions`. They also need `erasableSyntaxOnly` and
  `verbatimModuleSyntax` to match upstream. **Upstream does not compile with
  `noUncheckedIndexedAccess`** (173 errors in the 61-file `ai` set, 3 in
  `agent`), so `packages/pi/*` must override it to `false`. Target ES2023
  works.
- **Biome.** Upstream formats with tabs. The root `biome.json` uses 2-space
  indentation and a line width of 100. Exclude
  `packages/pi/{ai,agent}/src/**` and the upstream tests from Biome, or each
  sync becomes a whole-file reformat. Shepherd-owned files under
  `packages/pi/` remain linted.
- **Test runner.** The ported upstream tests use Vitest APIs that `bun test`
  lacks (`vi.hoisted`, `vi.stubGlobal`, `vi.advanceTimersByTimeAsync`,
  `vi.waitFor`): 11 of 110 core tests fail under `bun test`, and all pass
  under Vitest. The Pi packages' `test` script should run `vitest --run` (pin
  `4.1.11`). The runtime itself works under Bun 1.4.2.

## Sync strategy

Alternatives considered:

| Option | Verdict |
|---|---|
| Depend on the published `@earendil-works/pi-ai` / `pi-agent-core` | Rejected. Not a fork. It pulls every provider, OAuth, and the catalog, and it cannot be stripped. It remains the emergency fallback if the fork stalls. |
| `git subtree` / submodule of the whole monorepo | Rejected. Imports 13 packages and catalog data, and adds history noise. |
| **Vendored file manifest + patch queue** | **Chosen.** Small diff surface, explicit provenance, reproducible. |

`tools/upstream/pi-sync.sh <tag>`:

1. Shallow-clone `earendil-works/pi` at `<tag>` into a temp dir and record
   the commit SHA.
2. Copy the manifest (`packages/pi/upstream-files.txt`, the lists above) from
   upstream `packages/{ai,agent}/src` into `packages/pi/{ai,agent}/src`.
   Delete any vendored file no longer in the manifest. Copy the root `LICENSE`
   to `packages/pi/LICENSE`.
3. Check the import closure, value and type imports: fail if a vendored file
   imports a relative path missing from the manifest, and print the new files
   so a person can review and extend the manifest.
4. Apply the mechanical rewrite (`@earendil-works/pi-ai` → `@shepherd/pi-ai`).
5. Run `git apply --3way packages/pi/patches/*.patch` in order. Stop on
   conflict.
6. Update the tag, SHA, and date in `packages/pi/UPSTREAM.md`.
7. Run `bun run --filter '@shepherd/pi-*' build test` and the `tests/pi`
   suite.

Cadence: sync on demand, or at most once per two-week iteration, and only to
release tags. Before each bump, read the upstream changelog for
`packages/ai` and `packages/agent`. Do not sync during the release-hardening
iteration (weeks 11–12) unless a security fix requires it.

## Evidence

All of this was measured in scratch workspaces outside the repo; no spike code
is merged.

**Final variant: 61 `ai` files + agent, patch 0001, rename, the dependencies
above.**

- `tsc -p tsconfig.build.json` (TypeScript 5.9.3, strict, upstream flags)
  succeeds for `@shepherd/pi-ai` and then `@shepherd/pi-agent`.
- **23 upstream test files, 187 tests, pass** under Vitest 4.1.11 on Node 26:
  - core: `agent-loop`, `proxy`, `event-stream`, `validation`, `retry`,
    `provider-retry`, `overflow`, and
    `openai-completions-{raw-stop-reason,reasoning-details,retry,thinking-as-text}`
  - Anthropic: `anthropic-{eager-tool-input-compat,federation-sdk,strict-tool-schema}`
  - Bedrock: `bedrock-{convert-messages,redacted-reasoning}`
  - Google: `google-shared-{convert-tools,gemini3-unsigned-tool-call,image-tool-result-routing,retry,signed-empty-blocks}`
    and `google-thinking-{level-map,signature}`

  The remaining provider tests import the removed `compat.ts` or OAuth
  helpers. #190 can port them by switching to the `api/*` `stream` exports.

**First variant (OpenAI-compatible only, 41 files)** also built, passed its
11-file / 116-test subset, and was used for the smoke test below.

**Smoke test** against a mock OpenAI-compatible SSE server, using `Agent`,
one TypeBox tool, and the `streamSimple` stream function. It passed on Node 26
and Bun 1.4.2, and passed again on the final variant:

```json
{
  "roundtrip": { "requests": 2, "toolsAdvertised": ["fleet_summary"], "auth": "Bearer sk-test",
    "streamed": true, "toolArgs": { "scope": "all" },
    "toolResultSentBack": "{\"scope\":\"all\",\"machines\":3,\"failingDeployments\":1}",
    "textDeltas": ["3 machines", ", 1 failing", " deployment."],
    "final": "3 machines, 1 failing deployment.", "stopReason": "stop", "usage": 160 },
  "outage": { "threw": false, "stopReason": "error",
    "errorMessage": "503: {\"message\":\"upstream unavailable\"}", "requests": 1 },
  "maxTurns": { "turns": 3, "requests": 3, "tokens": 360 },
  "tokenBudget": { "turns": 3, "requests": 3, "tokens": 360, "budget": 250 }
}
```

The token budget is checked after each turn, so a run can exceed the budget
by up to one turn: 360 against a budget of 250. Runners that need a hard cap
should also clamp `maxTokens` in `prepareRequest`.

## Spec changes in this PR

- **SRS:**
  - AGT-02 allows native Anthropic, Bedrock, and Google providers with server
    credentials and rules out subscription logins.
  - New AGT-07: privileged read-only diagnosis executed by the daemon.
  - New AGT-08: findings escalate through the central agent to admins;
    remediation commands run only after an admin approves them and only from a
    signed instruction.
  - The component table is updated to match.
- **[18](../specs/18-agents.md):**
  - Pi fork scope.
  - Model providers and config (`AGENT_PROVIDER`, per-provider credentials,
    `AGENT_COMPAT`).
  - Node agent diagnosis tiers, with the probe catalog and the Linux and
    Windows sandbox designs.
  - Findings and escalation, and remediation commands.
  - The `ProxyCompletion` path.
  - The authority table and acceptance criteria.
- **[02](../specs/02-contracts.md):**
  - New RPCs: `SubmitAgentFinding`, `ProposeRemediation`, `ProxyCompletion`,
    `TriageFinding`.
  - New instructions: `RunAgent`, `RunRemediation`.
  - New `remediation` report kind.
- **[03](../specs/03-security-and-trust.md):** the `remediation.v1` payload
  type, its verification order, approval authority, and threat checklist
  items.
- **[04](../specs/04-control-plane.md):** `finding_triage` and
  `remediation_dispatch` workers.
- **[05](../specs/05-database.md):** `agent_findings`, `escalations`,
  `remediation_proposals`, and `remediation_dispatches`, plus admin-only
  approval invariants.
- **[10](../specs/10-node-daemon.md):** `diag/` and `remediation/` packages,
  the extended IPC surface, and the rule that no IPC method changes the
  machine.
- **[17](../specs/17-web-console.md):** the escalations inbox, the
  remediation review page, provider settings, and the machine Agent tab.
- **[00](../specs/00-delivery-plan.md):** the weeks 9–10 theme.
- Also updated: `KNOWLEDGE.md`, `architecture/agent-system.md`, and
  `packages/pi/UPSTREAM.md`.

## Follow-ups

Existing issues:

| Issue | Input from this spike |
|---|---|
| #189 Import and strip Pi fork | Use the 61 + 6 file manifest, patch 0001, the rename, the dependencies, the tsconfig and Biome overrides, and the sync script above. Seed `packages/pi/{ai,agent}/test` with the 23 portable upstream test files. |
| #23 / #254 TS workspace | Pi packages override `noUncheckedIndexedAccess`, are excluded from Biome, and use Vitest. `.nvmrc` must be ≥ 22.19. |
| #190 Pi runtime tests | Start from the smoke-test scenarios. Port the compat-based provider tests. Add per-provider smoke tests behind env flags. |
| #216 Central agent | `AGENT_PROVIDER` and per-provider credentials. Set `User-Agent`. Map `stopReason: "error"` to `UNAVAILABLE`. Add the `TriageFinding` RPC. |
| #217 Central agent tools | Add `findings.*`, `node.investigate`, `escalations.create`, and `remediation.propose`. |
| #220 Model proxy | `NodeAgentService.ProxyCompletion` through the central agent service, using the `proxy.ts` event shape. |
| #201 / #221 Node IPC and node agent | Extended IPC surface and the tiered diagnostic tools. `submitFinding` at session end. |
| #222 Agent authorization tests | Add `ApproveRemediation` denial for agent principals. |
| #31 / #34 / #56 Contracts | `node.v1` gets `SubmitAgentFinding`, `ProposeRemediation`, `RunAgent`, and `RunRemediation`. `finding.v1` and `remediation.v1` JSON Schemas with fixtures go in #34. `agent.v1` gets `TriageFinding`, `ProxyCompletion`, `UploadSession`, and the node-agent IPC methods. These land in weeks 3–4, ahead of every consumer. |

New issues filed from this spike:

| Issue | Key | Lane | Weeks |
|---|---|---|---|
| #256 Native model providers: Anthropic, Bedrock, Google, Vertex | T18.11 | Server | 7–8 |
| #257 Diagnostic probe catalog (Tier 1): Windows and NixOS | T10.18 | Node | 9–10 |
| #258 Read-only diagnostic sandbox (Tier 2): Linux | T10.19 | Node | 9–10 |
| #259 Remediation proposals, admin approval, signing, and dispatch | T18.13 | Server | 9–10 |
| #260 Signed remediation executor (Tier 3) in the daemon | T10.20 | Node | 9–10 |
| #261 Node findings, central triage-finding workflow, and escalations | T18.12 | Server | 9–10 |
| #262 Console: escalations inbox and remediation review | T17.22 | Server | 9–10 |
| #263 Diagnostic probes for macOS (Tier 1), **P1** | T10.21 | Node | 9–10 |
| #264 Windows JEA read-only diagnostic endpoint (Tier 2), **P1** | T10.22 | Node | 9–10 |

The P0 issues add 6.5 estimate points to weeks 9–10 (L = 2, M = 1,
S = 0.5), split across both lanes, and 0.5 to weeks 7–8. #263 and #264 add
2 more points at P1: they are the cut line. If weeks 9–10 overflow, drop
#263 first, then #264. Without them, macOS and Windows keep Tier 3 and
Windows keeps Tier 1. Linux, Windows probes, and the remediation path are
what make the escalation flow demonstrable.
