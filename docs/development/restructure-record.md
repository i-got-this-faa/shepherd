# Repository restructure record

## Completion record

The final scaffold uses `apps/central-agent/`, `packages/pi/`, top-level
`networking/`, native daemon platform providers under `internal/platform/`, and
the preserved Windows implementation under `reference/powershell/`. Tests are
under `tests/platform/`; manual Windows probes are under `tools/probes/windows/`.
Attic and its selected FBS storage dependency have separate deployment homes.
The complete current tree is recorded in the root README.

Final static checks: 84 `.gitkeep` files; no unpreserved empty directories;
70 local Markdown links, 14 PowerShell/launcher dependency paths, and eight
presentation assets resolve. Existing source differences were inspected and
are relocation references and documentation changes. Windows runtime suites,
Pi integration, mesh traffic, and Attic/FBS compatibility were not run; no new
service implementation was added by this scaffold. The SRS remains open as
recorded in `docs/scope/KNOWLEDGE.md`.

| Result | Source paths | Runtime paths | Check | State | Evidence |
|---|---|---|---|---|---|
| Separate deployable Windows agent | `agent/` | `apps/node-daemon/reference/powershell/` | PowerShell path resolution and source checks | proved | relative imports resolve in repository |
| Separate Windows tests | `tests/` | `tests/platform/windows/` | test dependency path scan | proved | test module and CLI paths resolve |
| Separate operator tools | `scripts/`, `run-elevated.cmd` | `tools/probes/windows/` | launcher and documentation path scan | proved | no old repository path remains |
| Separate academic artifacts | root presentation and synopsis paths | `artifacts/academic/` | presentation asset scan | proved | local image paths resolve |
| Define agent architecture | patent and Pi documentation | `docs/architecture/`, `docs/patent/` | architecture review | proved | component ownership and trust boundary recorded |
| Preserve Shepherd design | presentation PDF, HTML, and eight diagrams | `apps/`, `nix/`, `infra/`, `docs/architecture/` | full slide and diagram review | proved | Nix, cache, mesh, platform, console, and rollout paths recorded |

## Surface ledger

| Surface | Applies | Source | Required change | Check | State |
|---|---|---|---|---|---|
| Entry points | yes | Windows CLI, service, and elevated launcher | retain working relative paths | static path resolution | proved |
| Clients | yes | Windows device agent | move as one unit | module manifest and resource scan | proved |
| Providers | yes | PowerShell resource modules | remain beside the agent module | module import scan | proved |
| Contracts | yes | Windows plan and report schema | document future shared owner | link check | proved |
| Reverse state | yes | journal and resource reversal | no behavior change | source diff inspection | proved |
| Connection modes | yes | offline plan and future controller channel | preserve current behavior | source diff inspection | proved |
| Tests | yes | four Windows test tiers | repair agent and wrapper paths | static path resolution | proved |
| Documents | yes | Windows docs and academic artifacts | repair moved references | repository link scan | proved |

Branch: `main`. No commit, push, or pull request was requested.

Windows runtime tests were not run because this workspace is Linux. The file
layout, imports, links, JavaScript syntax, Python syntax, and presentation assets
were checked locally.
