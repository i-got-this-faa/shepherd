# Fleet agent CLI. Commands:
#   run-once  -PlanPath <file> [-ReportPath <file>]   apply or audit a plan
#   audit     -PlanPath <file>                        audit without applying
#   drift                                             audit the last applied plan
#   status                                            show last plan/report state
#   install-service | uninstall-service               manage the FleetAgent service
#   version
#
# Exit code 0 only when the command succeeded and no resource failed.

#Requires -Version 5.1

param(
  [Parameter(Mandatory)][string]$Command,
  [string]$PlanPath,
  [string]$ReportPath,
  [string]$ConfigPath
)

$agentRoot = $PSScriptRoot
Import-Module (Join-Path $agentRoot 'FleetAgent.psm1') -Force

$stateDir = Join-Path $env:ProgramData 'Fleet\state'
$settings = @{
  StateDir    = $stateDir
  JournalPath = Join-Path $env:ProgramData 'Fleet\journal\journal.jsonl'
}

function Get-FleetCliSummary {
  param($Report)
  # The foreach statement enumerates the results list directly; the @()
  # array operator on this List[object] throws in PS 5.1.
  $parts = @()
  foreach ($r in $Report.results) {
    $parts += ([string]$r.ResourceId + '=' + [string]$r.Status)
  }
  return ($parts -join '; ')
}

try {
  switch ($Command) {
  'version' {
    Write-Output 'fleet-agent 1.0.0 (PowerShell reference implementation)'
    exit 0
  }
  'run-once' {
    if (-not $PlanPath) { Write-Error 'run-once requires -PlanPath'; exit 2 }
    $plan = Get-Content $PlanPath -Raw | ConvertFrom-Json
    $report = Invoke-FleetAgentPlan -Plan $plan -Settings $settings
    $reportOut = if ($ReportPath) { $ReportPath } else { Join-Path $stateDir 'last-report.json' }
    $report | ConvertTo-Json -Depth 10 | Set-Content $reportOut -Encoding UTF8
    Save-FleetAgentState -StateDir $stateDir -Plan $plan -Report $report
    $summary = Get-FleetCliSummary -Report $report
    Write-Output "plan $($report.planId): $summary"
    $failed = @($report.results | Where-Object Status -in @('failed', 'blocked')).Count
    if ($failed -gt 0) { exit 1 }
    exit 0
  }
  'audit' {
    if (-not $PlanPath) { Write-Error 'audit requires -PlanPath'; exit 2 }
    $plan = Get-Content $PlanPath -Raw | ConvertFrom-Json
    $plan.mode = 'audit'
    $report = Invoke-FleetAgentPlan -Plan $plan -Settings $settings
    $reportOut = if ($ReportPath) { $ReportPath } else { Join-Path $stateDir 'last-audit.json' }
    $report | ConvertTo-Json -Depth 10 | Set-Content $reportOut -Encoding UTF8
    $summary = Get-FleetCliSummary -Report $report
    Write-Output "audit $($report.planId): $summary"
    exit 0
  }
  'drift' {
    $report = Invoke-FleetAgentDrift -StateDir $stateDir -ReportPath (Join-Path $stateDir 'last-drift.json')
    if ($null -eq $report) { Write-Output 'no plan has been applied yet'; exit 0 }
    $summary = Get-FleetCliSummary -Report $report
    Write-Output "drift $($report.planId): $summary"
    exit 0
  }
  'status' {
    $lastReport = Join-Path $stateDir 'last-report.json'
    if (Test-Path $lastReport) {
      $r = Get-Content $lastReport -Raw | ConvertFrom-Json
      Write-Output ("last plan: $($r.planId) mode=$($r.mode) rebootRequired=$($r.rebootRequired)")
      $r.results | ForEach-Object { Write-Output ("  $($_.ResourceId) = $($_.Status)") }
    }
    else { Write-Output 'no plan applied yet' }
    exit 0
  }
  'install-service' {
    $serviceScript = Join-Path $agentRoot 'agent-service.ps1'
    $binPath = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$serviceScript`""
    if (Get-Service -Name 'FleetAgent' -ErrorAction SilentlyContinue) {
      Write-Output 'FleetAgent service already installed'
      exit 0
    }
    New-Service -Name 'FleetAgent' -BinaryPathName $binPath -DisplayName 'Fleet Agent' -StartupType Automatic -ErrorAction Stop | Out-Null
    # Recovery: restart after 60s, three attempts, reset after one day.
    & sc.exe failure FleetAgent reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    Write-Output 'FleetAgent service installed (Automatic, recovery restart x3)'
    exit 0
  }
  'uninstall-service' {
    $svc = Get-Service -Name 'FleetAgent' -ErrorAction SilentlyContinue
    if ($svc) {
      Stop-Service -Name 'FleetAgent' -Force -ErrorAction SilentlyContinue
      & sc.exe delete FleetAgent | Out-Null
      Write-Output 'FleetAgent service removed'
    }
    else { Write-Output 'FleetAgent service not present' }
    exit 0
  }
  default {
    Write-Error "unknown command '$Command'"
    exit 2
  }
}
}
catch {
  Write-Error ($_.Exception.Message + ' | at ' + $_.InvocationInfo.PositionMessage + ' | ' + $_.ScriptStackTrace)
  exit 1
}
