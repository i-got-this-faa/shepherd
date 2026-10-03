# Mapper Assessment

This document answers the design question in `what-this-is.md`: map the
Windows control surface to one nix-authored configuration for all three
operating systems, with a custom mapper for Windows. It states the verdict
first, then the evidence.

## Verdict

The idea is sound, with one correction. Do not promise a read-only root
filesystem on Windows. Build the same guarantees a different way: declarative
plans, idempotent resources, a write-ahead journal, and drift detection.

## What is strong

1. One configuration language for three operating systems removes the largest
   fleet tax: three divergent ways to say the same thing. The nix evaluation
   model already proved this on NixOS and nix-darwin.
2. Evaluate on the server, apply on the client is the correct split. Nix does
   not run on Windows. The mapper agent needs only a plan in JSON, so the
   Windows machine needs no nix store, no nix daemon, and no WSL.
3. The six chosen surfaces cover the real Windows control points. Registry,
   policy files, packages, inventory, and updates are the same five domains
   that commercial MDM products manage.
4. winget already ships a declarative engine. `winget configure` applies a
   Desired State Configuration document and can test it for drift. The mapper
   can reuse that engine instead of reimplementing package reconciliation.
   See [winget.md](winget.md).

## The correction: state, not immutability

`what-this-is.md` says the deployed machine has a read-only root filesystem
and is writable only through the control layer. NixOS gives that property
because every file under `/nix/store` is immutable and the system profile is
one symlink switch. Windows gives no equivalent for most fleets:

1. `C:\Windows` is owned by TrustedInstaller and shared with Windows Update,
   servicing, and every installer. Freezing it breaks the operating system.
2. The transactional filesystem (TxF) that could give atomic multi-file
   changes is deprecated by Microsoft.
3. Most Windows state is a graph of registry values, not files.

The honest survey of read-only mechanisms on Windows:

| Mechanism | Editions | What it freezes | Fit for fleet |
|---|---|---|---|
| Unified Write Filter (`uwfmgr.exe`) | Enterprise, Education, IoT Enterprise only; not Home or Pro | All writes to a protected volume, into an overlay discarded at reboot | The only real read-only root on Windows. Requires servicing mode to apply updates. Absent on the test machine, as expected on Home |
| Windows Sandbox | Pro and higher | Nothing on the host; disposable VM | Not a management target |
| AppLocker / WDAC | AppLocker on all editions since KB5024351; WDAC 1903+ | Execution of unauthorized code, not configuration | Complements the mapper; not immutability |
| Non-persistent VDI | Any edition with the infra | Everything, reset at logoff | Convergence must finish before first logon; agent state must live in the image or the server |

The fleet property to keep is not "read-only files". It is "the machine
converges to the declared plan and reports when it cannot". The mapper gets
that with idempotent resources, a journal that records the previous state
before each write, reversal from the journal on failure, and a periodic drift
pass. This is documented in [README.md](README.md) under "State and reversal".
On Enterprise and IoT fleets that want real immutability, the mapper should
detect UWF and either drive its servicing mode or report the machine as
frozen instead of writing into a discarded overlay.

## The architecture is the industry's converged answer

Three independent lines of evidence validate the evaluate-on-server,
apply-on-client split with JSON plans:

1. PowerShell DSC v3 removed the pull server and the Local Configuration
   Manager from the engine and ships only get, test, and set primitives,
   leaving orchestration to external tooling. Fleet's control server is
   exactly that orchestrator, with nix evaluation instead of MOF
   compilation.
2. Windows Declared Configuration is Microsoft's own desired-state protocol:
   the server sends the complete document once, and the client stack applies
   it and re-checks drift on a schedule. The mapper is a WinDC-shaped engine
   with nix on the server end.
3. Azure machine configuration ships DSC packages to agents in audit or
   apply-and-autocorrect modes. Its audit-first ladder is a pattern the
   mapper should copy: every resource ships with a test-only mode, and
   rollout defaults to report-only before enforce.

Prior art also fixes the resource contract: Ansible's Windows modules return
`reboot_required` as structured output rather than rebooting unilaterally,
Chef and osquery treat the registry uninstall database as the canonical
package index, and Intune's Settings Catalog shows that a typed catalog of
named settings beats raw registry dumps. One naming note: a fleet tool named
FleetDM already exists; the name collision is worth an early decision.

## Ranked risks

| Risk | Effect | Control |
|---|---|---|
| Windows Update reboots | An update restarts the machine in the middle of an apply | Updates are the last resource class; the agent drains reboots into a maintenance window before the next plan |
| `HKEY_CURRENT_USER` under SYSTEM | The agent writes policy to the wrong user hive | Address user hives by SID, never by `HKCU`. See [registry.md](registry.md) |
| Edition differences | Home lacks the Group Policy engine and some providers | Edition-aware resources that report `unsupported` instead of failing. See [group-policy.md](group-policy.md) |
| winget detection gaps | `winget list` misses installs that register nowhere | Treat winget as the installer, registry uninstall keys as the inventory of record. See [wmi.md](wmi.md) |
| Third-party antivirus blocks ACL or service changes | An apply fails or hangs | Journal first, time-box each operation, report the blocker with the event log id |
| Scope creep into the full Win32 API | An unmaintainable binding surface | The mapper uses a small fixed API set per resource. See [winapi.md](winapi.md) |

## Nix on Windows is server-side only, and that is correct

Nix does not run natively on Windows; the supported platform is WSL, and
native-port efforts (Cygwin and MSYS2 CI, a MinGW build) remain incomplete.
The blockers are structural: UNC paths, sandboxing through Job Objects
instead of namespaces, and an ACL-based permission model. This makes the
evaluate-on-server split a requirement, not a preference. It also means the
ecosystem gap is real: numtide's system-manager extends declarative nix
configuration beyond NixOS but has no Windows backend, and the closest
independent project (Nazm, by the komorebi author) is a single-user Windows
config exporter. A fleet-grade Windows mapper with a server-side nix
evaluation is genuinely unclaimed territory.

## Build order

The order is cheapest-verification-first. Each step produces a resource the
next step can reuse.

1. Registry. One data type family, one API, instant observation.
2. winget. Delegates the hardest reconciliation to a maintained tool.
3. Windows Update. Search and history read without elevation; install is the
   first resource that needs the service context.
4. WMI and CIM. Inventory first, method calls second.
5. Group Policy. Registry.pol authoring needs the LGPO semantics from
   step 1; defer it until the registry resource is stable.
6. Win API. Not a milestone; it is the substrate each step already uses.

## What the mapper must not do

1. Do not reimplement Windows servicing. The mapper requests updates; the
   operating system applies them.
2. Do not write to `C:\Windows` directly. System components own that tree.
3. Do not call `Win32_Product` for inventory. Its methods trigger a
   reconfiguration of every MSI package. See [wmi.md](wmi.md).
4. Do not parse `reg.exe` or `gpresult` output for machine-readable state
   inside the agent. The agent uses the native API; the CLI tools are for
   humans and for this document set's verification.
