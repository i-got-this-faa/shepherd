# WMI and CIM Surface

WMI is the Windows instrumentation layer. The mapper uses it for inventory
and for state that has no registry or file representation. The modern
interface is CIM. `wmic.exe` was deprecated in Windows 10 21H1, removed by
default in Windows 11 24H2, and per the September 2025 servicing note it is
now fully removed including the Feature on Demand. The agent must never
depend on it.

## Namespace map for the agent

| Namespace | Classes | Purpose | Elevation |
|---|---|---|---|
| `root\cimv2` | `Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_BIOS`, `Win32_SystemEnclosure`, `Win32_Processor`, `Win32_PhysicalMemory`, `Win32_LogicalDisk`, `Win32_Service`, `Win32_Process`, `Win32_QuickFixEngineering` | Core hardware and OS inventory | Reads: none. Methods: admin or SYSTEM |
| `root\StandardCimv2` | `MSFT_NetAdapter`, `MSFT_NetIPAddress`, `MSFT_NetTCPConnection` | Network state | Reads: none |
| `root\Microsoft\Windows\Defender` | `MSFT_MpComputerStatus`, `MSFT_MpPreference`, `MSFT_MpScan` | Antivirus state and scans | Status read: none. Scan start: admin |
| `root\cimv2\Security\MicrosoftVolumeEncryption` | `Win32_EncryptableVolume` | BitLocker state | Admin and an encrypted connection for methods |
| `root\cimv2\Security\MicrosoftTpm` | `Win32_Tpm` | TPM presence and state | Methods: admin |
| `root\CIMV2\Applications\WindowsInventory` | `Win32_InstalledWin32Program`, `Win32_InstalledStoreProgram` | Safe software inventory | None |
| `root\Microsoft\Windows\WindowsUpdate` | `MSFT_WUOperations` | Update scan and install | Treat as opportunistic; unstable across builds |
| `root\cimv2\mdm\dmmap` | `MDM_Policy_*`, `MDM_WindowsLicensing`, and other `MDM_*` classes | MDM Bridge to configuration service providers | SYSTEM for device scope |

The MDM Bridge namespace is `root\cimv2\mdm\dmmap` (provider
`DMWmiBridgeProv`); the `mdm\mdmbridge` name seen in older notes is wrong.
Each `MDM_*` class instance maps to one configuration service provider URI
through its `ParentID` and `InstanceID` keys. Device-scope CSP calls require
the SYSTEM context; per-user CSP targeting needs MI custom options that the
PowerShell CIM cmdlets do not expose. Many CSPs only take effect on an
MDM-enrolled device, so the mapper treats the bridge as a secondary path on
Pro and higher.

## What the mapper maps

| Plan intent | Operation | Notes |
|---|---|---|
| Operating system inventory | Query `Win32_OperatingSystem` | `Caption`, `Version`, `BuildNumber` |
| Hardware identity | Query `Win32_ComputerSystem`, `Win32_BIOS`, `Win32_SystemEnclosure` | Enclosure serials are often vendor placeholders; combine three sources |
| Disk and volume state | Query `Win32_LogicalDisk` | Filter `WHERE DriveType=3` for fixed disks |
| Defender state | Query `MSFT_MpComputerStatus` | Read-only, works non-elevated |
| Defender scan | `Invoke-CimMethod MSFT_MpScan Start` | `ScanType`: 1 quick, 2 full, 3 custom with `ScanPath` |
| BitLocker state | `Get-BitLockerVolume` or `Win32_EncryptableVolume` | Full management needs Pro and higher; see below |
| Device or service action | `Invoke-CimMethod` on the class | `Win32_Process.Create` returns 0 on success |
| React to a state change | Temporary CIM indication | See the eventing rules |

## Inventory of record

The inventory of record for installed software is the registry uninstall
keys, not WMI:

