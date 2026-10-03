# Windows Update Surface

Windows Update is the servicing system for the operating system, drivers, and
Microsoft components. The mapper does not apply updates itself. It declares
update policy, triggers scans, and reports update state. The operating system
servicing stack does the rest.

## What the mapper maps

| Plan intent | Operation | Mechanism |
|---|---|---|
| Read update history | Query history | COM `Microsoft.Update.Session`, `CreateUpdateSearcher`, `QueryHistory` |
| Scan for applicable updates | Online search | COM `IUpdateSearcher.Search("IsInstalled=0")` |
| Approve and install | Download and install | COM `IUpdateDownloader`, `IUpdateInstaller` in the service context |
| Report reboot state | Query | `ISystemInformation.RebootRequired` |
| Pin an OS release | Policy value | `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` with `ProductVersion` and `TargetReleaseVersion` |
| Defer feature or quality updates | Policy values | `WindowsUpdate\AU` policy keys, deferral values |
| Set active hours | Registry or policy | `UX\Settings` values |
| Trigger a scan on demand | Orchestrator call | `UsoClient StartScan` |

## The COM session, step by step

The supported automation path is the COM API behind Windows Update Agent:

1. Create `Microsoft.Update.Session`.
2. Call `CreateUpdateSearcher()`. The searcher reads history and runs
   searches. `GetTotalHistoryCount()` and `QueryHistory(0, count)` return the
   update history without elevation.
3. `Search("IsInstalled=0 and Type='Software'")` returns the applicable
   updates. Search is read-only but contacts the service.
4. Download and install run through `CreateUpdateDownloader()` and
   `CreateUpdateInstaller()`. Both need elevation. The mapper runs them in
   the service context and time-boxes them; an install can take hours.
5. `ISystemInformation::get_RebootRequired` reports whether a reboot is
   pending. The agent reports this flag on every pass.

## Policy for fleet control

The control layer steers updates through policy, not through the installer.
The confirmed registry contract for feature-update pinning lives under
`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`:

| Value | Type | Effect |
|---|---|---|
| `ProductVersion` | `REG_SZ` | `Windows 11` or `Windows 10` |
| `TargetReleaseVersion` | `REG_DWORD` | `1` enables the pin |
| `TargetReleaseVersionInfo` | `REG_SZ` | The release line, for example `23H2` |

Further policy values in the same key and its `AU` subkey:

1. `DeferFeatureUpdates` and `DeferFeatureUpdatesPeriodInDays`, and the
   quality-update equivalents, set deferral windows.
2. `NoAutoRebootWithLoggedOnUsers` and `AlwaysAutoRebootAtScheduledTime`
   under `AU` control reboot behavior for interactive sessions.
3. `ExcludeWUDriversInQualityUpdate` separates driver servicing.
4. `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` holds active hours
   and pause state for the interactive experience.

The mapper writes these through the registry surface; the update surface
observes and reports the effect. Server-side, the Windows Update for
Business Deployment Service (driven through Microsoft Graph) can orchestrate
expedited feature and driver deployments for a fleet; it is a control-server
capability, not an agent capability. WSUS is deprecated with no replacement
in Windows Server 2025, so the deployment service and the policy keys are
the durable paths.

## The orchestrator

`UsoClient.exe` drives the Update Session Orchestrator. `StartScan`,
`StartDownload`, and `StartInstall` exist but Microsoft documents
`UsoClient` as unsupported for automation. The mapper uses it only for a
non-interactive scan trigger, and treats a failure as non-fatal. Empirical
evidence: on the test machine, `UsoClient StartScan` produced a new event in
the `Microsoft-Windows-WindowsUpdateClient/Operational` log within seconds,
which is how the agent verifies that a scan actually ran.

## Reboot discipline

The update surface is the only surface that reboots the machine. Rules:

1. The agent checks `RebootRequired` before every apply pass and reports it.
   `ISystemInformation.RebootRequired` is the COM check; the registry
   equivalents are `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto
   Update\RebootRequired`, `Component Based Servicing\RebootPending`, and
   `PendingFileRenameOperations`.
2. A plan that contains updates runs in a declared maintenance window.
3. The agent never forces a reboot outside the window. The report states the
   pending reboot and the dashboard shows it.
4. The agent reports reboots as structured output and never reboots on its
   own initiative. This follows the convention proven by Ansible's Windows
   modules: the operation returns `reboot_required`, and the orchestrator
   schedules it.

## Install gating

The COM installer marks every update with `InstallationBehavior.RebootBehavior`:
`0` never reboots, `1` can request a reboot, `2` must reboot. The mapper
installs only `RebootBehavior` 0 and 1 updates outside a declared firmware
plan, and never firmware or BIOS titles unattended. Empirical evidence from
the test machine: the default Windows Update source offered only two
reboot-forcing updates (a MediaTek ADB driver and an HP firmware driver).
Registering the Microsoft Update source through
`IUpdateServiceManager.AddService2` with the service id
`7971f918-a847-4430-9279-4a52d1efe18d` widened the set with a Defender
Security Intelligence update (`KB2267602`, `RebootBehavior=0`), which the
probe then downloaded and installed for real: `IUpdateDownloader.Download()`
and `IUpdateInstaller.Install()` both returned result code 2 (Succeeded)
with HResult 0, and `RebootRequired` stayed `False`. The registration is
reversible with `RemoveService`; fleet machines keep it enabled by policy
since it is the same source enterprises use for Office updates.

## Elevation and editions

History, settings reads, and searches work without elevation. Download,
install, and policy writes need elevation. All editions support Windows
Update; deferral policy values are honored on Pro and higher. Test machine
evidence: `CreateUpdateSearcher().GetTotalHistoryCount()` returned `201`
entries, non-elevated, Windows 11 Home.

## Verify

Read-only checks that prove the surface is reachable.

```powershell
$s = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$s.GetTotalHistoryCount()
(New-Object -ComObject Microsoft.Update.AutoUpdate).Settings |
  Select-Object NotificationLevel
```

Elevated evidence from the test machine: an online search through
`IUpdateSearcher.Search("IsInstalled=0 and IsHidden=0")` returned the
applicable set with titles and sizes; `usoclient StartScan` produced a new
operational-log event; the `TargetReleaseVersion` policy triple was written,
read back, and removed cleanly; and a Defender Security Intelligence update
was downloaded and installed through the COM installer (result code 2) with
no pending reboot afterwards.
