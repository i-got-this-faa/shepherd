# Group Policy Surface

Group Policy is the policy engine of Windows. Its unit of work is the
Administrative Template: a declared setting that the policy engine applies
into the registry policy hives. The mapper authors policy the same way a
domain controller would, so that native tooling stays valid.

## What the mapper maps

| Plan intent | Operation | Where it lands |
|---|---|---|
| One administrative template setting | Write the value into `Registry.pol` | `%WINDIR%\System32\GroupPolicy\Machine\Registry.pol` or the `User` equivalent |
| A security template setting | Write into `GptTmpl.inf` | `%WINDIR%\System32\GroupPolicy\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf` |
| Force policy evaluation | Trigger a policy refresh | `gpupdate /target:computer /force` or the scheduled task `\Microsoft\Windows\GroupPolicy\*` |
| Read effective policy | RSOP query | `gpresult /scope computer /r` |
| Remove a declared setting | Delete the entry from `Registry.pol` | The next refresh removes the registry value if the ADMX marks it |

## Registry.pol format

`Registry.pol` is a little-endian binary file:

1. Signature `PReg` (bytes `50 52 65 67`) followed by version `0x00000001`.
2. A sequence of records. Each record is: key length as uint16, key path in
   UTF-16LE, value name length as uint16, value name in UTF-16LE, value type
   as uint16, data length as uint32, then the data bytes.

Special value-name prefixes drive delete operations:

| Prefix | Effect |
|---|---|
| `**del.<name>` | Delete the named value at refresh |
| `**DelVals.` | Delete all values in the key |
| `**securekey.` / `**soft.` | Special markers used by the policy engine |

String data for ADMX enum and list elements can carry suffixes of the form
`[<type>:<value>]` next to the value name. The mapper writes plain records
for registry-backed policies and leaves ADMX-element encoding to the LGPO
semantics it imports.

The mapper writes this format directly or through LGPO.exe from the
Microsoft Security Compliance Toolkit. Writing it directly is one parser and
one serializer; the policy engine does the rest at refresh time. SaltStack's
`win_lgpo` module proves the approach at scale: it renders local policy
atomically through the same files. Policy values land under
`HKLM\SOFTWARE\Policies` or `HKCU\SOFTWARE\Policies`, so the registry
surface stays the single write target for raw values.

## How the engine processes policy

1. The Group Policy Client service reads the local GPO folder tree and any
   domain GPOs.
2. It merges registry-based policy into the `Policies` hives.
3. It records the applied GPO list in
   `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History`.
4. A refresh runs at boot, at logon, and on the refresh interval, and on
   demand through `gpupdate`.

Local policy does not need a domain. A workgroup machine applies the local
GPO folder tree exactly as written.

## Edition limits

1. Windows Pro, Enterprise, and Education have the full local policy engine
   and `gpedit.msc`.
2. Windows Home lacks `gpedit.msc` and parts of the engine. Empirical
   evidence from the test machine: a hand-written `Registry.pol` was applied
   by the engine once (first-ever foreground-triggered cycle, value landed
   in the Policies hive within 8 seconds) but repeated application failed
   across three controlled variants, including a `GPT.ini` version bump, a
   `gpsvc` restart, and a long poll after a plain `gpupdate /force`. The
   Group Policy operational log captured during a failed cycle gives the
   root cause: event 8004 shows a complete machine policy cycle, event 5312
   lists zero applicable Group Policy objects, and event 5313 reports the
   remaining GPOs as "filtered out". The local GPO is excluded at the
   policy-core level, so the registry client-side extension never reads the
   file. The mapper contract: on Home, write registry-backed policy
   settings directly to the `SOFTWARE\Policies` hives through the registry
   surface; do not depend on the policy engine as a write path.
3. Domain GPOs outrank local policy. On a domain-joined machine the mapper
   reports which settings a domain GPO owns and does not fight it.

## MDM alternative

On Pro and higher, the MDM Bridge WMI provider exposes configuration
service providers through the `root\cimv2\mdm\dmmap` namespace (provider
`DMWmiBridgeProv`) without full enrollment tooling. Device-scope CSP calls
require the SYSTEM context. It is a secondary path: the registry.pol path
is primary because it needs no enrollment and works offline, and many CSPs
only take effect on an enrolled device.

## Elevation

Reading policy needs no elevation. Writing `Registry.pol` and forcing a
machine-scope refresh need administrator or SYSTEM rights.

## Verify

Read-only checks that prove the surface is reachable. `gpresult /scope user
/r` ran non-elevated on the test machine and reported RSOP data for the
workgroup machine.

```powershell
gpresult /scope user /r
Test-Path "$env:WINDIR\System32\GroupPolicy\Machine\Registry.pol"
```

`Test-Path` returns `False` on a machine that has never applied local
policy; that is a valid observation, not a failure.

Elevated evidence from the test machine: the probe wrote a valid `PReg`
file with one `REG_DWORD` record and parsed it back byte-identical in
structure. Application was measured across five runs and three trigger
variants, with the operational log captured during each cycle; the root
cause and the resulting Home contract are documented under "Edition
limits". Computer-scope `gpresult` returned RSOP data while elevated, and
the machine returned to its baseline after every run.
