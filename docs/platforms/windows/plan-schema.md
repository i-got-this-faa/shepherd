# Plan and Report Schemas

The two contracts that cross the network between the control server and the
Windows agent. Both documents are versioned JSON. The same envelope serves
all three operating systems; only the resource modules differ per platform.

## Versioning rules

1. `planVersion` and `reportVersion` are major integers. A major bump is a
   breaking change; an agent rejects a plan with a different major version
   and reports it.
2. Unknown fields inside a known major version are ignored. Producers may
   add minor fields without a version bump.
3. Every schema change ships with a fixture document under the agent test
   suite before it ships to any machine.

## Plan document

```json
{
  "planVersion": 1,
  "planId": "uuid",
  "fleetId": "uuid",
  "machineId": "uuid",
  "createdAt": "RFC3339",
  "applyAfter": "RFC3339 or null",
  "expiresAt": "RFC3339",
  "mode": "audit",
  "resources": [ ]
}
```

`mode` is plan-level default: `audit` or `apply`. A plan in audit mode
changes nothing on the machine regardless of resource fields. `applyAfter`
supports maintenance windows; the agent holds the plan until that instant.

## Resource envelope

Every entry in `resources` carries this envelope. The payload shape is
owned by the named resource module.

```json
{
  "resource": "registry.value",
  "id": "HKLM\\SOFTWARE\\Fleet\\TelemetryEnabled",
  "mode": "apply",
  "ensure": "present",
  "data": { },
  "dependsOn": [ "package.winget:7zip.7zip" ],
  "timeoutSec": 300,
  "rebootBehavior": "report"
}
```

1. `resource` is `provider.module`, one module per surface.
2. `id` is stable and human-readable; it is the join key for reports,
   journal entries, and the dashboard.
3. `mode` overrides the plan-level default per resource.
4. `dependsOn` lists resource ids that must report success first. The agent
   rejects a plan with a dependency cycle or an unknown id.
5. `rebootBehavior` is `report` (default) or `allow` for the maintenance
   window flow. The agent never reboots on `report`.

## Resource modules and payloads

| Module | Payload fields | Elevation | Reversal |
|---|---|---|---|
| `registry.value` | `path`, `value`, `type` (REG_SZ, REG_EXPAND_SZ, REG_MULTI_SZ, REG_DWORD, REG_QWORD, REG_BINARY), `view` (64 or 32), `userSid` for per-user hives | machine: SYSTEM; per-user: that user | journal holds the previous data |
| `registry.key` | `path`, `ensure`, `view`, `userSid` | same | journal holds the previous subkeys |
| `policy.setting` | `admxId`, `scope` (machine or user), `state` (enabled, disabled, notConfigured), `elements` | Pro and higher for Registry.pol | journal holds the previous Registry.pol record |
| `package.winget` | `packageId`, `version` or `latest`, `scope` (machine or user), `source` (winget) | machine scope: SYSTEM, through the COM API (the CLI is unsupported as SYSTEM; see winget.md) | uninstall on reverse |
| `service.state` | `name`, `startupType`, `status`, `account` | SYSTEM | journal holds previous config |
| `task.scheduled` | `path`, `name`, `action`, `trigger`, `ensure` | SYSTEM | unregister on reverse |
| `update.settings` | `targetReleaseVersion`, `targetReleaseVersionInfo`, `productVersion`, `deferralDays`, `activeHours` | SYSTEM | journal holds previous values |
| `update.scan` | none; triggers a scan and reports | none for scan | no state change |
| `update.install` | `classifications`, `maxSizeMB`, `excludeTitles` | SYSTEM, maintenance window only | not reversible; Windows owns OS rollback |
| `inventory.report` | none; the audit pass over the whole machine | none | no state change |
| `script.fleet` | `content`, `runAs`, `expectedExitCodes` | per runAs | none; marked non-convergent and reported as such |

Rules that hold for every module:

1. `ensure: absent` and `ensure: present` are the only state words.
2. An unsupported combination (for example `policy.setting` on Home) does
   not fail the plan. The resource reports `unsupported` with the reason.
3. A blocked resource (antivirus interference, file in use) reports
   `blocked` and names the blocker.
4. Unknown `resource` names report `unsupported`. The agent never skips a
   resource silently.

## Report document

The agent sends one report per plan execution and one per drift pass.

```json
{
  "reportVersion": 1,
  "planId": "uuid",
  "machineId": "uuid",
  "kind": "apply",
  "startedAt": "RFC3339",
  "finishedAt": "RFC3339",
  "rebootRequired": false,
  "results": [
    {
      "resourceId": "registry.value:HKLM\\SOFTWARE\\Fleet\\TelemetryEnabled",
      "status": "applied",
      "evidence": "REG_DWORD 1 written and read back",
      "errorCode": null,
      "journalId": "uuid",
      "durationMs": 41
    }
  ]
}
```

`kind` is `apply`, `drift`, or `inventory`. `status` is one of `applied`,
`unchanged`, `failed`, `unsupported`, `blocked`. `evidence` is a short
human-readable string with the observed fact, not a log dump. Long output
goes to the journal; the report references it by `journalId`.

## Journal entry

The journal is local, append-only, and written before every mutation.

```json
{
  "journalId": "uuid",
  "timestamp": "RFC3339",
  "planId": "uuid",
  "resourceId": "policy.setting:Wi-Fi.PasswordPolicy",
  "operation": "set",
  "previousState": { },
  "newState": { },
  "reversed": false
}
```

1. The agent writes the entry, performs the operation, then updates the
   entry with the outcome.
2. Reversal walks the journal backwards for the plan and replays
   `previousState`. Each reversed entry is marked.
3. The journal carries no secrets. Values that contain credentials are
   stored as references, never as plain text.

## Drift pass

A drift pass runs the audit mode of every resource in the last applied plan
on a schedule (default 4 hours, matching WinDC's refresh). It produces a
report of `kind: drift` listing every resource whose live state no longer
matches the plan. The control server decides between re-apply and alert;
the agent does not self-correct beyond the plan.
