# Integration tier (non-elevated): executor triples against synthetic
# per-user registry targets, audit purity, idempotency, reversal, and the
# failure taxonomy in a non-elevated context.

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\FleetTest\FleetTest.psm1') -Force
Initialize-FleetTestRun -Name 'integration'

$probePath = 'HKLM\SOFTWARE\FleetTest\ExecutorProbe'   # addressed via userSid -> HKEY_USERS\<sid>\...
$psPath = 'Registry::HKEY_USERS\' + (Get-FleetCurrentUserSid) + '\SOFTWARE\FleetTest\ExecutorProbe'

# Helper used only by this file (kept local to avoid polluting the module).
function Get-FleetRegistryValueStateLocal {
  param([string]$PsPath, [string]$ValueName)
  $key = Get-Item -Path $PsPath -ErrorAction SilentlyContinue
  if (-not $key) { return $null }
  return $key.GetValue($ValueName)
}

function New-RegistryPlan {
  param([string]$PlanId, [string]$Mode, [string]$Ensure)
  return @{
    planVersion = 1
    planId      = $PlanId
    fleetId     = 'fleet-tests'
    machineId   = 'local'
    mode        = $Mode
    resources   = @(
      @{ resource = 'registry.value'; id = $probePath; ensure = $Ensure
         userSid = (Get-FleetCurrentUserSid)
         data = @{ valueName = 'Alpha'; type = 'REG_SZ'; data = 'one' } }
    )
  }
}

# Fresh state for the run.
Initialize-FleetJournal
if (Test-Path $psPath) { Remove-Item -Path $psPath -Recurse -Force }

