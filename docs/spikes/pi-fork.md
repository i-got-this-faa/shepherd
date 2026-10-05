# Spike: Pi fork import plan

| | |
|---|---|
| Issue | #53 (`T18.00`), unblocks #189 |
| Spec | [18 — Agents § Pi fork](../specs/18-agents.md#pi-fork-packagespi) |
| SRS | AGT-02 |
| Date | 2026-10-05 |
| Decision | **Go.** Fork 41 files of `packages/ai` and all 6 files of `packages/agent`, with two small patches. The spec needs the corrections listed in [Spec changes](#spec-changes) |

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
them touched the files we keep.

## What upstream contains

The monorepo has 13 packages: `agent ai chord client codemode coding-agent
durable env evals mcp protocol server telemetry tui`.

- `packages/agent` (6 source files, 2,513 LOC) is already headless. It
  contains the agent loop, the stateful `Agent`, tool execution with schema
  validation, steering and follow-up queues, and an HTTP proxy stream
  function. **It has no TUI, CLI, file-system, or shell tools.** Those live in
  `packages/coding-agent`, which the fork does not import at all.
- `packages/ai` (≈230 source files, 77k LOC including tests) ships 10 wire
  APIs, about 40 provider factories, OAuth flows, image and classifier APIs, a
  generated model catalog, and the `pi-ai` CLI. Its core entry point
  `src/index.ts` is side-effect free. Providers live behind `api/*` and
  `providers/*` subpaths.

## Retained files

### `packages/pi/agent/src/` ← upstream `packages/agent/src/` (keep all)

| File | LOC | Role |
|---|---|---|
| `agent-loop.ts` | 940 | `agentLoop` / `runAgentLoop`: turns, tool batches, `finishTurn` / `prepareRequest` hooks |
| `agent.ts` | 613 | Stateful `Agent`: subscribe, prompt, steer, follow-up, abort |
| `types.ts` | 529 | `AgentTool`, `AgentEvent`, `AgentLoopConfig`, `StreamFn` |
| `proxy.ts` | 406 | `streamProxy`: an SSE stream function for routing model calls through a server (see [Node agent transport](#node-agent-transport)) |
| `stream-fn.ts` | 20 | `setDefaultStreamFn` |
| `index.ts` | 5 | Barrel |

Do not import `examples/` (MCP code-mode demo), `CHANGELOG.md`, or the npm
`README.md`.

### `packages/pi/ai/src/` ← upstream `packages/ai/src/` (41 files, 8,959 LOC)

These files are the full import closure of `index.ts` plus
`api/openai-completions.ts` after [patches](#local-patches) 0001 and 0002. The
closure follows both value and type imports, so `tsc` sees every file it
needs.

```text
index.ts  types.ts  models.ts  models-store.ts  session-resources.ts
api/openai-completions.ts  api/openai-completions.lazy.ts  api/lazy.ts
api/constrained-sampling.ts  api/simple-options.ts  api/transform-messages.ts
api/openai-prompt-cache.ts  api/github-copilot-headers.ts
auth/context.ts  auth/credential-store.ts  auth/helpers.ts  auth/resolve.ts  auth/types.ts
providers/faux.ts
utils/abort.ts  utils/assistant-message-frame.ts  utils/diagnostics.ts  utils/error-body.ts
utils/estimate.ts  utils/event-stream.ts  utils/hash.ts  utils/headers.ts  utils/json-parse.ts
utils/model-operations.ts  utils/models-error.ts  utils/overflow.ts  utils/pi-user-agent.ts
utils/provider-env.ts  utils/provider-retry.ts  utils/retry.ts  utils/sanitize-unicode.ts
utils/text.ts  utils/transcript.ts  utils/typebox-helpers.ts  utils/uuid.ts  utils/validation.ts
```

Notes on the less obvious files:

- `api/openai-completions.ts` (1,734 LOC) is the only wire implementation we
  keep. It covers Chat Completions with SSE streaming, incremental tool-call
  argument parsing, usage in the stream, retries, and compat flags.
- `providers/faux.ts` is upstream's in-process fake provider. Keep it: it
  gives runner unit tests a model with no HTTP mock.
- `api/github-copilot-headers.ts` (37 LOC) is imported unconditionally by
  `openai-completions.ts` but only takes effect when `provider ===
  "github-copilot"`. Patching it out would save nothing.
- `auth/*` holds the generic credential types and resolver used by
  `models.ts`. The OAuth implementations (`auth/oauth/*`) are not in the
  closure.

### Runtime dependencies after the trim

| Package | Version (upstream pin) | Why |
|---|---|---|
| `openai` | 7.19.0 | HTTP client for Chat Completions |
| `typebox` | 1.3.27 | Tool parameter schemas and validation |
| `partial-json` | 0.1.7 | Streaming tool-call argument parsing |

These dependencies are removed: `@anthropic-ai/sdk`,
`@aws-sdk/client-bedrock-runtime`, `@google/genai`,
`@smithy/node-http-handler`, `http-proxy-agent`, `https-proxy-agent`, and
`@earendil-works/pi-telemetry`. Removing them matters for the node agent,
which ships to endpoints.

## Removed parts

| Upstream path | Reason |
|---|---|
| `packages/coding-agent`, `tui`, `chord`, `client`, `server`, `protocol`, `durable`, `env`, `evals`, `mcp`, `codemode`, `telemetry` | Interactive CLI/TUI, coding tools (fs, shell, edit), RPC server and client, durable sessions, MCP, evals. None are needed by a headless runner whose tools are hosted by the control plane. |
| `ai/src/api/*` except the 8 files above | Anthropic, OpenAI Responses and Codex, Azure, Google and Vertex, Mistral, Bedrock, pi-messages, Cloudflare, OpenRouter images, llama.cpp classify. AGT-02 requires OpenAI-compatible only. |
| `ai/src/providers/*` except `faux.ts`, and `providers/data/*.json` | Built-in provider factories and the generated model catalog. Shepherd builds one `Model` from its own config. |
| `ai/src/auth/oauth/*`, `oauth.ts`, `bun-oauth.ts`, `utils/oauth-page.ts` | Subscription OAuth logins. Shepherd uses a static API key from server secrets. |
| `ai/src/compat.ts`, `compat/*`, `legacy-api-aliases.ts`, `env-api-keys.ts` | Deprecated global API that reads keys from the process environment. Shepherd passes the key explicitly. |
| `ai/src/cli.ts`, `bedrock-provider.ts`, `images*.ts`, `image-models.ts`, `model-catalog.ts`, `models.generated.ts`, `utils/node-http-proxy.ts`, `utils/abort-signals.ts` | CLI, image generation, catalog, and proxy-agent plumbing. Unused by the closure. |
| `ai/scripts/*` | Model catalog generation from models.dev and OpenRouter. |

## Local patches

Each patch lives in `packages/pi/patches/NNNN-*.patch` and is applied in
order by `tools/upstream/pi-sync.sh`. Together they change about 40 lines:

| Patch | File | Change | Size |
|---|---|---|---|
| `0001-ai-index-openai-only.patch` | `ai/src/index.ts` | Drop the type re-exports from removed APIs (`AnthropicOptions` … `PiMessagesOptions`) and from `compat/extension-oauth-types.ts`. | −18 lines |
| `0002-ai-types-openai-only.patch` | `ai/src/types.ts` | Drop 9 type-only imports of removed API option types and their `ApiOptionsMap` entries, leaving only `"openai-completions"`. Replace the type-only `@earendil-works/pi-telemetry` import with a local `TelemetryContext` interface. | −20 / +4 lines |

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
| Tool authorization and recording | `beforeToolCall` / `afterToolCall` hooks, or tools whose `execute` calls `ToolHostService`. |
| Prompt hygiene | Tools return content blocks that the runner builds. Machine strings are wrapped there. |

## OpenAI-compatible support notes

- **Wire API:** `api: "openai-completions"` (`POST {baseUrl}/chat/completions`,
  `stream: true`, `stream_options.include_usage`). Tool calls stream as
  `tool_calls[].function.arguments` deltas and are parsed incrementally. The
  `finish_reason` values `stop`, `tool_calls`, and `length` map to `stop`,
  `toolUse`, and `length`. A `length` stop fails every tool call in that
  message instead of running calls with truncated arguments.
- **Model object:** the runner builds one `Model<"openai-completions">` from
  config, with no catalog lookup: `{ id: AGENT_MODEL, provider: "shepherd",
  baseUrl: AGENT_BASE_URL, api: "openai-completions", contextWindow,
  maxTokens, reasoning, input: ["text"], cost: zeros, compat }`. The key is
  passed per request (`options.apiKey`), never through the environment.
- **Compat flags matter.** `detectCompat()` recognizes about a dozen hosted
  vendors by URL. **Any other base URL is treated as real OpenAI**:
  `developer` role, `store`, `max_completion_tokens`, and `reasoning_effort`
  are all on. Self-hosted vLLM, Ollama, LiteLLM, and llama.cpp often reject
  one or more of these. Shepherd must therefore expose explicit compat
  overrides (`AGENT_COMPAT`, see [Spec changes](#spec-changes)). AGT-02's
  "tested against the selected provider" check should record which compat set
  passed.
- **Strict tool schemas** are off by default (`supportsStrictMode: false`),
  which is correct for generic endpoints.
- **Ambient inputs:** the retained code reads one environment variable,
  `PI_CACHE_RETENTION` (prompt-cache hinting). It sends
  `User-Agent: pi (<os> <release>; <arch>)`, which `model.headers` can
  override. The runners should set `User-Agent: shepherd-agent/<version>` so
  endpoints don't leak OS details.

## Node agent transport

`proxy.ts` already implements a stream function that posts the context to a
server and consumes a compact SSE event stream (`ProxyAssistantMessageEvent`).
There are two ways to satisfy spec 18's "model calls go through the control
plane's model proxy":

1. **OpenAI-compatible passthrough (recommended).** The control plane exposes
   `/v1/chat/completions` to the node agent. The node agent sends a
   short-lived node-agent token as its "API key", and the control plane
   injects the real key and forwards the request. The node agent then reuses
   the exact `openai-completions` path the central agent uses, so one code
   path covers both agents, and #190's mock server tests the node agent too.
2. **`AgentService.ProxyCompletion` Connect stream.** Write a custom
   `StreamFn`, modeled on `proxy.ts`, that maps Connect messages to
   `AssistantMessageEvent`s. This adds a second serialization of the
   assistant stream that has to be maintained and tested.

The spec currently names `ProxyCompletion`. Decide this in #216/#221. Keep
`proxy.ts` in the fork either way, because it costs nothing and is the
template for option 2.

## Workspace integration constraints (from #23 / #254)

- **TypeScript flags.** Upstream sources use `.ts` import specifiers, so the
  Pi packages' `tsconfig.json` must set `allowImportingTsExtensions` and
  `rewriteRelativeImportExtensions`. They also need `erasableSyntaxOnly` and
  `verbatimModuleSyntax` to match upstream. **Upstream does not compile with
  `noUncheckedIndexedAccess`** (83 errors in `ai`, 3 in `agent`), so
  `packages/pi/*` must override it to `false`. Patching 86 call sites would
  make every sync conflict. Target ES2023 works.
- **Biome.** Upstream formats with tabs. The root `biome.json` uses 2-space
  indentation and a line width of 100. Exclude
  `packages/pi/{ai,agent}/src/**` and the upstream tests from Biome, or each
  sync becomes a whole-file reformat and the patches stop applying.
  Shepherd-owned files under `packages/pi/` remain linted.
- **Test runner.** The ported upstream tests use Vitest APIs that `bun test`
  lacks (`vi.hoisted`, `vi.stubGlobal`, `vi.advanceTimersByTimeAsync`,
  `vi.waitFor`): 11 of 110 fail under `bun test`, and all pass under Vitest.
  The Pi packages' `test` script should run `vitest --run` (pin `4.1.11`);
  `bun run --filter` invokes it unchanged. The runtime itself works under Bun
  1.4.2, as the smoke test below passed.

## Sync strategy

Alternatives considered:

| Option | Verdict |
|---|---|
| Depend on the published `@earendil-works/pi-ai` / `pi-agent-core` | Rejected. Not a fork, and it pulls the Anthropic, AWS, and Google SDKs into the endpoint-shipped node agent. It cannot be stripped. It remains the emergency fallback if the fork stalls. |
| `git subtree` / submodule of the whole monorepo | Rejected. Imports 13 packages and catalog data, adds history noise, and still needs the trim and patches. |
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

All of this was measured in a scratch workspace outside the repo. That
workspace held the manifest above, patches 0001 and 0002, the package rename,
and the three runtime dependencies. No spike code is merged.

- **Build:** `tsc -p tsconfig.build.json` (TypeScript 5.9.3, strict, upstream
  flags) succeeds for `@shepherd/pi-ai` and then `@shepherd/pi-agent`.
- **Upstream tests that port unchanged:** 11 files and 116 tests pass under
  Vitest 4.1.11 on Node 26.0. The files are `agent-loop`, `proxy`,
  `openai-completions-{raw-stop-reason,reasoning-details,retry,thinking-as-text}`,
  `event-stream`, `validation`, `retry`, `provider-retry`, and `overflow`. The
  other `openai-completions-*` tests (`tool-choice`, `empty-tools`,
  `tool-result-images`, `vllm-priority`, …) import the removed `compat.ts`.
  #190 can port them by switching to `api/openai-completions`'s `stream`.
- **Smoke test against a mock OpenAI-compatible SSE server**, using `Agent`,
  one TypeBox tool, and the `streamSimple` stream function. It passed on
  Node 26 and Bun 1.4.2:

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

## Spec changes

This PR updates [18 — Agents § Pi fork](../specs/18-agents.md#pi-fork-packagespi):

- Upstream URL becomes `earendil-works/pi`. The pin is recorded here.
- `packages/agent` has no fs or shell tools to remove. The exclusion applies
  to `coding-agent` and the other packages.
- Patches live in `packages/pi/patches/`, and the manifest in
  `packages/pi/upstream-files.txt`.
- Max turns and token budget are runner hooks (`finishTurn` /
  `prepareRequest`), not fork patches.
- Config gains `AGENT_COMPAT`: JSON overrides for `OpenAICompletionsCompat`.

Open for #216/#221: node agent transport (passthrough vs `ProxyCompletion`).

## Follow-ups

| Issue | Input from this spike |
|---|---|
| #189 Import and strip Pi fork | Use the manifest, patches 0001/0002, rename, dependencies, tsconfig and Biome overrides, and the sync script design above. Seed `packages/pi/{ai,agent}/test` with the 11 portable upstream test files. |
| #23 / #254 TS workspace | Pi packages override `noUncheckedIndexedAccess`, are excluded from Biome, and use Vitest. `.nvmrc` must be ≥ 22.19. |
| #190 Pi runtime tests | The smoke-test scenarios above are the starting fixtures. Port the compat-based `openai-completions-*` tests. Assert that the token budget overshoots by at most one turn. |
| #216 Central agent | Build `Model` from config including `AGENT_COMPAT`. Set `User-Agent`. Map `stopReason: "error"` to `UNAVAILABLE`. |
| #221 Node agent | Decide the model-proxy transport (recommendation: OpenAI-compatible passthrough). |