1. `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
2. `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`
3. `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` per user

Reason: `Win32_Product` is not query optimized. Every enumeration runs a
Windows Installer consistency check of every package: it reconfigures
products, writes Application log events 1033 and 1035, and spikes
`WmiPrvSE` CPU. The mapper never queries `Win32_Product`.
`Win32_InstalledWin32Program` in the WindowsInventory namespace is the safe
WMI alternative; it does not trigger MSI reconfiguration. It complements the
uninstall keys; it does not replace them.

## OS version detection

Version detection must not use `ProductName` or `Caption` alone:

1. Registry `ProductName` still reports `Windows 10 ...` on Windows 11
   machines. Confirmed on the test machine: it reports `Windows 10 Home
   Single Language` on a Windows 11 Home installation.
2. `Win32_OperatingSystem.Version` reports `10.0` on both Windows 10 and 11.
3. `DisplayVersion` is identical across Windows 10 21H2 and Windows 11 21H2.
4. The reliable fingerprint: build number at least 22000 means Windows 11.
   Compute `osVersion = major.minor.build.UBR` from `BuildNumber` plus the
   registry `UBR` value under `CurrentVersion`. `UBR` is also the patch
   level; `Win32_QuickFixEngineering` lists only Component Based Servicing
   updates and can contain duplicates or localized dates.

## Eventing rules for drift detection

1. Use temporary subscriptions in the agent process. Never create permanent
   subscriptions (`__EventFilter` plus `__CommandLineEventConsumer` plus
   `__FilterToConsumerBinding`). That triple is the MITRE ATT&CK T1546.003
   persistence fingerprint, runs as SYSTEM through `WmiPrvSE`, and gets
   flagged by antivirus and EDR tools.
2. `WITHIN` polling intervals under 300 seconds are not recommended by
   Microsoft; they are resource intensive and can be rejected. For a
   long-running service, prefer the agent's own timer loop over WMI polling.
3. The agent can audit `root\subscription` read-only and report malicious
   permanent subscriptions found on the host. That is a valuable drift
   signal.

## Remote management

The agent does all CIM work locally in-process. It does not open WinRM or
DCOM:

1. WinRM uses ports 5985 (HTTP) and 5986 (HTTPS); client SKUs have no
   listener until `winrm quickconfig` runs. Workgroup TrustedHosts
   authentication is unauthenticated NTLM, which the docs warn about.
2. DCOM remoting uses TCP 135 plus dynamic RPC ports 49152 to 65535, which
   is firewall hostile.
3. `Win32_Process.Create` cannot start an interactive process remotely, and
   remote children are bound to a job object.
4. `New-CimSession` with `-OperationTimeoutSec` under 180 seconds makes
   network failures unrecoverable per the documented retry behavior.
5. CimSession objects have runspace affinity; they cannot cross
   `ForEach-Object -Parallel` blocks.

The control server pushes plans to the agent's own authenticated channel.
WMI remoting stays off by default, which keeps the attack surface small.

## PowerShell version discipline

The WMI cmdlets (`Get-WmiObject`, `Invoke-WmiMethod`, `Register-WmiEvent`)
are removed in PowerShell 7. The agent uses only the CIM cmdlets or its
language's native CIM bindings. The BitLocker and TrustedPlatformModule
modules are Windows PowerShell oriented; an agent that embeds PowerShell 7
must call the underlying namespaces directly. The mapper's own Rust or C#
bindings call the CIM COM infrastructure, which works identically on both
PowerShell generations.

## Elevation and editions

Most `root\cimv2` reads work without elevation. Defender scan start,
BitLocker methods, TPM methods, and `Confirm-SecureBootUEFI` need admin or
SYSTEM rights; the service context provides them. On the test machine
(Windows 11 Home, elevated): `MSFT_MpComputerStatus` read succeeded,
`Get-BitLockerVolume` returned `C: Off` (status readable on Home through
device encryption; full BitLocker management is Pro and higher),
`Get-Tpm` returned `TpmPresent=True, TpmReady=True`, `Confirm-SecureBootUEFI`
returned `False`, and a `Win32_Process.Create` method call returned 0. Five
hotfixes were listed through `Win32_QuickFixEngineering`, latest `KB5124008`.

## Resilience rules

1. Probe namespace availability with `Get-CimClass` before the first real
   query; report `unsupported` for a missing namespace instead of failing.
2. Wrap every query with a timeout. Degrade to the registry uninstall keys
   when the WindowsInventory agent has not refreshed.
3. Ship the break-glass sequence as an agent diagnostic:
   `winmgmt /verifyrepository`, then `/salvagerepository`, then
   `/resetrepository` as the last resort with consent and logging.

## Verify

Read-only checks that prove the surface is reachable.

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model
Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter |
  Select-Object Name, InterfaceDescription
Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
  -Arguments @{ CommandLine = 'cmd /c exit 0' }
```

All four ran on the test machine, the last one elevated, with `ReturnValue 0`.
