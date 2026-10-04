# 09 — Deployment and recovery

## Draft → deployment lifecycle (server)

```text
Draft(editing)
  └─save→ Draft(evaluating) ──eval error──> Draft(invalid)  [CFG-05, DEM-04]
                │
                └─ok→ Draft(valid) ──admin approves (diff shown, destructive acked)──> Approval
                                                     [AGT-05: admin only]
Approval → merge draft branch into main (new config revision)
         → job build_generation (per platform × machine group)
              └─build/publish error──> Deployment(failed), no target change
         → Generation(s) ready
         → Deployment(rolling): dispatch per rollout policy
              per machine: finalize plan, sign, write machine_targets
         → Deployment(completed) when every targeted machine reports
           healthy, failed→recovered, or is offline beyond policy timeout
```

Rollout policy is configuration [DEP-07]: `{ strategy: "all-at-once" |
"batches", batchSize, pauseOnFailureCount, requireWindow: bool }`. No fixed
canary percentages are mandated. Default `[impl]`: all-at-once with
`pauseOnFailureCount = 1`. The policy and the computed schedule are shown
before the admin confirms [DEP-07].

## Per-machine generation states (from node reports)

```text
pending → fetching → activating → healthy (becomes last working)
                          │
                          └→ unhealthy/failed → recovering → recovered (last working re-activated)
                                                         └→ recovery-failed (alert; unrecovered effects listed)
```

`is_last_working` moves to a generation only after activation **and** health
checks succeed [DEP-05]. Superseded generations stay retained (GC root on
NixOS, generation bundle on Windows) while they are last working.

## Maintenance windows and reboots [DEP-04, DEP-07]

- Windows are RRULE-based, per profile/group/machine (most specific wins).
- `apply_after` in the target holds activation until the window opens; the
  node enforces it locally (it may already have fetched artifacts).
- Reboot only via `Reboot` instruction inside a window with `allow_reboot`;
  nodes never reboot on their own.
- Reconnecting offline nodes reconcile to the latest target but still respect
  windows [DEP-04].

## Drift and auto-fix [DEP-03, AGT-04]

1. Node runs drift passes (timer default 15 min in V1 for demo visibility,
   configurable; plus event triggers on Windows registry change notifications
   where cheap) using the observation side of every resource.
2. Drift report → `drift_findings` opened/updated/resolved.
3. If auto-fix is enabled (machine override ?? profile setting), the server
   issues a signed `Reapply{generation_id = current approved target}`. The
   node applies only drifted resources (or full plan — decide per platform;
   NixOS: re-run `switch-to-configuration switch` for the same closure).
4. Result is recorded as a `repair` report and an audit event.
5. Auto-fix never changes the target, never approves, never upgrades.
6. Node-local auto-fix (when offline): the daemon MAY reapply the last
   verified plan locally only if the last received signed policy says
   auto-fix enabled for this machine; it reports when back online `[impl]`.

## Recovery [DEP-05, DEP-06, DEM-06]

Triggers: activation failure, health check failure within `health.timeoutSec`,
daemon restart finding an `intent` journal entry without completion.

| Platform | Recovery mechanism | Guarantees |
|---|---|---|
| NixOS | Re-activate last working generation's closure (`switch-to-configuration switch` on its store path), set system profile back; bootloader default restored | System configuration restored; mutable data not restored (reported) |
| Windows | Reverse journal entries for the failed plan in reverse order (registry/env/service/firewall/account restorable), then re-apply last working plan for convergence | Per-provider: packages may not downgrade (reported as unrecovered), updates not reversible |
| macOS | Re-activate last working nix-darwin generation; MDM profiles: reinstall previous profile set | Partial; reported per effect |

The recovery report lists `unrecovered[]` with resource key, reason, and
suggested manual action [DEP-06].

## Offline [DEP-04, DEM-07]

- Node keeps last verified target and plan on disk, continues drift passes,
  queues reports (bounded, oldest drift reports dropped first, apply/recovery
  reports never dropped).
- Server marks the machine `offline` after the freshness window; console
  shows "last seen" and labels cached data as stale.
- On reconnect: heartbeat → target digest compare → fetch new target if
  changed → apply within window → flush queued reports (marked with original
  timestamps; server stores `received_at` separately).

## Profile switching [PRF-04, DEM-03]

Changing a machine's effective profile (direct assign/unassign, group change)
creates a **transition**: the console shows the transition plan (current
active vs new generation diff) and requires confirmation; dispatch then uses
the new profile's current approved generation. Assigned target, active
configuration, and transition result are shown as three separate fields.

## Acceptance

- State machine unit tests for every transition and illegal transition.
- DEM-02: drift visible with auto-fix off; turn on → repaired, recorded.
- DEM-06: injected failing health check on both platforms recovers to last
  working; unrecovered effects listed for Windows package install.
- DEM-07: disconnect VM network for > freshness window, change target, reconnect
  → node converges; console shows offline period and stale labels.
