# Win32 API Surface

The Win32 API is not a fleet resource by itself. It is the substrate every
other provider calls. This document fixes the API set the mapper is allowed
to use, so the binding surface stays small and auditable.

## Implementation choice

The mapper agent is a native Windows service. Two viable stacks:

1. Rust with the `windows-rs` crates. Microsoft maintains the bindings from
   Windows metadata. Preferred for a single static service binary.
2. C# with .NET and the `CsWin32` source generator. Faster to build; needs
   the .NET runtime or self-contained publishing.

Either way, every API call sits in one module per surface. The rest of the
agent depends on typed surface modules, never on raw P/Invoke.

## The allowed API set

| Area | API group | Used by |
|---|---|---|
| Registry | `RegOpenKeyEx`, `RegQueryValueEx`, `RegSetValueEx`, `RegDeleteValue`, `RegCreateKeyEx`, `RegDeleteTree`, `RegEnumValue`, `RegNotifyChangeKeyValue`, `RegSaveKeyEx`, `RegLoadKey`, `RegRestoreKey` | Registry surface |
| Services | `OpenSCManager`, `OpenService`, `QueryServiceStatus`, `StartService`, `ChangeServiceConfig` | Service state resources |
| Processes and jobs | `CreateProcess`, `OpenProcess`, `TerminateProcess`, `WaitForSingleObject`, Job Objects | Installer time-boxing, child processes |
| Privileges and tokens | `OpenProcessToken`, `AdjustTokenPrivileges`, `LookupAccountSid` | Service context checks, SID handling |
| Files and ACLs | `CreateFile`, `GetSecurityInfo`, `SetSecurityInfo`, `SetNamedSecurityInfo` | Policy file writes, ACL resources |
| Computer and version identity | `GetComputerNameEx`, `VerifyVersionInfo` | Inventory, edition checks |
| Restart Manager | `RmStartSession`, `RmRegisterResources`, `RmGetList` | File-in-use detection before a write |
| Event log | `EvtQuery`, `EvtRender` | Failure diagnostics in reports |
| Task Scheduler | `ITaskService` COM | Maintenance windows, refresh triggers |

Everything else needs a review note in this document before the agent calls
it. The list exists to keep the audit surface small.

## Patterns the agent must follow

1. Every handle closes through a guard type. `CloseHandle`, `RegCloseKey`,
   and `CloseServiceHandle` belong to RAII wrappers, not to code paths.
2. Every system call that can fail checks the error and the agent maps the
   error to a report result. No call passes silently.
3. Buffer-size calls run twice: query the size, allocate, call again. This is
   the standard pattern for `GetComputerNameEx`, `RegQueryValueEx`, and the
   security APIs.
4. The agent never loads a DLL dynamically for an allowed API. Static
   bindings keep the import table auditable.

## Evidence from the probe suite

The elevated probe run exercised four of these API areas on the test machine
through their nearest CLI or .NET boundary:

1. Service control: `OpenSCManager`-family operations through `sc.exe`.
   The probe created a service, queried it, started it, and deleted it; the
   query after deletion returned error 1060, which proves the full SCM
   lifecycle. A service whose binary is not a real service binary stops
   immediately, which is the expected observation for the probe's
   `cmd.exe` binary.
2. Task Scheduler: the probe registered a task under the root folder,
   started it, read `LastTaskResult` (0), unregistered it, and confirmed
   removal. Note: `Register-ScheduledTask` needs an existing task path, so
   the mapper creates folders explicitly or uses the root.
3. Files and ACLs: the probe removed inheritance from a throwaway file's
   descriptor, applied an explicit ACE, verified the protection flag, and
   removed the file.
4. Identity: `GetComputerNameEx` returned the DNS hostname that matches
   `$env:COMPUTERNAME`.

## Transactional caveat

`RegCreateKeyTransacted` and filesystem transactions (TxF) are deprecated.
The mapper does not use them. Atomicity comes from the journal: record the
previous state, write, verify, and reverse from the journal on failure. See
[README.md](README.md) under "State and reversal".

## Verify

A read-only P/Invoke that proves native calls work from the agent's runtime
model. This is the same call shape the agent uses for identity.

```powershell
Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetComputerNameEx(uint NameType,
  System.Text.StringBuilder Buffer, ref uint Size);
'@ -Name Kernel32 -Namespace Win32
$size = [uint32]256
$buffer = New-Object System.Text.StringBuilder 256
[Win32.Kernel32]::GetComputerNameEx(3, $buffer, [ref]$size)
$buffer.ToString()
```

NameType 3 is `ComputerNamePhysicalDnsHostname`. The probe script runs this
and compares the result with `$env:COMPUTERNAME`.
