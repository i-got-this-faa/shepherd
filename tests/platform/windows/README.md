# Fleet Windows mapper test suite

The layered test suite for the Windows mapper. It tests the reference
executor, a PowerShell implementation of the
[plan schema](../../../docs/platforms/windows/plan-schema.md), as a black
box through real machine state, using the same contracts the production
agent will implement.

## How to run

```powershell
tests\platform\windows\run.ps1                    # unit + integration + system (non-elevated)
tests\platform\windows\run.ps1 -ElevatedOnly      # spawn the elevated tier (one UAC prompt)
tests\platform\windows\run.ps1                    # re-run to merge elevated results
```

Exit code 0 means nothing failed. Status words: `PASS`, `FAIL`,
`UNSUPPORTED` (a resource cannot run in this edition or context — verified
documented behavior, not a skip), `PENDING` (the elevated tier has not run
yet).

## Layers

| Tier | File | What it tests |
|---|---|---|
| unit | `unit\unit.tests.ps1` | PReg codec round-trip and malformed input, plan schema validation (versioning, HKCU ban, dependsOn resolution and cycles), winget exit-code taxonomy, journal counting |
| integration | `integration\integration.tests.ps1` | Apply/verify/reverse triples on per-user registry state, audit purity, idempotency, drift detection, journal-driven reversal, failure taxonomy in a non-elevated context |
| system | `system\system.tests.ps1` | A whole plan document: audit → apply → idempotent re-apply → out-of-band drift → repair → reversal; dependsOn execution order proven by a marker file; report schema conformance |
| elevated | `elevated-runner.ps1` | The same triples where the context matters: HKLM writes, service state, update policy keys, scheduled tasks, the winget install/upgrade/uninstall lifecycle with exit-code mapping |

## Design rules

1. Every mutating test is a triple: apply → verify → reverse → verify the
   reversal. The journal is the reversal source of truth.
2. Idempotency is asserted, not assumed: a second apply must report
   `unchanged` and add zero journal entries. Audit runs must add zero
   entries and change nothing.
3. Tests verify state through a different path than the write (write via
   the executor, read via `Get-ItemProperty` or `reg.exe`).
4. Every external call is time-boxed; a hang is a failure with evidence.
5. `UNSUPPORTED` is a first-class result: a resource that cannot run in the
   current edition or context reports it with a reason, and the suite
   counts it as verified behavior.
6. Tests own synthetic targets only (`FleetTest` key prefixes, probe
   services and tasks, a candidate-selected probe package) and tear down in
   `finally` semantics even on failure.

## What the reference executor implements

`FleetTest.psm1` contains a walking skeleton of the mapper: plan
validation, topological ordering by `dependsOn`, audit and apply modes,
journal-before-write, journal reversal, and resource handlers for
`registry.value`, `service.state`, `update.settings`, `script.fleet`, and
`inventory.report`. The remaining handlers report `unsupported` with a
reason and are exercised by the elevated tier directly. When the production
agent exists, these tests target it through its own CLI instead.

## Evidence

Probe-suite evidence (the six Windows surfaces, elevated operations, and
the two findings) lives in
[Windows evidence](../../../docs/platforms/windows/evidence.md).
