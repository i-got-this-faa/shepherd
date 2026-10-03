# System tier (non-elevated): executes a whole plan document through the
# reference executor — audit purity, apply, idempotency, drift detection,
# journal reversal, and dependsOn execution ordering.

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\FleetTest\FleetTest.psm1') -Force
Initialize-FleetTestRun -Name 'system'

$probePath = 'HKLM\SOFTWARE\FleetTest\SystemProbe'
$psPath = 'Registry::HKEY_USERS\' + (Get-FleetCurrentUserSid) + '\SOFTWARE\FleetTest\SystemProbe'
$markerFile = Join-Path $env:TEMP ('fleet-system-marker-' + [guid]::NewGuid().ToString('N') + '.txt')
Initialize-FleetJournal

if (Test-Path $psPath) { Remove-Item -Path $psPath -Recurse -Force }
Remove-Item $markerFile -Force -ErrorAction SilentlyContinue

$sid = Get-FleetCurrentUserSid
$content = "`$a = (Get-ItemProperty 'Registry::HKEY_USERS\$sid\SOFTWARE\FleetTest\SystemProbe').Alpha; " +
  "`$b = (Get-ItemProperty 'Registry::HKEY_USERS\$sid\SOFTWARE\FleetTest\SystemProbe').Beta; " +
  "Set-Content -Path '$markerFile' -Value ('alpha=' + `$a + ';beta=' + `$b) -Encoding ASCII; exit 0"

function New-Plan {
  param([string]$PlanId, [string]$Mode)
  return @{
    planVersion = 1
    planId      = $PlanId
    fleetId     = 'fleet-tests'
    machineId   = 'local'
    mode        = $Mode
    resources   = @(
      @{ resource = 'registry.value'; id = $probePath; ensure = 'present'; userSid = $sid
         data = @{ valueName = 'Alpha'; type = 'REG_SZ'; data = 'one' } }
      @{ resource = 'registry.value'; id = $probePath; ensure = 'present'; userSid = $sid
         data = @{ valueName = 'Beta'; type = 'REG_DWORD'; data = 42 } }
      @{ resource = 'script.fleet'; id = 'collect'
         data = @{ content = $content; expectedExitCodes = @(0) }
         dependsOn = @("registry.value:$probePath"); timeoutSec = 60 }
    )
  }
}

Invoke-FleetCheck -Surface 'System' -Check 'plan validates before execution' -Body {
  $v = Test-FleetPlan -Plan (New-Plan -PlanId 'e2e-1' -Mode 'apply')
  if (-not $v.Valid) { throw ($v.Errors -join '; ') }
  return 'e2e plan valid (2 registry values + script with dependsOn)'
}

Invoke-FleetCheck -Surface 'System' -Check 'audit run reports drift and performs zero writes' -Body {
  $report = Invoke-FleetPlan -Plan (New-Plan -PlanId 'e2e-audit' -Mode 'audit')
  if ($report.mode -ne 'audit') { throw "mode $($report.mode)" }
  $statuses = @($report.results | ForEach-Object Status)
  if ($statuses[0] -ne 'drifted' -or $statuses[1] -ne 'drifted') { throw "registry rows: $($statuses -join ',')" }
  if ($statuses[2] -ne 'unchanged') { throw "script row in audit should be unchanged (non-convergent): $($statuses[2])" }
  if ((Get-FleetJournalWriteCount -PlanId 'e2e-audit') -ne 0) { throw 'audit wrote journal entries' }
  if (Test-Path $markerFile) { throw 'audit ran the script' }
  return 'drifted/drifted/unchanged; zero writes; script not run'
}

Invoke-FleetCheck -Surface 'System' -Check 'apply converges and the script observes the applied state' -Body {
  $report = Invoke-FleetPlan -Plan (New-Plan -PlanId 'e2e-apply' -Mode 'apply')
  $statuses = @($report.results | ForEach-Object Status)
  if ($statuses -contains 'failed' -or $statuses -contains 'drifted') { throw "statuses: $($statuses -join ',')" }
  $marker = Get-Content $markerFile -Raw
  if ($marker -notmatch 'alpha=one;beta=42') { throw "marker '$marker' proves wrong ordering or state" }
  if ((Get-FleetJournalWriteCount -PlanId 'e2e-apply') -ne 2) { throw "expected 2 journal writes, got $(Get-FleetJournalWriteCount -PlanId 'e2e-apply')" }
  return "marker: $($marker.Trim())"
}

