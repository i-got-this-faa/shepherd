# 17 — Web console

Next.js 16 (App Router, React Server Components), TypeScript strict, in
`apps/web-console/`. Pin the exact 16.x in weeks 1–2. UI kit `[impl]`: shadcn/ui
(Radix + Tailwind) — copy-in components, no runtime lock-in. Data: Connect-ES
clients generated from `console.v1`, TanStack Query on the client for live
views; server components call the Go API with the session cookie forwarded.
Code editor: Monaco (advanced Nix editor) with a Nix TextMate grammar.

The console never holds signing keys or node credentials [AGT-06]; all
authority is checked by the Go API.

## Information architecture

| Route | Purpose | SRS |
|---|---|---|
| `/login` | Admin login (+TOTP when enabled) | ADM-04 |
| `/` (Overview) | Fleet health: online/offline/stale, deployments in progress, open drift, recent failures, capability gaps | DEP-03/04 |
| `/machines` | Inventory table: hostname, platform/edition, status, effective profile (and source: direct/group), assigned target vs active generation, last seen (stale label), drift count, auto-fix state | PRF-04, DEP-04 |
| `/machines/[id]` | Tabs: Overview (three separate fields: assigned target, active configuration, last transition result), Reports, Drift, Capabilities/omitted settings, Inventory, Managers detected, Timeline (audit), Agent (node agent sessions with probe and sandbox transcripts, findings, remediations), Actions (reapply, toggle auto-fix, assign profile, remove) | PRF-04, DEP-03, ADM-02/03 |
| `/groups`, `/groups/[id]` | Membership, assigned profile, conflicts | PRF-01..03 |
| `/profiles`, `/profiles/[id]` | Profile overview, current revision, assigned groups/machines, auto-fix default, maintenance windows, rollout policy | PRF, DEP-07 |
| `/profiles/[id]/configure` | **Configurator** (structured GUI) editing a draft | CFG-01..03 |
| `/profiles/[id]/advanced` | Hidden-by-default advanced editor: custom modules (Monaco), file tree, eval errors inline | CFG-01/02/05 |
| `/drafts/[id]` | Draft review: source diff, plan diff per platform, capability coverage, eval status/errors, destructive acknowledgements, Approve button | CFG-04..07, AGT-05 |
| `/deployments`, `/deployments/[id]` | Rollout schedule preview, per-machine progress (pending→healthy/failed/recovered), pause/resume/cancel, peer vs cache bytes | DEP-01/07 |
| `/drift` | Fleet drift findings, filter by profile/resource, bulk reapply (approved generation only) | DEP-03, AGT-04 |
| `/enrollment` | Create tokens (platform, initial group, expiry, max uses), download bundle/ISO build instructions, macOS profile download, revoke | ADM-01/04 |
| `/agents` | Central agent chat: ask about failures, request drafts; shows tool calls and that drafts need approval | AGT-01..05 |
| `/escalations`, `/escalations/[id]` | Inbox of central agent escalations. Each shows: the summary, correlated machines, raw node finding evidence next to the agent summary, session links, and the linked draft or remediation. Acknowledge and resolve actions | AGT-07/08 |
| `/remediations/[id]` | Remediation review: every step verbatim (shell, argv/script, run-as, timeout), target machines, evidence, a managed-resource warning, then Approve/Reject (admins only; absent for agent principals); per-machine dispatch results with redacted output | AGT-08 |
| `/audit` | Audit log with filters, export CSV | ADM-05 |
| `/settings` | Admins, AI provider (OpenAI-compatible, Anthropic, Bedrock, Google, Vertex), endpoint/model, credentials (write-only), DERP/mesh status, keys (rotation), Attic/FBS health, capability table | AGT-02, ADM-04 |

AI-dependent UI degrades gracefully: when the agent is disabled/unreachable,
the Agents page and "Explain" buttons show disabled state; every other page
works [AGT-01, DEM-01].

## Configurator design

Sections mirror `generated.json` ([06](06-configuration-pipeline.md)):
Applications (catalog search, pinned version, per-platform availability
badges), Environment (variables, PATH entries with append/prepend, platform
scope), Services, Firewall rules, Local accounts, Network (DNS/proxy), Windows
(Registry editor with typed values and view, Policies picker, Scheduled tasks,
Update settings), macOS (defaults, MDM profiles), Health checks.

Behaviors:

- Every field shows the platforms it applies to and a warning icon when a
  target platform/edition cannot enforce it (from capability data) [CFG-06].
- Saving writes the draft; evaluation runs automatically and status updates
  live (streaming `WatchEvaluation`).
- Fields defined by custom modules are shown read-only with "defined in
  custom/foo.nix" so the GUI does not overwrite custom source [CFG-02].
- Validation client-side (zod schemas generated from contracts where
  possible) + server-side.

## Review and approval UX

- Approve requires: valid evaluation for all target platforms, explicit tick
  for each destructive change, comment optional. The button is absent for
  agent principals (and the API rejects them anyway).
- After approval, the deployment preview shows targeted machines, windows,
  rollout batches; "Deploy" confirms [DEP-07].

## Live updates

Server-streaming Connect RPCs (`WatchMachine`, `WatchDeployment`,
`WatchFleetSummary`) over HTTP/2; fallback polling every 5 s.

## Quality bars

- Accessibility: keyboard navigation, labels, contrast (WCAG AA).
- Every reported string rendered as text (no `dangerouslySetInnerHTML`); CSP
  header with nonces.
- Playwright e2e for DEM flows against the docker-compose stack + fakenode.
- Empty states and error states for every list.

## Acceptance

- DEM-01 is executable entirely in the console without raw Nix and without AI.
- Playwright suite covers login, create profile, configure, review diff,
  approve, deploy, see machine converge (fakenode), drift + auto-fix, profile
  precedence, removal.
