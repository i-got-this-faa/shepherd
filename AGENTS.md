# Shepherd — Agent Instructions & Repository Manual

## Repository Layout (Systems)

```
shepherd/
├── apps/
│   ├── control-plane/    # Go central control-plane service (shepherd)
│   ├── build-worker/     # Go build & artifact worker (shepherd-builder)
│   └── node-daemon/      # Go cross-platform node daemon (shepherd-node)
├── infra/
│   ├── database/         # Postgres migrations & schema
│   ├── networking/       # Tailcat mesh, relays (shepherd-derper)
│   └── storage/          # Attic & FBS storage definitions
├── internal/             # Cross-binary shared Go packages (e.g. version, signing)
├── networking/           # WireGuard/Tailcat transport and policy libraries
├── nix/                  # NixOS & Darwin system modules, dev shell, templates
├── packages/
│   └── contracts/        # Protobuf definitions, JSON schemas, generated code
├── tools/
│   ├── fakes/            # Mock services (shepherd-fakecp, shepherd-fakenode)
│   └── shepherdctl/      # Admin / operator CLI
├── docs/                 # Authoritative SRS and implementation specifications (specs 00-20)
└── Makefile              # Root build, test, and verification automation
```

## Key Commands

Run all checks from repository root:

```bash
# Build all system binaries into bin/
make build

# Run unit tests
make test

# Run Go static analysis
make lint

# Combined quality gate (runs lint + test)
make check

# Cross-compile node daemon for Windows AMD64
GOOS=windows GOARCH=amd64 go build ./apps/node-daemon/...

# Cross-compile node daemon for macOS Apple Silicon
GOOS=darwin GOARCH=arm64 go build ./apps/node-daemon/...
```

## Lane Rules & Parallel Execution

Two primary lanes execute in parallel:
- **Server Lane**: Owns `apps/control-plane`, `apps/build-worker`, `infra/`, database schema, Nix config modules. Uses `tools/fakes/fakenode` for local testing.
- **Node Lane**: Owns `apps/node-daemon`, platform providers (Windows, NixOS, macOS), mesh transport (`networking/`). Uses `tools/fakes/fakecp` for daemon testing.
- **Shared Lane**: Interfaces (`packages/contracts`), security primitives (`internal/signing`), repo tooling, CI, and release evidence.

**Contract changes must go first**:
Any payload or RPC contract change must land as a distinct PR touching `packages/contracts/` before dependent lanes implement against it.

## Commit & Branch Conventions

- **Commits**: Follow Conventional Commits format:
  - `feat(node-daemon): add windows registry provider`
  - `fix(control-plane): enforce token expiration check`
  - `docs(specs): update enrollment flow`
- **Branches**: Format branches as `feat/<backlog-key>-<short-slug>` (e.g., `feat/t01-01-go-module`).

## Definition of Done (All Changes)

1. PR references the relevant issue (`Closes #<id>`) and links to the spec section.
2. `make check` passes cleanly without warnings or errors.
3. Cross-compilation passes for `shepherd-node` (`windows/amd64` and `darwin/arm64`).
4. Contract fixtures updated in `packages/contracts/` if any serialization schema changes.
5. No secrets, keys, or credentials committed (`gitleaks` clean).
6. Real machine evidence (command outputs or logs) recorded for node/system changes.
