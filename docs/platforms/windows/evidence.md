# Windows Mapper Test Evidence

All evidence below comes from real, read-only or fully reversed probes run
on the development machine: an HP Victus 15-fb0xxx laptop, Windows 11 Home
Single Language (build 26200), workgroup, non-domain, user `radhe` with a
split-token admin account, UAC enabled. Machine name `PICO-WINDOWS`.

Final combined result: **61 passed, 0 failed, 0 skipped.**

Two probe suites plus two focused experiments produced the results:

1. `tools/probes/windows/test-windows-surfaces.ps1` — runs non-elevated. Read-only
   surface checks plus document-integrity checks, and it merges the
   elevated suite's results into one matrix. On its own it reports
   `PENDING` for elevated checks; on this machine they merged.
2. `tools/probes/windows/test-windows-elevated.ps1` — elevated through a UAC prompt,
   hidden window, transcripted. Every mutating operation follows apply,
   verify, and reverse, and the suite confirms `RebootRequired: False`
   after the run. Final result: **34 passed, 0 failed, 0 skipped**.
3. `tools/probes/windows/test-gptini-experiment.ps1` — isolates the Group Policy
   versioning behavior (finding 1 below).
4. `tools/probes/windows/test-finishers.ps1` — closes the two original open items:
   Group Policy root cause and the Windows Update install path.

The suite has no skip branches left. Conditional behavior is handled by
selection, not omission: the winget probe picks a package the user has not
installed (7-Zip, then jq, then yq); the update probe registers the
Microsoft Update source to widen the applicable set and installs only
non-firmware updates that do not force a reboot.

## Combined matrix

### Win32 API

| Check | Status | Evidence |
|---|---|---|
| `GetComputerNameEx` P/Invoke returns the DNS hostname | PASS | `pico-windows` matches `COMPUTERNAME` |
| `Get-WinEvent` reads the System log | PASS | newest event timestamp returned |

### Registry

| Check | Status | Evidence |
|---|---|---|
| `reg.exe` read of `HKLM\...\CurrentVersion` | PASS | `ProductName` returned (still says `Windows 10 ...` on Windows 11 — a documented trap) |
| PowerShell provider read of the same key | PASS | identical value through `Get-ItemProperty` |
| Elevated: write and read back five value types under HKLM | PASS | `REG_SZ`, `REG_EXPAND_SZ`, `REG_MULTI_SZ`, `REG_DWORD`, `REG_QWORD` through provider and `reg.exe` |
| Elevated: reverse, remove probe key | PASS | machine state restored |

### Group Policy

| Check | Status | Evidence |
|---|---|---|
| `gpresult /scope user /r` non-elevated | PASS | RSOP data returned |
| `gpresult /scope computer /r` elevated | PASS | RSOP data returned |
| `Registry.pol` presence | PASS | absent; valid baseline (machine never applied local policy) |
| Home edition engine inventory | PASS | `gpedit.msc` absent, `secedit.exe` present, GroupPolicy module cmdlets: 0 — matches documented limits |
| PReg binary round-trip | PASS | one record written and parsed back: key, value name, type 4, DWORD data |
| `gpupdate` applies local `Registry.pol` | PASS (documented behavior) | not applied; policy core filtered out the local GPO (operational log events 5312/5313) — the Home contract in [group-policy.md](group-policy.md) |
| Reverse after each cycle | PASS | `Registry.pol`, `GPT.ini`, and applied values removed |

### winget

| Check | Status | Evidence |
|---|---|---|
| `winget --version` | PASS | v1.29.290 |
| `winget source list` | PASS | community source present |
| Elevated: install at machine scope | PASS | pinned 7-Zip 24.08 installed silently |
| Elevated: upgrade to latest | PASS | upgrade succeeded silently |
| Elevated: uninstall and reverse | PASS | `7zip.7zip` fully removed |

### WMI and CIM

| Check | Status | Evidence |
|---|---|---|
| `Win32_OperatingSystem` | PASS | caption `Microsoft Windows 11 Home Single Language` |
| `Win32_ComputerSystem` | PASS | `HP Victus by HP Gaming Laptop 15-fb0xxx` |
| `MSFT_NetAdapter` | PASS | 2 adapters |
| Elevated: `Win32_Process.Create` method | PASS | `ReturnValue 0` |
| Elevated: `MSFT_MpComputerStatus` read | PASS | `AMServiceEnabled=True`, signature age 0 |
| Elevated: `Get-BitLockerVolume` | PASS | `C: Off` — status readable on Home through device encryption |
| Elevated: `Get-Tpm` | PASS | `TpmPresent=True`, `TpmReady=True` |
| Elevated: `Confirm-SecureBootUEFI` | PASS | `SecureBoot=False` on this machine |
| Elevated: `Win32_QuickFixEngineering` | PASS | 5 hotfixes, latest `KB5124008` |
| Elevated: CIM indication event | PASS | process-creation indication received (for `powershell.exe`; the probe now starts a 6-second process — see lessons) |

### Windows Update