Invoke-FleetCheck -Surface 'System' -Check 'second apply is fully unchanged and writes nothing' -Body {
  $report = Invoke-FleetPlan -Plan (New-Plan -PlanId 'e2e-apply2' -Mode 'apply')
  $statuses = @($report.results | ForEach-Object Status)
  # script.fleet is non-convergent: every apply runs it and reports applied.
  if (($statuses -join ',') -ne 'unchanged,unchanged,applied') { throw "statuses: $($statuses -join ',')" }
  if ((Get-FleetJournalWriteCount -PlanId 'e2e-apply2') -ne 0) { throw 'idempotent apply wrote journal entries' }
  return 'registry idempotent; script re-runs by design; zero journal writes'
}

Invoke-FleetCheck -Surface 'System' -Check 'out-of-band mutation is detected as drift' -Body {
  Set-ItemProperty -Path $psPath -Name Beta -Value 43 -Type DWord
  $report = Invoke-FleetPlan -Plan (New-Plan -PlanId 'e2e-drift' -Mode 'audit')
  if ($report.results[1].Status -ne 'drifted') { throw "beta $($report.results[1].Status)" }
  if ($report.results[0].Status -ne 'unchanged') { throw "alpha $($report.results[0].Status)" }
  return 'beta drifted, alpha unchanged'
}

Invoke-FleetCheck -Surface 'System' -Check 'apply repairs the drift and undo returns to the mutated state' -Body {
  $report = Invoke-FleetPlan -Plan (New-Plan -PlanId 'e2e-repair' -Mode 'apply')
  if ($report.results[1].Status -ne 'applied') { throw "beta $($report.results[1].Status)" }
  $read = (Get-ItemProperty -Path $psPath -Name Beta).Beta
  if ($read -ne 42) { throw "beta repaired to $read" }
  $undone = Undo-FleetPlan -PlanId 'e2e-repair'
  if ($undone -ne 1) { throw "undo reversed $undone entries" }
  $after = (Get-ItemProperty -Path $psPath -Name Beta -ErrorAction SilentlyContinue).Beta
  if ($after -ne 43) { throw "after undo beta=$after, expected the pre-plan value 43" }
  return 'repair then journal reversal verified (43 -> 42 -> 43)'
}

Invoke-FleetCheck -Surface 'System' -Check 'report conforms to the report schema' -Body {
  $report = Invoke-FleetPlan -Plan (New-Plan -PlanId 'e2e-schema' -Mode 'audit')
  if ($report.reportVersion -ne 1) { throw 'reportVersion' }
  if (-not $report.planId -or -not $report.machineId) { throw 'ids missing' }
  if ($report.rebootRequired -isnot [bool]) { throw 'rebootRequired not bool' }
  foreach ($r in $report.results) {
    if (-not $r.ResourceId) { throw 'result missing ResourceId' }
    if ($r.Status -notin @('applied', 'unchanged', 'failed', 'unsupported', 'blocked', 'drifted')) { throw "bad status $($r.Status)" }
    if ($r.DurationMs -lt 0) { throw 'negative duration' }
  }
  return "report schema valid for $($report.results.Count) results"
}

