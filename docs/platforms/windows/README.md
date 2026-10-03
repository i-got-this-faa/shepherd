# Windows Mapper

The Windows mapper is the Windows provider for Fleet. Fleet authors one
declarative configuration in nix for all machines. NixOS applies the
configuration on Linux. nix-darwin applies it on macOS. The Windows mapper
applies it on Windows.

This document describes the mapper architecture. Each managed Windows surface
has its own document:

| Document | Surface | Scope |
|---|---|---|
| [assessment.md](assessment.md) | Design review | Verdict and risks for the mapper idea |
| [prior-art.md](prior-art.md) | Prior art | What Puppet, Ansible, Chef, Salt, DSC, Intune, and WinDC do, and what to borrow |
| [plan-schema.md](plan-schema.md) | Contracts | Versioned plan, report, and journal schemas |
| [agent-runtime.md](agent-runtime.md) | Runtime | Service host, network model, apply loop, journal, security |
| [evidence.md](evidence.md) | Test evidence | Full result matrices from the probe suites |
| [winapi.md](winapi.md) | Win32 API | The substrate the mapper runs on |
| [registry.md](registry.md) | Registry | Machine and user configuration state |
| [group-policy.md](group-policy.md) | Group Policy | Policy declarations and their files |
| [winget.md](winget.md) | winget | Package install, upgrade, and removal |
| [wmi.md](wmi.md) | WMI and CIM | Inventory and device control |
| [windows-update.md](windows-update.md) | Windows Update | Patches, drivers, and deferrals |
| [surface-ledger.md](surface-ledger.md) | Ledger | Applicability of every surface with evidence |

## Apply and audit modes

Every resource ships with two modes, following the pattern Azure machine
configuration proved at fleet scale:

1. `audit`. The agent compares live state with the plan and reports the
   difference without writing. Rollout of a new plan defaults to audit.
2. `apply`. The agent converges the machine to the plan. The control server
   flips a resource from audit to apply per fleet, per ring.

The drift pass is the audit mode run on a schedule.

## Pipeline

The mapper has three stages. The same stage boundaries exist on all three
operating systems.

1. Evaluate. The control server runs `nix eval` on the fleet configuration and
   produces a plan. The plan is a JSON document that describes desired state.
   Nix never runs on Windows. The agent receives JSON, not nix.
2. Apply. The mapper agent on the machine reads the plan, observes the current
   state, computes the difference, and applies the smallest set of operations.
   Each operation targets one surface through one provider.
3. Report. The agent writes a result for each operation to a journal and sends
   a report to the control server. The dashboard reads the reports.

The plan and the report are the two contracts that cross the network. Both
sides version them.

## Structure of one plan entry

Each plan entry names one resource. A resource is one idempotent unit of
desired state. The mapper ships one resource module per surface.

```json
{
  "resource": "registry.value",
  "id": "HKLM\\SOFTWARE\\Fleet\\TelemetryEnabled",
  "ensure": "present",
  "data": { "type": "REG_DWORD", "value": 1 }
}
```

The agent applies resources in a fixed order: boot and service state first,
packages second, configuration third, updates last. This order exists because
a package install can overwrite configuration, and an update can restart the
machine.

## State and reversal

NixOS gives each generation an atomic switch and a rollback. Windows has no
equivalent. The registry, packages, and policy files are mutable, and the
operating system shares that state with every other program. The mapper
compensates with four rules instead of immutability:

1. Every resource is idempotent. Applying the same plan twice changes nothing
   the second time.
2. The agent journals every operation before it applies it. The journal entry
   contains the observed previous state.
3. The agent reverses a failed apply from the journal, in reverse order.
4. The agent detects drift. A periodic observation pass compares live state
   with the last applied plan and reports the difference.

## Service context rules

The agent runs as a Windows service in the SYSTEM account. Two context rules
prevent the most common Windows configuration mistakes:

1. `HKEY_CURRENT_USER` in a SYSTEM process is not the logged-in user's hive.
   The agent loads or addresses each user hive explicitly. See
   [registry.md](registry.md).
2. Machine-wide policy and updates need elevation. The agent holds SYSTEM
   rights, so its operations do not need a separate elevation prompt. An
   interactive user run of the mapper has fewer rights. Each surface document
   states its elevation requirement.

## Edition limits

Fleet targets Windows 10 and 11 Pro, Enterprise, and Education first. Home
editions lack the full Group Policy engine and some WMI providers. Each
surface document states the edition limit. The test evidence in this document
set came from a Windows 11 Home machine, so Home-only gaps are marked in the
surface documents.
