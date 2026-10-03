# Elevated tier: executor resources that require SYSTEM/admin context,
# plus direct integration for task scheduler and the winget lifecycle.
# Writes results JSON and a done flag for the non-elevated runner to merge.

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'FleetTest\FleetTest.psm1') -Force

Initialize-FleetTestRun -Name 'elevated'
Initialize-FleetJournal

if (-not (Test-FleetElevated)) {
  Add-FleetResult -Surface 'Elevation' -Check 'administrator token' -Status 'FAIL' -Evidence 'not elevated'
  $outDir = Join-Path $env:TEMP 'fleet-tests'
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  Complete-FleetTestRun -OutFile (Join-Path $outDir 'elevated-results.json') | Out-Null
  Set-Content -Path (Join-Path $outDir 'done.flag') -Value 'done' -Encoding ASCII
  exit 1
}
Add-FleetResult -Surface 'Elevation' -Check 'administrator token' -Status 'PASS' -Evidence 'elevated'

# Clean up any leftover test keys from prior runs:
if (Test-Path 'HKLM:\SOFTWARE\FleetTest') { Remove-Item 'HKLM:\SOFTWARE\FleetTest' -Recurse -Force -ErrorAction SilentlyContinue }

# --- HKLM registry triple through the executor ------------------------
Invoke-FleetCheck -Surface 'Registry' -Check 'apply to HKLM and read back' -Body {
  $plan = ConvertFrom-Json (@"
{ "planVersion": 1, "planId": "el-reg-1", "fleetId": "f", "machineId": "m", "mode": "apply",
  "resources": [ { "resource": "registry.value", "id": "HKLM\\SOFTWARE\\FleetTest\\Elevated", "ensure": "present",
    "data": { "valueName": "Alpha", "type": "REG_QWORD", "data": 123456789012 } } ] }
"@)
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'applied') { throw "status $($report.results[0].Status): $($report.results[0].Evidence)" }
  $read = (Get-ItemProperty 'HKLM:\SOFTWARE\FleetTest\Elevated').Alpha
  if ($read -ne 123456789012) { throw "read back $read" }
  return 'REG_QWORD written to HKLM and verified'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'idempotent re-apply is unchanged' -Body {
  $plan = ConvertFrom-Json (@"
{ "planVersion": 1, "planId": "el-reg-2", "fleetId": "f", "machineId": "m", "mode": "apply",
  "resources": [ { "resource": "registry.value", "id": "HKLM\\SOFTWARE\\FleetTest\\Elevated", "ensure": "present",
    "data": { "valueName": "Alpha", "type": "REG_QWORD", "data": 123456789012 } } ] }
"@)
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'unchanged') { throw "status $($report.results[0].Status)" }
  if ((Get-FleetJournalWriteCount -PlanId 'el-reg-2') -ne 0) { throw 'idempotent apply journaled' }
  return 'unchanged with zero writes'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'undo removes the HKLM value' -Body {
  $undone = Undo-FleetPlan -PlanId 'el-reg-1'
  if ($undone -ne 1) { throw "undo reversed $undone" }
  if (Test-Path 'HKLM:\SOFTWARE\FleetTest\Elevated') { throw 'probe key still present' }
  return 'machine state restored'
}

# --- service.state through the executor --------------------------------
$svcName = 'FleetTestSvc'
Invoke-FleetCheck -Surface 'Services' -Check 'executor changes startup type and reverts from the journal' -Body {
  & sc.exe create $svcName binPath= "$env:WINDIR\System32\cmd.exe" start= demand | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'sc create failed' }
  try {
    $plan = ConvertFrom-Json (@"
{ "planVersion": 1, "planId": "el-svc-1", "fleetId": "f", "machineId": "m", "mode": "apply",
  "resources": [ { "resource": "service.state", "id": "$svcName",
    "data": { "startupType": "disabled", "status": "stopped" } } ] }
"@)
    $report = Invoke-FleetPlan -Plan $plan
    if ($report.results[0].Status -ne 'applied') { throw "status $($report.results[0].Status): $($report.results[0].Evidence)" }
    $startType = (Get-Service $svcName).StartType.ToString()
    if ($startType -ine 'Disabled') { throw "start type now $startType" }
    $undone = Undo-FleetPlan -PlanId 'el-svc-1'
    if ($undone -ne 1) { throw "undo reversed $undone" }
    $restored = (Get-Service $svcName).StartType.ToString()
    if ($restored -ine 'Manual') { throw "startup type restored to $restored, expected Manual (demand)" }
    return 'disabled applied, journal restored Manual'
  }
  finally { & sc.exe delete $svcName | Out-Null }
}

# --- update.settings through the executor -------------------------------
Invoke-FleetCheck -Surface 'WindowsUpdate' -Check 'executor writes the TargetReleaseVersion triple' -Body {
  $plan = ConvertFrom-Json (@"
{ "planVersion": 1, "planId": "el-wu-1", "fleetId": "f", "machineId": "m", "mode": "apply",
  "resources": [ { "resource": "update.settings", "id": "windowsupdate",
    "data": { "TargetReleaseVersion": 1, "TargetReleaseVersionInfo": "26100", "ProductVersion": "Windows 11" } } ] }
"@)
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'applied') { throw "status $($report.results[0].Status): $($report.results[0].Evidence)" }
  $read = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
  if ($read.TargetReleaseVersion -ne 1 -or $read.TargetReleaseVersionInfo -ne '26100') { throw 'read-back mismatch' }
  Undo-FleetPlan -PlanId 'el-wu-1' | Out-Null
  $residue = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'TargetReleaseVersion' -ErrorAction SilentlyContinue
  if ($residue) { throw 'policy keys residue after undo' }
  return 'policy triple written, verified, reversed'
}

# --- policy.setting through the executor (Home: direct Policies writes) --
Invoke-FleetCheck -Surface 'GroupPolicy' -Check 'executor writes policy values with the edition-appropriate engine' -Body {
  $plan = ConvertFrom-Json (@"
{ "planVersion": 1, "planId": "el-pol-1", "fleetId": "f", "machineId": "m", "mode": "apply",
  "resources": [ { "resource": "policy.setting", "id": "windowsupdate-au",
    "data": { "scope": "machine", "engineMode": "auto",
      "values": [ { "keyPath": "SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "valueName": "NoAutoRebootWithLoggedOnUsers", "type": "REG_DWORD", "data": 1 } ] } } ] }
"@)
  $report = Invoke-FleetPlan -Plan $plan
  $row = $report.results[0]
  if ($row.Status -notin @('applied', 'unchanged')) { throw "status $($row.Status): $($row.Evidence)" }
  $edition = Get-FleetEdition
  $evidence = "edition $edition; engine: $($row.Evidence)"
  if ($edition -eq 'Home') {
    $read = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoRebootWithLoggedOnUsers' -ErrorAction SilentlyContinue).NoAutoRebootWithLoggedOnUsers
    if ($read -ne 1) { throw "direct value missing: $read" }
    $evidence += '; direct value verified'
  }
  Undo-FleetPlan -PlanId 'el-pol-1' | Out-Null
  $residue = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoRebootWithLoggedOnUsers' -ErrorAction SilentlyContinue
  if ($residue) { throw 'policy value residue after undo' }
  $evidence += '; reversed'
  return $evidence
}

# --- task.scheduled through the executor -------------------------------
Invoke-FleetCheck -Surface 'ScheduledTask' -Check 'executor registers, replaces, and reverses a task' -Body {
  $plan = @{
    planVersion = 1; planId = 'el-task-1'; fleetId = 'f'; machineId = 'm'; mode = 'apply'
    resources   = @(
      @{ resource = 'task.scheduled'; id = '\FleetTestTask'; ensure = 'present'
         data = @{ path = '\'; name = 'FleetTestTask'; action = @{ execute = 'cmd.exe'; arguments = '/c exit 0' }; trigger = @{ onceAt = 'now+1h' } } }
    )
  }
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'applied') { throw "status $($report.results[0].Status): $($report.results[0].Evidence)" }
  $task = Get-ScheduledTask -TaskName 'FleetTestTask' -TaskPath '\' -ErrorAction SilentlyContinue
  if (-not $task) { throw 'task not present after apply' }
  $undone = Undo-FleetPlan -PlanId 'el-task-1'
  if ($undone -ne 1) { throw "undo reversed $undone" }
  if (Get-ScheduledTask -TaskName 'FleetTestTask' -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'task still present after undo' }
  return 'task registered via executor and reversed from the journal'
}

# --- package.winget through the executor --------------------------------
Invoke-FleetCheck -Surface 'winget' -Check 'executor installs, upgrades, and reverses a probe package' -Body {
  $candidates = @('7zip.7zip', 'jqlang.jq', 'MikeFarah.yq')
  $winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
  if (-not $winget) { $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe' }

  # Clean up any probe package left behind if a previous test run failed before undo:
  foreach ($p in @('jqlang.jq', 'MikeFarah.yq')) {
    Invoke-TimeboxedFleet -FileName $winget `
      -Arguments @('uninstall', '--id', $p, '--exact', '--silent', '--disable-interactivity') -TimeoutSec 180 | Out-Null
  }

  $pkgId = $null
  foreach ($c in $candidates) {
    $lp = Invoke-TimeboxedFleet -FileName $winget `
      -Arguments @('list', '--id', $c, '--exact', '--accept-source-agreements', '--disable-interactivity') -TimeoutSec 180
    if ((-not $lp.TimedOut) -and ($lp.Output -match 'No installed package found')) { $pkgId = $c; break }
  }
  if (-not $pkgId) { return 'all probe packages already installed by the user; software preserved' }

  $plan = @{
    planVersion = 1; planId = 'el-pkg-1'; fleetId = 'f'; machineId = 'm'; mode = 'apply'
    resources   = @(
      @{ resource = 'package.winget'; id = $pkgId; ensure = 'present'
         data = @{ packageId = $pkgId; scope = 'machine'; version = 'latest' } }
    )
  }
  $report = Invoke-FleetPlan -Plan $plan
  $row = $report.results[0]
  if ($row.Status -ne 'applied') { throw "status $($row.Status): $($row.Evidence)" }
  $installed = Invoke-TimeboxedFleet -FileName $winget `
    -Arguments @('list', '--id', $pkgId, '--exact', '--accept-source-agreements', '--disable-interactivity') -TimeoutSec 180
  if ($installed.Output -match 'No installed package found') { throw "$pkgId not installed after apply" }

  # Idempotent re-apply: latest is installed; the upgrade path maps the
  # no-applicable-update exit code to unchanged.
  $report2 = Invoke-FleetPlan -Plan $plan
  $row2 = $report2.results[0]
  if ($row2.Status -ne 'unchanged') { throw "second apply status $($row2.Status): $($row2.Evidence)" }

  $undone = Undo-FleetPlan -PlanId 'el-pkg-1'
  if ($undone -lt 1) { throw "undo reversed $undone" }
  $gone = Invoke-TimeboxedFleet -FileName $winget `
    -Arguments @('list', '--id', $pkgId, '--exact', '--accept-source-agreements', '--disable-interactivity') -TimeoutSec 180
  if ($gone.Output -notmatch 'No installed package found') { throw "$pkgId still installed after undo" }
  return "$pkgId installed via executor, idempotent re-apply unchanged, reversed from the journal"
}

# --- teardown and persist ------------------------------------------------
if (Test-Path 'HKLM:\SOFTWARE\FleetTest') { Remove-Item 'HKLM:\SOFTWARE\FleetTest' -Recurse -Force }
Get-ScheduledTask -TaskName 'FleetTestTask' -TaskPath '\' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

$outDir = Join-Path $env:TEMP 'fleet-tests'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Complete-FleetTestRun -OutFile (Join-Path $outDir 'elevated-results.json') | Out-Null
Set-Content -Path (Join-Path $outDir 'done.flag') -Value 'done' -Encoding ASCII
Write-Output 'ELEVATED TIER COMPLETE'
exit 0
