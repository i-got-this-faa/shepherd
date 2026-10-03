# Fleet device agent for Windows

The Windows mapper agent: applies nix-evaluated JSON plans to a Windows
machine. Implements the [plan contract](../../../../docs/platforms/windows/plan-schema.md)
and the [Windows provider contracts](../../../../docs/platforms/windows/README.md).

## Layout

| File | Purpose |
|---|---|
| `FleetAgent.psm1` | Core: settings, journal (memory + JSONL on disk), plan validation, provider dispatch, execution, reports, drift, PReg codec, winget exit-code taxonomy |
| `Resources\*.ps1` | One provider file per surface: registry, policy, winget, service, task, update settings/scan/install, inventory, script |
| `fleet-agent-cli.ps1` | CLI: `run-once`, `audit`, `drift`, `status`, `install-service`, `uninstall-service`, `version` |
| `agent-service.ps1` | Service loop: applies new plans, runs a drift pass every 4 hours, never exits on error |
| `config.sample.json` | Settings template (state dir, journal path, server URL) |

## Provider contract

Each provider implements `Get-*State` (observation), `Set-*` (audit or
apply, returns an evidence line), and `Undo-*` (journal-driven reversal,
receives the whole journal entry). Providers throw `UNSUPPORTED: <reason>`
when the edition or context cannot do the work and `BLOCKED: <reason>` for
external gating; the executor maps both into the report taxonomy
(`applied / unchanged / drifted / failed / unsupported / blocked`).

## Engine decisions baked in

1. Group Policy: `auto` mode authors `Registry.pol` + bumps `GPT.ini` on
   Pro and higher, and writes policy values directly into the
   `SOFTWARE\Policies` hives on Home — the measured Home behavior
   ([group-policy.md](../../../../docs/platforms/windows/group-policy.md)) makes the policy engine unusable as a
   write path there.
2. Windows Update installs run only with an active maintenance window,
   register the Microsoft Update source for the search, exclude
   firmware/BIOS and `RebootBehavior >= 2` updates, deregister the source
   afterwards, and prefix evidence with `reboot-required:` when the machine
   needs a restart.
3. winget runs through the CLI with hard timeouts and full agreement flags;
   exit codes map through the documented taxonomy. In the SYSTEM service
   context the COM API replaces the CLI ([winget.md](../../../../docs/platforms/windows/winget.md)).
4. The journal records the previous state of every mutation, including
   whether a registry key pre-existed, so reversal removes keys the agent
   created and restores values it overwrote.

## Status

PowerShell 5.1 reference implementation, covered by
`tests\platform\windows\`. The native Rust/C# service (SCM signaling,
plan signature verification, COM winget)
builds on this contract; `config.sample.json` marks
`allowUnsignedPlans` as a pre-production gate.
