# Prior Art

How existing tools implement Windows configuration, and what the mapper
borrows from each. This survey validates the Fleet split: nix evaluates on
the control server, the agent applies a JSON plan, and Windows stays a
client.

## Configuration management tools

| Tool | Windows surfaces | Resource model | Idempotency | What the mapper borrows |
|---|---|---|---|---|
| Puppet | package (MSI, EXE), registry_key, service, scheduled_task, windowsfeature | Agent compiles a catalog of typed resources | Compare-and-write per resource; read path can emit declarative state (`puppet resource`) | The read path that emits the current state as a plan; registry resources bundled in the agent, not plugins |
| Ansible | win_package, win_regedit, win_updates, win_feature, win_service | Module per task, agentless over WinRM | Each module reports `changed`; exit code 3010 means `reboot_required` | `reboot_required` as structured report output, never an agent-initiated reboot; per-installer-type sub-adapters behind one package verb; explicit check (audit) mode in every resource |
| Chef | windows_package, registry_key, windows_feature (DISM), windows_task | Converge-based agent | Package identity resolved against the registry uninstall database; registry atomic compare | The registry uninstall database as the canonical package index; a pluggable package identity predicate (product code, name, hash) |
| SaltStack | win_pkg (winrepo), win_wua, win_lgpo | Execution module plus state module on a minion | win_wua: search, select by KB or classification, install, report reboot | `win_lgpo` is the reference for atomic local policy rendering (Registry.pol plus GPT.ini); win_wua is the mature shape of an update resource |
| PowerShell DSC v2 | Registry, WindowsFeature, Service, File, Archive, Script, Package | Server compiles a MOF; the Local Configuration Manager applies in push or pull | `Get-TargetResource` / `Test-TargetResource` / `Set-TargetResource`; ApplyAndAutoCorrect mode corrects drift | The get/test/set contract as the resource interface, serialized as JSON instead of MOF |
| PowerShell DSC v3 | Cross-platform `dsc.exe`, JSON manifests, adapters for legacy resources | No MOF, no LCM, no pull server; only get, test, and set primitives | Explicit invocation; orchestration left to external tooling | Microsoft removed the orchestration layer from the engine and expects an external controller. Fleet's control server is that controller, with nix evaluation instead of MOF compilation |

## Microsoft's own fleet stacks

1. **Windows Declared Configuration (WinDC)**. Microsoft's desired-state
   protocol: the server sends the complete document once, and the client
   stack applies it and re-checks drift on a default 4-hour schedule,
   re-applying on drift and flagging documents it cannot refresh. The
   mapper is a WinDC-shaped engine with nix on the server end. This is the
   single strongest validation of the design.
2. **Azure machine configuration** (Guest Configuration). DSC packages
   delivered by an extension, in two modes: audit (report-only) and apply
   with autocorrect. The mapper copies the audit-first rollout ladder: a
   new plan ships in audit mode first, and the control server promotes it
   per ring.
3. **Intune**. Three models to study: the Win32 app pipeline (detection and
   requirement scripts around an installer), the Settings Catalog (a typed
   catalog of named settings that compile to configuration service
   providers, which beats raw registry dumps), and Remediations (paired
   detection and fix scripts). The mapper keeps an equivalent
   `script.fleet` resource as the documented escape hatch for anything not
   declarative, marked non-convergent.

## Nix on Windows

Nix does not run natively on Windows. The supported platform is WSL, with
NixOS-WSL as the declarative option. Native port work (Cygwin and MSYS2 CI
builds, a MinGW build) remains incomplete; the structural blockers are UNC
paths, sandboxing through Job Objects instead of namespaces, and ACL-based
permissions. nix-portable is Linux only. Conclusion: evaluate on the
server, apply JSON on the client is a requirement, not a preference.

## Declarative Windows projects

1. `winget configure` — Microsoft's declarative layer over DSC v3, YAML
   with a JSON schema, `winget configure test` for drift. Developer-machine
   scope, no fleet orchestration.
2. Nazm (by the komorebi author) — declarative config plus export, diff,
   and apply for Windows 11. Single user, no fleet.
3. numtide system-manager — declarative nix configuration beyond NixOS for
   Linux and macOS, no Windows backend. Fleet would be its missing target.
4. FleetDM — osquery-based fleet inventory and MDM. Inventory first, not
   configuration management. Its osquery tables (registry, scheduled_tasks,
   services) are a good read-back checklist for the mapper's audit mode.
   Name collision note: the existing product is called Fleet; an early
   naming decision for this project avoids confusion.

## What the mapper does differently

1. One nix-authored configuration for all three operating systems, with
   per-OS providers behind one resource envelope.
2. No pull server, no agentless SSH or WinRM. One authenticated,
   outbound-only agent channel.
3. Journal-first mutation on Windows: every operation records the previous
   state before it writes, because the platform has no generations.
4. Audit and apply as first-class modes on every resource, with audit as
   the rollout default.

Sources for every claim in this document live in the research notes that
produced it: learn.microsoft.com (WinDC, machine configuration, DSC, Intune,
UWF), docs.ansible.com, docs.chef.io, docs.puppet.com, docs.saltproject.io,
and the NixOS issue tracker for the Windows port status.
