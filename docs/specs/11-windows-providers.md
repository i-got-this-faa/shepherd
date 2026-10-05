# 11 — Windows providers

Go implementations under `apps/node-daemon/internal/platform/windows/<area>/`.
Each implements the provider interface in [10](10-node-daemon.md#provider-interface-go)
and passes the conformance suite. Surface research already in the repo is
normative background: [registry](../platforms/windows/registry.md),
[group policy](../platforms/windows/group-policy.md),
[winget](../platforms/windows/winget.md), [WMI](../platforms/windows/wmi.md),
[Win32 API](../platforms/windows/winapi.md),
[Windows Update](../platforms/windows/windows-update.md). The PowerShell
module in `apps/node-daemon/reference/powershell/Resources/` is the oracle
for behavior parity tests.

Libraries `[impl]`: `golang.org/x/sys/windows`, `golang.org/x/sys/windows/registry`,
`golang.org/x/sys/windows/svc/mgr`, `github.com/go-ole/go-ole` (COM for
winget/WUA/firewall), `github.com/microsoft/wmi` or raw COM for WMI.

## Edition support matrix (target; verified results go to the capability table)

| Provider | Enterprise/Pro | Home | Reversible |
|---|---|---|---|
| registry.value / registry.key | ✅ | ✅ | full |
| env.variable / env.path | ✅ | ✅ | full |
| service.state | ✅ | ✅ | full (config); status best-effort |
| package.winget | ✅ | ✅ (App Installer present) | partial (uninstall; no downgrade) |
| firewall.rule | ✅ | ✅ | full |
| account.local | ✅ | ✅ | partial (deleted accounts cannot be restored with same SID) |
| policy.setting | ✅ via Registry.pol + gpupdate | ⚠ `degraded` registry fallback or `unsupported` | full |
| task.scheduled | ✅ | ✅ | full |
| update.settings | ✅ | ⚠ deferrals limited | full |
| update.install | ✅ in window | ✅ in window | none |
| network.dns / network.proxy | ✅ | ✅ | full |
| shepherd.daemon (self-update) | ✅ | ✅ | binary rollback |

## registry.value / registry.key

- API: `RegCreateKeyEx`/`RegSetValueEx` via `x/sys/windows/registry`, explicit
  `KEY_WOW64_64KEY` / `KEY_WOW64_32KEY` per `view`.
- Types: SZ, EXPAND_SZ, MULTI_SZ, DWORD, QWORD, BINARY (base64 in plan).
- HKLM only in V1; `HKCU`/`HKU` resources are rejected by the compiler as
  omitted (`per-user-unsupported`).
- Deny-list: `HKLM\SAM`, `HKLM\SECURITY`, `HKLM\SYSTEM\CurrentControlSet\Control\Lsa`
  (unless explicitly allow-listed), BCD — see registry.md "Operations the agent must not perform".
- Journal previous: existed?, type, data; for keys: existed?, created subkeys.
- Reverse: restore previous value or delete value/key that Shepherd created.
- Drift: value missing, type changed, data changed.
- Optional event trigger: `RegNotifyChangeKeyValue` on managed keys to
  schedule an early drift pass `[impl, stretch in weeks 5–6]`.

## env.variable / env.path

Machine scope only: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`.

- `env.variable`: REG_SZ or REG_EXPAND_SZ per `expand`. After change, broadcast
  `WM_SETTINGCHANGE` with `"Environment"` via `SendMessageTimeout(HWND_BROADCAST)`.
- `env.path` ownership `[impl — closes KNOWLEDGE Q24 with the recommended option]`:
  Shepherd manages only **its own entries**. The provider stores the set of
  entries Shepherd owns in `HKLM\SOFTWARE\Shepherd\Ownership\Path` (REG_MULTI_SZ).
  Apply: ensure each declared entry exists at the declared position class
  (`append`/`prepend`), keep all foreign entries untouched, remove entries
  Shepherd previously owned that are no longer declared. Comparison is
  case-insensitive with trailing backslash normalized; `%VAR%` forms compared
  after expansion. PATH is written as REG_EXPAND_SZ.
- Drift: a declared entry missing or an owned entry duplicated.
- Max length guard (32,767 chars) → `failed` with evidence.

## service.state

- API: SCM via `svc/mgr` (`OpenService`, `Config`, `UpdateConfig`, `Start`,
  `Control(Stop)`), wait for state with timeout.
- Fields: `name`, `startupType` (`automatic|automatic-delayed|manual|disabled`),
  `status` (`running|stopped|any`). `account` is **not** supported in V1
  (reports `unsupported` if set — closes KNOWLEDGE gap honestly).
- Protected services (e.g. `WinDefend`, `TrustedInstaller`) → `blocked`.
- Reverse: restore previous startup type; restore previous running state.

## package.winget

- SYSTEM context: use the WinGet COM API (`Microsoft.Management.Deployment`)
  per winget.md; fall back to CLI only in user-mode debug runs. If COM is
  unavailable as SYSTEM on the tested build, the documented fallback is the
  CLI path with `--disable-interactivity --accept-source-agreements
  --accept-package-agreements --scope machine` executed with a hard timeout;
  record which path was used in evidence. `[spike in weeks 3–4 decides]`
- Fields: `wingetId`, `version` (required, pinned), `scope: machine`,
  `ensure`. `latest` is not allowed [DEP-02].
- Observation: installed version via COM `FindPackages` / `winget list`
  + uninstall registry keys.
- Disable winget self-updating behaviors and App Installer auto-update where
  possible (policy `EnableAppInstaller*` keys) so apps do not upgrade outside
  Shepherd [DEP-02].
- Exit codes mapped through the taxonomy in winget.md (reboot required,
  blocked by policy, package in use → `blocked`).
- Reverse: uninstall if Shepherd installed it; cannot restore previous version
  → `reversible: partial`, listed as unrecovered.

## firewall.rule

- API: `INetFwPolicy2` COM (HNetCfg.FwPolicy2) or `netsh advfirewall` as
  fallback `[impl]`. All Shepherd rules are created with `Grouping =
  "@Shepherd"` and name prefix `Shepherd:` so ownership is unambiguous.
- Fields: name, direction, action, protocol, localPorts, remoteAddresses,
  program, profiles (domain/private/public), enabled.
- Apply: create/update owned rules; remove owned rules no longer declared;
  never touch non-Shepherd rules.
- Reverse: restore previous rule definition or delete created rule.

## account.local

- API: `NetUserAdd`, `NetUserSetInfo`, `NetLocalGroupAddMembers`,
  `NetLocalGroupDelMembers`, `NetUserDel` (netapi32 via `x/sys/windows`).
- Fields: name, ensure, fullName, description, disabled, groups (local groups).
  No passwords in V1: new accounts are created disabled unless the platform
  allows "password must change at next logon" with a random unknown password —
  decide in issue and document.
- Only manages accounts listed; never deletes unlisted accounts. Group
  membership: manages membership of the declared account in declared groups
  only.
- Reverse: delete accounts Shepherd created (SID cannot be restored after a
  delete → `partial`).

## policy.setting

- Pro/Enterprise: author `C:\Windows\System32\GroupPolicy\Machine\Registry.pol`
  (PReg codec ported from the PowerShell reference), bump `gpt.ini` version,
  run `gpupdate /target:computer /force` (or `RefreshPolicyEx`), verify the
  resulting value under `HKLM\SOFTWARE\Policies`.
- Domain-joined machines: if domain GPO sets the same key, report `blocked`
  with "domain policy owns this setting" [ADM-03].
- Home: if `requireEngine` → `unsupported`; else write the policy registry
  value directly and report `applied` with capability `degraded` (visible).
- Machine scope only in V1.

## task.scheduled

- API: Task Scheduler COM (`Schedule.Service`). Tasks live under folder
  `\Shepherd\`. Run as SYSTEM only in V1.
- Fields: name, action (exe + args), trigger (boot, daily at, interval), enabled.
- Arbitrary scripts are **not** a V1 resource (SRS Platform limits); a task
  must reference an executable shipped by a package or the OS.

## update.settings / update.install / update.scan

- Settings via policy registry keys under
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` (deferrals,
  target release version, active hours, `NoAutoUpdate`/AU options so Windows
  does not install outside Shepherd's window) [DEP-02].
- Install via WUA COM (`Microsoft.Update.Session`) only inside a maintenance
  window; exclude drivers/firmware unless explicitly allowed; never reboot
  (report `rebootRequired`). Port logic from `Update.Operations.ps1`.

## network.dns / network.proxy

- DNS: per adapter selection (`match: {interfaceAlias?, all: true}`) via
  `SetInterfaceDnsSettings` (Win10 2004+) or WMI
  `Win32_NetworkAdapterConfiguration.SetDNSServerSearchOrder`.
- Proxy: machine-wide WinHTTP proxy (`WinHttpSetDefaultProxyConfiguration`) and
  the policy `ProxySettingsPerUser=0` + IE/Edge proxy policy keys.
- Static IP and Wi-Fi are out of V1 scope (bounded catalog).

## Inventory and capability probes

Edition (`EditionID`, `ProductName`), build, domain/workgroup, Azure AD /
Intune MDM enrollment (`dsregcmd /status` parsing or registry
`HKLM\SOFTWARE\Microsoft\Enrollments`), SCCM client (`CcmExec` service),
winget presence/version, Group Policy engine availability, TPM, BitLocker
status (read-only), disks, NICs, installed programs.

## Testing

- Unit tests with an injectable `winapi` interface (fakes) for each provider.
- Integration tests on `windows-latest` runners for safe subsets (HKLM under
  `SOFTWARE\ShepherdTest` in an elevated runner, temp services created by the
  test, owned firewall rules, local test accounts).
- VM conformance suite on Win11 Pro and Win11 Home lab VMs, results recorded in
  `docs/platforms/windows/evidence.md` and the capability table.
- Parity tests: the same plan fixture applied by the PowerShell reference and
  the Go daemon on a snapshot VM yields the same observed state.
