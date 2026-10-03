# Agent Runtime

How the Windows mapper agent is built, installed, secured, and operated.
The agent is one Windows service that talks to the control server over an
outbound-only channel.

## Service host

| Property | Value |
|---|---|
| Name | `fleet-agent` |
| Account | `LocalSystem` |
| Start type | Automatic (delayed) |
| Recovery | Restart after 60 s, three attempts, then reset after 1 day |
| Sessions | Session 0 only; never interacts with the desktop |
| Binary | One signed static executable (Rust with `windows-rs`, or C# with CsWin32) |

LocalSystem satisfies every elevation requirement in the surface documents:
machine hive registry writes, `Registry.pol` and GPT.ini management, machine
package scope, update installs, Defender and BitLocker reads, and the SCM
write path. A per-user run of the agent has fewer rights; every resource
document states what it needs and reports `unsupported` when the context is
insufficient.

## Network model

1. Outbound only. The agent initiates every connection to the control
   server. No inbound ports, no WinRM, no DCOM remoting. This keeps the
   machine's attack surface at zero new listeners.
2. Transport is HTTPS with certificate pinning to the server's public key.
3. The agent authenticates with an enrollment token issued once at
   enrollment, stored in the machine credential store, never in the journal
   or the logs.
4. Plans are signed by the server (Ed25519). The agent verifies the
   signature against the pinned server key before it parses the plan. An
   unsigned or invalid plan is discarded and reported.
5. Offline operation: the agent keeps the last verified plan and continues
   drift passes locally, queues reports, and retries the server with
   exponential backoff. It never executes a plan it cannot verify, and it
   never fetches packages while offline.

## Apply loop

One pass is: fetch plan, verify signature, evaluate mode, then per
resource: observe, decide, journal, mutate, verify, record. Rules:

1. Resource order is fixed: services and boot state first, packages
   second, configuration third, updates last. `dependsOn` edges may
   reorder within a class, never across classes.
2. Every mutation writes a journal entry before it writes state. The
   journal is the reversal source of truth. See [plan-schema.md](plan-schema.md).
3. Each resource runs under its `timeoutSec`. A timeout kills the
   operation's process tree (Job Object) and reports `failed` with the
   timeout as evidence.
4. An apply pass stops at the first `failed` resource unless the plan sets
   `continueOnError` per resource. `unsupported` and `blocked` never stop
   the pass; they are per-resource outcomes.
5. A reboot never happens inside the pass. Resources that require one set
   `rebootRequired` in the report; the control server schedules the reboot
   through the maintenance window and a `reboot` instruction.

## Drift pass

1. Default interval: 4 hours with jitter, matching the Windows Declared
   Configuration refresh model.
2. The pass runs the audit mode of every resource in the last applied plan
   and sends one report of `kind: drift`.
3. The agent does not self-correct beyond the plan. Re-apply is the
   control server's decision.
4. Drift detection supplements, not replaces, the registry change
   notifications and CIM eventing described in the surface documents.

## Journal and logs

1. Journal: `C:\ProgramData\Fleet\journal\`, append-only JSON lines,
   rotated monthly, ACL grants write to SYSTEM only and read to
   Administrators.
2. Logs: `C:\ProgramData\Fleet\logs\`, structured JSON lines, one file per
   day, 30-day retention. The agent also writes an application event log
   source `FleetAgent` for start, stop, crash, and apply-summary events, so
   existing event-based monitoring sees it.
3. No credential ever lands in the journal or the logs. Resources store
   secret references; the schema forbids secret-typed fields from
   serializing to disk.
4. Support bundle: a single command collects journal summary, last plan,
   last reports, and redacted logs, without raw state values.

## Enrollment and removal

1. Enrollment pairs the machine with the fleet: an operator runs the agent
   installer with a one-time enrollment code; the agent exchanges it for a
   machine token and pins the server key.
2. An unenrolled agent does nothing. It reports its presence once and then
   idles. This is the `does not apply` state from the surface ledger.
3. Removal: the uninstaller stops the service, deletes `C:\ProgramData\Fleet`,
   and leaves machine state untouched. The journal is exported to the
   server before deletion when the server is reachable.

## Update coordination

1. The agent exposes a `reboot` instruction that only runs inside a
   maintenance window the server declares.
2. Before any pass, the agent checks `ISystemInformation.RebootRequired`
   and the registry reboot markers, and reports them. A pending reboot
   pauses package and configuration applies until the machine restarts,
   because a mid-apply restart is the most common Windows failure mode.
3. Windows Update installs run only inside the window and only for
   `RebootBehavior` 0 and 1, never firmware outside an explicit
   operator-approved plan. See [windows-update.md](windows-update.md).

## Failure taxonomy

| Status | Meaning | Server action |
|---|---|---|
| `applied` | State changed and verified | Record |
| `unchanged` | State already matched | Record |
| `failed` | Operation attempted and did not converge | Alert, optionally reverse from journal |
| `unsupported` | Edition, SKU, or context cannot do it | Record once, do not retry |
| `blocked` | External interference (antivirus, file in use, policy) | Alert with the blocker named |

`unsupported` is cached per machine so the dashboard shows a real
capability map of the fleet instead of a wall of retries.

## Testing the agent

1. Every resource module ships with unit fixtures (a plan entry, an
   observed state, the expected result) and an integration probe guarded by
   an opt-in environment variable, mirroring the probe suites in
   `tools/probes/windows/`.
2. The probe suites in this repository are the manual acceptance harness:
   non-elevated surface checks, the elevated apply-and-reverse suite, and
   the Group Policy experiment.
3. A plan that contains all `audit` resources must be provably side-effect
   free. The integration tests assert no journal writes during audit runs.
