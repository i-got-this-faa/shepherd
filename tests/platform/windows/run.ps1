# Fleet Windows mapper test-suite orchestrator.
#
# Usage:
#   tests\platform\windows\run.ps1                  # unit + integration + system (non-elevated),
#                                  # merging elevated results when present
#   tests\platform\windows\run.ps1 -ElevatedOnly    # spawn the elevated tier (one UAC prompt),
#                                  # then re-run without the switch to merge
#
# Exit code 0 only when nothing failed. UNSUPPORTED counts as verified
# documented behavior; PENDING means the elevated tier has not run yet.

#Requires -Version 5.1

param([switch]$ElevatedOnly)

$testsRoot = $PSScriptRoot
$outDir = Join-Path $env:TEMP 'fleet-tests'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if ($ElevatedOnly) {
  Remove-Item (Join-Path $outDir 'done.flag') -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $outDir 'elevated-results.json') -Force -ErrorAction SilentlyContinue
  $wrapperPath = Join-Path $testsRoot 'elevated-wrapper.ps1'
  try {
    $p = Start-Process powershell -Verb RunAs -ArgumentList `
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath -PassThru -ErrorAction Stop
    Write-Output ("elevated tier launched (pid $($p.Id)); approve the UAC prompt. It writes $outDir\done.flag; then re-run tests\platform\windows\run.ps1 to merge.")
  }
  catch {
    try {
      $sh = New-Object -ComObject Shell.Application
      $sh.ShellExecute('powershell.exe', "-NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`"", '', 'runas', 1)
      Write-Output ("elevated tier launched via Shell.Application; approve the UAC prompt. It writes $outDir\done.flag; then re-run tests\platform\windows\run.ps1 to merge.")
    }
    catch {
      Write-Error ("Failed to launch elevated process: " + $_.Exception.Message)
    }
  }
  return
}

$tiers = @(
  @{ Name = 'unit';        File = Join-Path $testsRoot 'unit\unit.tests.ps1' },
  @{ Name = 'integration'; File = Join-Path $testsRoot 'integration\integration.tests.ps1' },
  @{ Name = 'system';      File = Join-Path $testsRoot 'system\system.tests.ps1' }
)

$tierExit = 0
foreach ($tier in $tiers) {
  Write-Output ''
  Write-Output "=== Tier: $($tier.Name) ==="
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tier.File
  if ($LASTEXITCODE -ne 0) { $tierExit = 1 }
}

Write-Output ''
$elevatedResultsPath = Join-Path $outDir 'elevated-results.json'
$elevatedDonePath = Join-Path $outDir 'done.flag'
if ((Test-Path $elevatedDonePath) -and (Test-Path $elevatedResultsPath)) {
  Write-Output '=== Elevated tier results (merged) ==='
  $elevated = Get-Content $elevatedResultsPath -Raw | ConvertFrom-Json
  $elevated | Format-Table Run, Surface, Check, Status, Evidence -AutoSize -Wrap
  $failed = @($elevated | Where-Object Status -eq 'FAIL').Count
  if ($failed -gt 0) { $tierExit = 1 }
}
else {
  Write-Output 'Elevated tier: PENDING (run tests\platform\windows\run.ps1 -ElevatedOnly and approve the UAC prompt)'
}

if ($tierExit -ne 0) { exit 1 }
exit 0