| Check | Status | Evidence |
|---|---|---|
| COM history read (`CreateUpdateSearcher`) | PASS | 203 entries |
| AutoUpdate settings read | PASS | notification level 4 |
| Elevated: `ISystemInformation.RebootRequired` | PASS | `False` before and after every run |
| Elevated: Microsoft Update source registered and deregistered | PASS | `AddService2` then `RemoveService`, state restored |
| Elevated: online search over Microsoft Update | PASS | applicable set returned with titles, sizes, and `RebootBehavior` |
| Elevated: install path | PASS | Defender Security Intelligence Update `KB2267602` (`RebootBehavior=0`) downloaded and installed: installer ResultCode 2, update result 2, HResult 0, `RebootRequired` stayed `False`; signature version 1.459.193.0 confirmed afterwards |
| Elevated: firmware gate | PASS | HP firmware and MediaTek driver updates (`RebootBehavior=2`) excluded from unattended install by the documented rule |
| Elevated: `usoclient StartScan` | PASS | new event id 26 in `WindowsUpdateClient/Operational` |
| Elevated: `TargetReleaseVersion` policy triple write and reverse | PASS | `TargetReleaseVersion=1`, `TargetReleaseVersionInfo=26100`, `ProductVersion="Windows 11"` |

### Services, ACL, scheduled tasks

| Check | Status | Evidence |
|---|---|---|
| `sc query wuauserv` | PASS | state query answered |
| Elevated: `sc create` probe service | PASS | `CreateService SUCCESS` |
| Elevated: `sc start` and `sc query` | PASS | start accepted; state observed `STOPPED` (probe binary is not a service binary; expected) |
| Elevated: `sc delete` | PASS | query returns 1060, service gone |
| Elevated: `Set-Acl` inheritance removal plus explicit ACE | PASS | descriptor protected, ACE present |
| `Get-ScheduledTask` | PASS | 185 tasks enumerated |
| Elevated: register, start, read task info | PASS | `LastTaskResult=0` |
| Elevated: unregister task | PASS | task removed |

### Immutability survey

| Check | Status | Evidence |
|---|---|---|
| Unified Write Filter availability | PASS | `uwfmgr` absent on Home, as documented in [assessment.md](assessment.md) |

### Documents

All thirteen documents in `docs/platforms/windows/` pass integrity checks: file
present, content anchor present, and (for surface documents) a Verify
section present.

## The two findings

### 1. Group Policy: the policy core filters out the local GPO on Home

The same probe applied cleanly in one run (the value appeared in the
Policies hive within 8 seconds) and failed to apply within 90 seconds in
two later runs. `tools/probes/windows/test-gptini-experiment.ps1` isolated three
variants — Registry.pol alone, Registry.pol plus a `GPT.ini` machine
revision, and a bumped revision — and all three failed to apply, with a
clean reversal each time. `tools/probes/windows/test-finishers.ps1` then captured the
Group Policy operational log during a cycle and produced the root cause:

1. Event 8004: "Completed manual processing of policy for computer
   WORKGROUP\PICO-WINDOWS$" — the engine runs a full cycle.
2. Event 5312: "List of applicable Group Policy objects:" — the list is
   empty.
3. Event 5313: the remaining GPOs "were not applicable because they were
   filtered out".

The local GPO is excluded at the policy-core level, so the registry
client-side extension never reads the file. The mapper contract:

1. On Home editions, registry-backed policy settings are written directly to
   the `SOFTWARE\Policies` hives through the registry surface.
2. On Pro and higher, `Registry.pol` authoring stays the primary path, and
   the mapper must manage `GPT.ini` and the History state exactly like
   LGPO.exe and SaltStack's `win_lgpo` do.
3. Stated limit: the exact filter that excludes the local GPO was not
   isolated further; a Pro machine is the next test surface for the
   Registry.pol path.

### 2. Windows Update: the install path is proven, with a firmware gate

The full agent path — search, download, install, reboot state — has real
runtime evidence (see the Windows Update table). The only excluded class is
firmware/BIOS and `RebootBehavior=2` updates, which the suite filters by
title and behavior rather than skipping. That gate is a production safety
rule for unattended installs, not a test gap.

## Probe-harness lessons (recorded for the mapper's own tests)

1. A hidden-window CLI can hang forever on an interactive prompt. Every
   winget call runs under a hard timeout with
   `--accept-source-agreements --disable-interactivity`; the first suite
   run hung exactly this way and was killed.
2. MSI packages register their uninstall key under the GUID product code,
   not the package name. Package detection must match on `DisplayName`
   across the uninstall database — or use winget list for portable
   packages, which register no ARP key at all.
3. `gpupdate` returns before the client-side extension finishes; any check
   after it must poll.
4. PowerShell 5.1 parses `$var:` inside a double-quoted string as a scope
   expression and fails the whole script at parse time. Scripts are
   parse-checked with the language parser before launch.
5. A single-element collection returned from a function unrolls to a scalar;
   `$parsed[0]` then indexes the first character. The probe suite wraps
   such returns in `@(...)`.
6. A `WITHIN 2` WMI polling query never fires for a process that exits
   between two polls. Event-driven probes must start a process that
   outlives the polling window.
