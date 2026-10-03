# Wrapper: run the elevated probe suite with a full transcript so a crash
# or a closed window still leaves evidence. Kills a stale probe run and any
# leftover winget process first.

param([int]$StalePid = 0)

if ($StalePid -gt 0) {
  Stop-Process -Id $StalePid -Force -ErrorAction SilentlyContinue
}
Get-Process -Name winget -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$outDir = Join-Path $env:TEMP 'fleet-elevated'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$log = Join-Path $outDir 'run.log'
Start-Transcript -Path $log -Force
try {
  & (Join-Path $PSScriptRoot 'test-windows-elevated.ps1')
}
finally {
  Stop-Transcript
}