# --- Agent CLI E2E: run-once through the real CLI as a child process. ---
Invoke-FleetCheck -Surface 'AgentCLI' -Check 'run-once applies a plan file and writes a conforming report' -Body {
  $cli = Join-Path $PSScriptRoot '..\..\..\..\apps\node-daemon\reference\powershell\fleet-agent-cli.ps1'
  $sid = Get-FleetCurrentUserSid
  $planPath = Join-Path $env:TEMP ('fleet-cli-plan-' + [guid]::NewGuid().ToString('N') + '.json')
  $reportPath = Join-Path $env:TEMP ('fleet-cli-report-' + [guid]::NewGuid().ToString('N') + '.json')
  $probeKey = 'HKLM\SOFTWARE\FleetTest\CliProbe'
  # Build as a hashtable and serialize: ConvertTo-Json escapes the
  # backslashes in registry paths correctly.
  $plan = @{
    planVersion = 1; planId = 'cli-1'; fleetId = 'fleet-tests'; machineId = 'local'; mode = 'apply'
    resources   = @(
      @{ resource = 'registry.value'; id = $probeKey; ensure = 'present'; userSid = $sid
         data = @{ valueName = 'Via'; type = 'REG_SZ'; data = 'cli' } }
    )
  }
  $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $planPath -Encoding UTF8
  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Command run-once -PlanPath $planPath -ReportPath $reportPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CLI exit $LASTEXITCODE" }
    $report = Get-Content $reportPath -Raw | ConvertFrom-Json
    if ($report.reportVersion -ne 1) { throw 'report schema' }
    if ($report.results[0].Status -ne 'applied') { throw "status $($report.results[0].Status)" }
    $psPath = 'Registry::HKEY_USERS\' + $sid + '\SOFTWARE\FleetTest\CliProbe'
    $read = (Get-ItemProperty -Path $psPath -Name Via -ErrorAction SilentlyContinue).Via
    if ($read -ne 'cli') { throw "read back '$read'" }
    return 'CLI run-once applied plan; report written and validated'
  }
  finally {
    Remove-Item $planPath, $reportPath -Force -ErrorAction SilentlyContinue
    Remove-Item ('Registry::HKEY_USERS\' + $sid + '\SOFTWARE\FleetTest\CliProbe') -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Invoke-FleetCheck -Surface 'AgentCLI' -Check 'audit command reports drift without applying' -Body {
  $cli = Join-Path $PSScriptRoot '..\..\..\..\apps\node-daemon\reference\powershell\fleet-agent-cli.ps1'
  $sid = Get-FleetCurrentUserSid
  $planPath = Join-Path $env:TEMP ('fleet-cli-plan-' + [guid]::NewGuid().ToString('N') + '.json')
  $reportPath = Join-Path $env:TEMP ('fleet-cli-report-' + [guid]::NewGuid().ToString('N') + '.json')
  $plan = @{
    planVersion = 1; planId = 'cli-2'; fleetId = 'fleet-tests'; machineId = 'local'; mode = 'audit'
    resources   = @(
      @{ resource = 'registry.value'; id = 'HKLM\SOFTWARE\FleetTest\CliAudit'; ensure = 'present'; userSid = $sid
         data = @{ valueName = 'Via'; type = 'REG_SZ'; data = 'audit' } }
    )
  }
  $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $planPath -Encoding UTF8
  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Command audit -PlanPath $planPath -ReportPath $reportPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CLI exit $LASTEXITCODE" }
    $report = Get-Content $reportPath -Raw | ConvertFrom-Json
    if ($report.results[0].Status -ne 'drifted') { throw "status $($report.results[0].Status)" }
    $exists = Test-Path ('Registry::HKEY_USERS\' + $sid + '\SOFTWARE\FleetTest\CliAudit')
    if ($exists) { throw 'audit created the probe key' }
    return 'CLI audit reported drifted; nothing applied'
  }
  finally {
    Remove-Item $planPath, $reportPath -Force -ErrorAction SilentlyContinue
    Remove-Item ('Registry::HKEY_USERS\' + $sid + '\SOFTWARE\FleetTest\CliAudit') -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Invoke-FleetCheck -Surface 'AgentCLI' -Check 'status command reports state from the last applied plan' -Body {
  $cli = Join-Path $PSScriptRoot '..\..\..\..\apps\node-daemon\reference\powershell\fleet-agent-cli.ps1'
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Command status
  if ($LASTEXITCODE -ne 0) { throw "CLI exit $LASTEXITCODE" }
  $text = ($out | Out-String).Trim()
  if (-not $text) { throw 'status returned empty output' }
  return "CLI status succeeded: $($text -split "`r?`n" | Select-Object -First 1)"
}

# Teardown.
if (Test-Path $psPath) { Remove-Item -Path $psPath -Recurse -Force }
Remove-Item $markerFile -Force -ErrorAction SilentlyContinue

$outDir = Join-Path $env:TEMP 'fleet-tests'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
exit (Complete-FleetTestRun -OutFile (Join-Path $outDir 'system-results.json'))
