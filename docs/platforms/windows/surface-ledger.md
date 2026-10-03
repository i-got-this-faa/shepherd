# Surface Ledger — Windows Mapper

The `hit-every-surface` skill applied to the behavior: "one nix-authored
plan configures a Windows machine through the mapper". Each row states
whether the surface applies, the source of the decision, the required
change, the check that proves it, and the state.

| Surface | Applies | Source | Required change | Check | State |
|---|---|---|---|---|---|
| Entry points: nix configuration module | applies | The fleet config is the single authoring surface | Document the plan contract shape | README.md "Pipeline" | done |
| Entry points: mapper agent service | applies | The service is the only writer on the machine | Define service context rules | README.md "Service context rules" | done |
| Entry points: mapper CLI | applies | An operator run without the service | Note reduced-rights context | README.md "Service context rules" | done |
| Clients: control server | applies | Evaluates nix, signs and ships plans | Plan schema versioning | README.md "Pipeline" | done |
| Clients: dashboard | applies | Reads reports and drift | Report schema feeds the dashboard | wmi.md "Relevance to the fleet dashboard" | done |
| Providers: registry | applies | Primary state store | Resource module + journal | registry.md | done |
| Providers: group policy | applies with edition limits | Home: the policy core filters out the local GPO (operational log events 5312 and 5313) | Edition-aware resources; direct Policies-hive writes on Home; GPT.ini and History management on Pro+ | group-policy.md, evidence.md | done |
| Providers: winget | applies where App Installer exists | Absent on Server/LTSC by default | Availability check before apply | winget.md | done |
| Providers: WMI and CIM | applies | Inventory backbone | Query set + inventory of record | wmi.md | done |
| Providers: Windows Update | applies | Servicing owner | Policy + COM probes, reboot rules; full search/download/install cycle proven on a Defender definition update | windows-update.md, evidence.md | done |
| Providers: Win32 API | applies | Substrate, fixed API set | Allowed-API table | winapi.md | done |
| Contracts: plan JSON | applies | Crosses server → agent boundary | Versioned schema; entry shape documented | README.md "Structure of one plan entry" | done |
| Contracts: report and journal | applies | Crosses agent → server boundary | Journal-before-write rule; report carries surface, result, evidence | README.md "State and reversal" | done |
| Reverse state: registry rollback | applies | Journal holds previous value | Reverse from journal in reverse order | registry.md back up section | done |
| Reverse state: package removal | applies | `winget uninstall` is the reverse | Exit code recorded | winget.md | done |
| Reverse state: update rollback | applies with limits | Windows owns OS rollback | Mapper never rolls back OS updates; reports state | windows-update.md | done |
| Reverse state: policy removal | applies | Delete the Registry.pol entry | Documented under the policy table | group-policy.md | done |
| Connection modes: enrolled and online | applies | Normal operation | Apply and report immediately | README.md | done |
| Connection modes: offline | applies | A machine works without the server | Apply last plan? No: hold last plan, queue reports; no new plans while offline | README.md "Pipeline" | done |
| Connection modes: unenrolled | does not apply | No plan, no trust | The agent runs observations only when unenrolled | README.md | done |
| Tests: surface probes | applies | Each documented verify command must run | tools/probes/windows/test-windows-surfaces.ps1 | See "Test evidence" below | done |
| Tests: document integrity | applies | Docs must exist and match the probes | The probe script checks anchors | See "Test evidence" below | done |
| Documents: this set | applies | Eight documents cover the six surfaces plus architecture and ledger | docs/platforms/windows/* | The probe script verifies presence | done |

## Resolved unknowns

1. Does `HKCU` work for the agent? No. SYSTEM context resolves `HKCU` to the
   SYSTEM account. Resolved by forbidding `HKCU` in plans and addressing
   hives by SID (registry.md).
2. Does the mapper need nix on the machine? No. Nix evaluates on the control
   server; the agent consumes JSON (README.md). Confirmed by the nix-on-
   Windows survey in assessment.md: nix does not run natively on Windows.
3. Can the machine keep a read-only root filesystem? No. Resolved as a
   design correction with journal-based guarantees (assessment.md). The
   only real read-only mechanism, Unified Write Filter, exists on
   Enterprise, Education, and IoT Enterprise only.
4. Does the policy engine accept out-of-band Registry.pol writes on Home?
   Not reliably. One first-time application succeeded; three controlled
   re-applications failed. Measured in evidence.md; the Home contract is
   direct Policies-hive writes.

## Test evidence

Probe suites: `tools/probes/windows/test-windows-surfaces.ps1` (non-elevated: 23 pass,
0 fail, 5 stated skips) and `tools/probes/windows/test-windows-elevated.ps1` (elevated:
31 pass, 1 documented fail, 1 gated skip), plus
`tools/probes/windows/test-gptini-experiment.ps1`. Evidence level: real runtime probes,
Windows 11 Home (build 26200), PowerShell 5.1, workgroup machine, UAC
elevation through a hidden window with transcripts. Full matrices and the
two open findings are in [evidence.md](evidence.md). Not exercised:
installing a reboot-forcing update (the machine's applicable set contained
only driver and firmware updates; gated to a maintenance window) and the
Pro-edition policy engine path (this machine is Home).
