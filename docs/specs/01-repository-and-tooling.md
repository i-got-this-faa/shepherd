# 01 — Repository and tooling

## Workspaces

### Go `[impl]`

One Go module at the repository root: `module github.com/i-got-this-faa/shepherd`.
A single module keeps cross-component refactors atomic and lets the daemon,
control plane, build worker, networking, and distribution share packages
without version skew. Pin the Go toolchain with the `toolchain` directive;
match Tailcat's minimum (Go 1.27.x at the time of writing).

| Binary | Main package | Targets |
|---|---|---|
| `shepherd` (control plane) | `apps/control-plane/cmd/shepherd` | linux/amd64, linux/arm64 |
| `shepherd-builder` | `apps/build-worker/cmd/shepherd-builder` | linux/amd64, linux/arm64, darwin/arm64 (Darwin builds) |
| `shepherd-node` | `apps/node-daemon/cmd/shepherd-node` | windows/amd64, linux/amd64, linux/arm64, darwin/arm64, darwin/amd64 |
| `shepherd-derper` | `infra/networking/relays/cmd/shepherd-derper` (thin wrapper over `tailscale.com/cmd/derper`) | linux/amd64 |
| `shepherd-fakenode`, `shepherd-fakecp` | `tools/fakes/...` | linux, windows |
| `shepherdctl` | `tools/shepherdctl` | all (admin/debug CLI against the console API) |

Shared Go packages live under `internal/` at the root only when two or more
binaries import them (`internal/signing`, `internal/plan`, `internal/journal`
are expected); component-private code stays inside each app's `internal/`.

### TypeScript `[impl]`

pnpm workspace at the root (`pnpm-workspace.yaml`):

- `apps/web-console` — Next.js 16 (App Router).
- `apps/central-agent` — Node.js service hosting the central Pi runtime.
- `apps/node-agent` — Node.js process launched by the daemon on demand.
- `packages/pi/ai`, `packages/pi/agent` — the stripped Pi fork.
- `packages/contracts/gen/ts` — generated TS clients/types.

Use Node.js LTS pinned in `.nvmrc` and in the Nix dev shell. TypeScript strict
mode everywhere. Biome for lint+format (one tool, fast) `[impl]`.

### Nix

The repository root gets a `flake.nix` that provides:

- `devShells.default`: Go, gopls, golangci-lint, buf, protoc-gen-go,
  protoc-gen-connect-go, Node.js, pnpm, postgresql (for local tests), attic-client,
  sqlc, goose, gitleaks, nixfmt, jq, qemu/libvirt tooling hints.
- `packages.<system>.shepherd-node`, `shepherd`, `shepherd-builder` via
  `buildGoModule` (vendor hash pinned).
- `nixosModules.shepherd-node` and `nixosModules.shepherd-server` (see [07](07-nix-modules.md), [20](20-operations-and-release.md)).
- `darwinModules.shepherd-node`.
- `lib.shepherd` — the option modules consumed by the per-org config repo.
- `checks` — nix module evaluation tests (see [19](19-testing-and-demo.md)).

## Code generation

- `buf` with `buf.gen.yaml` generating Go (`protoc-gen-go`,
  `protoc-gen-connect-go`) into `packages/contracts/gen/go` and TS
  (`@bufbuild/protoc-gen-es`) into `packages/contracts/gen/ts`.
- JSON Schemas in `packages/contracts/schemas/*.schema.json` are the source for
  plan/report/journal; Go types generated with `go-jsonschema` or hand-written
  with schema conformance tests `[impl: decide in the contracts issue]`.
- `sqlc` generates typed Go queries from `apps/control-plane/internal/db/queries/*.sql`.
- Generated code is committed so agents and reviewers see it; CI fails if
  regeneration produces a diff.

## CI (GitHub Actions)

Workflows under `.github/workflows/`:

| Workflow | Trigger | Jobs |
|---|---|---|
| `ci.yml` | PR, push to main | `go` (vet, golangci-lint, `go test ./...` with race on linux, cross-compile matrix incl. windows/darwin), `ts` (pnpm install --frozen-lockfile, biome, typecheck, vitest), `contracts` (buf lint, buf breaking against main, regenerate-and-diff), `nix` (`nix flake check` on ubuntu with Nix installer), `secrets` (gitleaks) |
| `windows.yml` | PR touching node-daemon | `go test ./apps/node-daemon/...` on `windows-latest` including provider integration tests that are safe on runners (registry under HKCU test key, services read-only, env read-only) |
| `integration.yml` | PR label `integration`, nightly | docker-compose: postgres + FBS + Attic + control plane + fakenode; runs contract and API integration tests |
| `release.yml` | tag `v*` | build all binaries, sign checksums, build NixOS/Windows ISOs (self-hosted runner optional), publish release |

Required checks on `main`: `go`, `ts`, `contracts`, `secrets`.

## Local lab

`infra/development/` provides:

- `docker-compose.yml`: postgres:17, FBS (built from pinned `fbs-core` revision),
  Attic (`atticd`) configured against FBS, `shepherd` control plane,
  `shepherd-derper`, optional `nanomdm`.
- `lab/` libvirt definitions (or Vagrant-free scripts) for: Windows 11 Pro VM,
  Windows 11 Home VM, NixOS VM, plus instructions for a physical/virtual Mac.
  VMs attach to a NAT network that can reach the host's DERP and control plane,
  and an "isolated" network profile that blocks UDP to force DERP relay.
- `make lab-up`, `make lab-reset-<vm>` (snapshot revert) targets.

## Repository hygiene

- `CODEOWNERS`: lane owners per top-level path.
- PR template with: linked issue, spec section, SRS IDs, evidence, checklist
  from the definition of done.
- Issue templates: Task, Spike, Bug, Contract change.
- Conventional Commits (`feat(node-daemon): ...`) — matches existing history.
- `AGENTS.md` at root with build/test commands per component so coding agents
  can self-serve; `CLAUDE.md` symlink to it.

## Acceptance

- `nix develop -c make check` passes on a fresh clone on Linux.
- `go build ./...` cross-compiles `shepherd-node` for windows/amd64 and darwin/arm64.
- `pnpm -r build` succeeds.
- CI is green on an empty-feature PR and red on a deliberately broken contract.
