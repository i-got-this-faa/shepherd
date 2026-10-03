# Fleet agent service loop. Runs as the FleetAgent service binary path
# (SYSTEM). Every 5 minutes: apply the plan in the state directory when a
# new one arrives; every 4 hours: run a drift pass. Reports land next to
# the plans for the control server to collect.

#Requires -Version 5.1

Import-Module (Join-Path $PSScriptRoot 'FleetAgent.psm1') -Force

$stateDir = Join-Path $env:ProgramData 'Fleet\state'
$settings = @{
  StateDir    = $stateDir
  JournalPath = Join-Path $env:ProgramData 'Fleet\journal\journal.jsonl'
}
Initialize-FleetAgentSettings -Settings $settings

$driftIntervalMinutes = 4 * 60
$lastDrift = (Get-Date).AddHours(-1)

while ($true) {
  try {
    $planPath = Join-Path $stateDir 'plan.json'
    $appliedMarker = Join-Path $stateDir 'last-plan.json'
    if ((Test-Path $planPath) -and ((Get-Item $planPath).LastWriteTimeUtc -gt (Get-Item $appliedMarker -ErrorAction SilentlyContinue).LastWriteTimeUtc -or -not (Test-Path $appliedMarker))) {
      $plan = Get-Content $planPath -Raw | ConvertFrom-Json
      $report = Invoke-FleetAgentPlan -Plan $plan
      Save-FleetAgentState -StateDir $stateDir -Plan $plan -Report $report
      $report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $stateDir 'last-report.json') -Encoding UTF8
    }
    if (((Get-Date) - $lastDrift).TotalMinutes -ge $driftIntervalMinutes) {
      Invoke-FleetAgentDrift -StateDir $stateDir -ReportPath (Join-Path $stateDir 'last-drift.json') | Out-Null
      $lastDrift = Get-Date
    }
  }
  catch {
    # The service never exits on error; the loop logs and continues.
    Write-EventLog -LogName Application -Source FleetAgent -EventId 1001 -EntryType Error -Message $_.Exception.Message -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 300
}
