# Registry Surface

The registry is the primary machine and user configuration store on Windows.
The mapper writes declared values into declared keys and observes them for
drift. This surface has no edition limits and no extra tool requirements.

## What the mapper maps

| Plan intent | Registry operation | Native call |
|---|---|---|
| A value must exist with data | Create or update the value | `RegSetValueEx` |
| A value must not exist | Delete the value if present | `RegDeleteValue` |
| A key must exist | Create the key and its parents | `RegCreateKeyEx` |
| A key must not exist | Delete the subtree | `RegDeleteTree` |
| Read current state | Enumerate values and data | `RegQueryValueEx`, `RegEnumValue` |
| Detect drift without polling | Register for change notification | `RegNotifyChangeKeyValue` |
| Back up before a write | Export the key to a file | `RegSaveKeyEx` |
| Restore after a failure | Import the saved file | `RegLoadKey`, `RegRestoreKey` |

## Data types

The mapper supports these types and rejects others in the plan:

| Plan type | Registry type | Notes |
|---|---|---|
| `REG_SZ` | String | Fixed string |
| `REG_EXPAND_SZ` | Expand string | Contains `%VARIABLE%` references |
| `REG_MULTI_SZ` | String list | Ordered list of strings |
| `REG_DWORD` | 32-bit number | The most common policy type |
| `REG_QWORD` | 64-bit number | Used by 64-bit components |
| `REG_BINARY` | Byte sequence | Size-limited by the plan schema |

An `ensure: absent` operation ignores the type. A change of type on an
existing value deletes the value and recreates it.

## Hive access rules

1. `HKEY_LOCAL_MACHINE` is machine state. The agent writes it in the service
   context.
2. `HKEY_CURRENT_USER` inside the agent process resolves to the SYSTEM
   account, not to a logged-in user. The mapper forbids `HKCU` in plans.
3. To declare per-user state, the plan names the target user by SID and the
   agent addresses `HKEY_USERS\<SID>` after loading the hive with
   `RegLoadKey` when the user is not logged in. The report records the SID.
4. `HKEY_CLASSES_ROOT` is a merged view. The agent writes class registrations
   under `HKEY_LOCAL_MACHINE\SOFTWARE\Classes` or the per-user
   `HKEY_USERS\<SID>\SOFTWARE\Classes`, never through `HKCR`.
5. A 32-bit application on 64-bit Windows reads `SOFTWARE\WOW6432Node` through
   redirection. The plan states the view explicitly with a `view` field set to
   `64` or `32`; the agent calls `RegOpenKeyEx` with `KEY_WOW64_64KEY` or
   `KEY_WOW64_32KEY`.

## Operations the agent must not perform

1. Do not replace a whole hive with `RegRestoreKey` outside reversal. The call
   replaces security descriptors and can lock the system out.
2. Do not write while a key transaction from another process is open. Key
   transactions (`RegCreateKeyTransacted`) are deprecated; the mapper does not
   use them.
3. Do not change the values of the policy hives directly when the plan has a
   group-policy resource for the same setting. One setting, one owner. See
   [group-policy.md](group-policy.md).

## Known content traps

1. `ProductName` under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
   reports `Windows 10 ...` on Windows 11 machines. Never use it as the OS
   version. The reliable fingerprint is the build number (22000 and higher
   means Windows 11) plus the `UBR` value as the patch level. See
   [wmi.md](wmi.md).
2. Policy hives under `SOFTWARE\Policies` are owned by the policy engine.
   The mapper writes them only through the group-policy surface, so a
   refresh does not fight the mapper. See [group-policy.md](group-policy.md).

## Elevation and editions

Machine hive writes need administrator or SYSTEM rights. User hive writes
need the rights of that user or of SYSTEM. No edition restricts the registry
APIs.

## Verify

Read-only checks that prove the surface is reachable. Both ran on the test
machine (Windows 11 Home, PowerShell 5.1, non-elevated).

```powershell
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v ProductName
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" |
  Select-Object ProductName
```

Elevated evidence from the test machine: the probe wrote a probe key with
all five supported types (`REG_SZ`, `REG_EXPAND_SZ`, `REG_MULTI_SZ`,
`REG_DWORD`, `REG_QWORD`) under `HKLM\SOFTWARE`, verified each value through
both the PowerShell provider and `reg.exe`, then removed the key and
confirmed removal. The full apply-and-reverse cycle succeeded.
