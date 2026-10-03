# Wrapper: run the elevated test tier with a transcript so a crash or a
# closed window still leaves evidence. Kills stale winget processes first.

param([int]$StalePid = 0)

if ($StalePid -gt 0) {
  Stop-Process -Id $StalePid -Force -ErrorAction SilentlyContinue
}
Get-Process -Name winget -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$outDir = Join-Path $env:TEMP 'fleet-tests'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Start-Transcript -Path (Join-Path $outDir 'elevated-run.log') -Force
try {
  & (Join-Path $PSScriptRoot 'elevated-runner.ps1')
}
finally {
  Stop-Transcript
}