Invoke-FleetCheck -Surface 'Registry' -Check 'apply creates the value and journals it' -Body {
  $report = Invoke-FleetPlan -Plan (New-RegistryPlan -PlanId 'reg-1' -Mode 'apply' -Ensure 'present')
  $row = $report.results[0]
  if ($row.Status -ne 'applied') { throw "status $($row.Status): $($row.Evidence)" }
  $read = (Get-ItemProperty -Path $psPath -Name Alpha).Alpha
  if ($read -ne 'one') { throw "read back '$read'" }
  if ((Get-FleetJournalWriteCount -PlanId 'reg-1') -ne 1) { throw 'expected exactly one journal write' }
  $j = Get-FleetJournal | Select-Object -Last 1
  if ($null -ne $j.PreviousState.Value) { throw 'previous state should record absence as null' }
  return 'applied, read back through HKEY_USERS path, journaled with previous absence'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'second apply is unchanged and writes nothing' -Body {
  $report = Invoke-FleetPlan -Plan (New-RegistryPlan -PlanId 'reg-2' -Mode 'apply' -Ensure 'present')
  $row = $report.results[0]
  if ($row.Status -ne 'unchanged') { throw "status $($row.Status): $($row.Evidence)" }
  if ((Get-FleetJournalWriteCount -PlanId 'reg-2') -ne 0) { throw 'idempotent apply wrote journal entries' }
  return 'idempotent: unchanged with zero journal writes'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'audit detects drift and writes nothing' -Body {
  Set-ItemProperty -Path $psPath -Name Alpha -Value 'mutated-out-of-band'
  $report = Invoke-FleetPlan -Plan (New-RegistryPlan -PlanId 'reg-3' -Mode 'audit' -Ensure 'present')
  $row = $report.results[0]
  if ($row.Status -ne 'drifted') { throw "status $($row.Status): $($row.Evidence)" }
  if ((Get-FleetJournalWriteCount -PlanId 'reg-3') -ne 0) { throw 'audit wrote to the journal' }
  if ((Get-ItemProperty -Path $psPath -Name Alpha).Alpha -ne 'mutated-out-of-band') { throw 'audit changed live state' }
  return 'drift detected; live state untouched; zero writes'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'apply converges drifted state from the journaled previous' -Body {
  $report = Invoke-FleetPlan -Plan (New-RegistryPlan -PlanId 'reg-4' -Mode 'apply' -Ensure 'present')
  $row = $report.results[0]
  if ($row.Status -ne 'applied') { throw "status $($row.Status): $($row.Evidence)" }
  $j = Get-FleetJournal | Where-Object { $_.PlanId -eq 'reg-4' } | Select-Object -First 1
  if ($j.PreviousState.Value -ne 'mutated-out-of-band') { throw "journal previous '$($j.PreviousState.Value)'" }
  return 'converged; journal holds the drifted previous value'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'undo restores the pre-plan state' -Body {
  $undone = Undo-FleetPlan -PlanId 'reg-4'
  if ($undone -ne 1) { throw "undone $undone entries" }
  $read = (Get-ItemProperty -Path $psPath -Name Alpha -ErrorAction SilentlyContinue).Alpha
  if ($read -ne 'mutated-out-of-band') { throw "undo landed on '$read', expected the pre-plan drifted value" }
  $flags = @(Get-FleetJournal | Where-Object { $_.Reversed }).Count
  if ($flags -ne 1) { throw "reversed entries flagged: $flags" }
  return 'undo restored pre-plan state (journal-driven, plan-scoped)'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'ensure absent on a missing value is unchanged' -Body {
  Remove-ItemProperty -Path $psPath -Name Alpha -Force -ErrorAction SilentlyContinue
  $report = Invoke-FleetPlan -Plan (New-RegistryPlan -PlanId 'reg-5' -Mode 'apply' -Ensure 'absent')
  $row = $report.results[0]
  if ($row.Status -ne 'unchanged') { throw "status $($row.Status): $($row.Evidence)" }
  return 'absent-on-missing is unchanged'
}

Invoke-FleetCheck -Surface 'Registry' -Check 'absent removes an existing value and undo restores it' -Body {
  New-ItemProperty -Path $psPath -Name Alpha -Value 'keepme' -PropertyType String -Force | Out-Null
  $report = Invoke-FleetPlan -Plan (New-RegistryPlan -PlanId 'reg-6' -Mode 'apply' -Ensure 'absent')
  if ($report.results[0].Status -ne 'applied') { throw "status $($report.results[0].Status)" }
  if (Get-FleetRegistryValueStateLocal -PsPath $psPath -ValueName 'Alpha') { throw 'value still present' }
  Undo-FleetPlan -PlanId 'reg-6' | Out-Null
  $restored = (Get-ItemProperty -Path $psPath -Name Alpha).Alpha
  if ($restored -ne 'keepme') { throw "undo restored '$restored'" }
  return 'deleted then restored through the journal'
}

# Taxonomy: resources that cannot run in this context report unsupported.
Invoke-FleetCheck -Surface 'Taxonomy' -Check 'service.state reports unsupported when non-elevated' -Body {
  if (Test-FleetElevated) { return 'elevated context; the elevated tier exercises this instead' }
  $plan = @{
    planVersion = 1; planId = 'tax-1'; fleetId = 'f'; machineId = 'm'
    resources = @( @{ resource = 'service.state'; id = 'wuauserv'; data = @{ status = 'running' } } )
  }
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'unsupported') { throw "status $($report.results[0].Status)" }
  return $report.results[0].Evidence
}

Invoke-FleetCheck -Surface 'Taxonomy' -Check 'update.settings reports unsupported when non-elevated' -Body {
  if (Test-FleetElevated) { return 'elevated context; the elevated tier exercises this instead' }
  $plan = @{
    planVersion = 1; planId = 'tax-2'; fleetId = 'f'; machineId = 'm'
    resources = @( @{ resource = 'update.settings'; id = 'windowsupdate'; data = @{ TargetReleaseVersion = 1 } } )
  }
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'unsupported') { throw "status $($report.results[0].Status)" }
  return $report.results[0].Evidence
}

Invoke-FleetCheck -Surface 'Taxonomy' -Check 'policy.setting is unsupported by the reference executor' -Body {
  $plan = @{
    planVersion = 1; planId = 'tax-3'; fleetId = 'f'; machineId = 'm'
    resources = @( @{ resource = 'policy.setting'; id = 'admx:Something'; data = @{} } )
  }
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'unsupported') { throw "status $($report.results[0].Status)" }
  return $report.results[0].Evidence
}

Invoke-FleetCheck -Surface 'Taxonomy' -Check 'inventory.report works non-elevated' -Body {
  $plan = @{
    planVersion = 1; planId = 'tax-4'; fleetId = 'f'; machineId = 'm'
    resources = @( @{ resource = 'inventory.report'; id = 'os' } )
  }
  $report = Invoke-FleetPlan -Plan $plan
  if ($report.results[0].Status -ne 'unchanged') { throw "status $($report.results[0].Status): $($report.results[0].Evidence)" }
  return $report.results[0].Evidence
}

# Teardown.
if (Test-Path $psPath) { Remove-Item -Path $psPath -Recurse -Force }

$outDir = Join-Path $env:TEMP 'fleet-tests'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
exit (Complete-FleetTestRun -OutFile (Join-Path $outDir 'integration-results.json'))
