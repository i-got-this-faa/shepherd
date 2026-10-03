# Experiment: does the Group Policy registry CSE require a GPT.ini version
# bump to process an out-of-band Registry.pol write?
# Phase 1: write Registry.pol alone, gpupdate, observe.
# Phase 2: add GPT.ini with a machine revision, bump it, gpupdate, observe.
# Everything is reversed at the end.

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'
$outDir = Join-Path $env:TEMP 'fleet-elevated'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$resultsPath = Join-Path $outDir 'gptini-results.json'
$donePath = Join-Path $outDir 'gptini-done.flag'
Remove-Item $resultsPath, $donePath -Force -ErrorAction SilentlyContinue

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param([string]$Check, [string]$Status, [string]$Evidence)
  $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Evidence = $Evidence })
  Write-Output ("[{0}] {1} :: {2}" -f $Status, $Check, $Evidence)
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Add-Result 'Elevation' 'FAIL' 'not elevated'
  $results | ConvertTo-Json | Set-Content $resultsPath -Encoding UTF8
  Set-Content $donePath 'done' -Encoding ASCII
  exit 1
}

function New-RegistryPol {
  param([string]$Key, [string]$ValueName, [int]$Type, [byte[]]$Data)
  $keyBytes = [System.Text.Encoding]::Unicode.GetBytes($Key)
  $valBytes = [System.Text.Encoding]::Unicode.GetBytes($ValueName)
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([byte[]]@(0x50, 0x52, 0x65, 0x67))
  $bw.Write([uint32]1)
  $bw.Write([uint16]$keyBytes.Length); $bw.Write($keyBytes)
  $bw.Write([uint16]$valBytes.Length); $bw.Write($valBytes)
  $bw.Write([uint16]$Type)
  $bw.Write([uint32]$Data.Length); $bw.Write($Data)
  $bw.Flush()
  return $ms.ToArray()
}

$gpoDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine'
$polPath = Join-Path $gpoDir 'Registry.pol'
$gptPath = Join-Path $env:WINDIR 'System32\GroupPolicy\GPT.ini'
$policyValueKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$valueName = 'NoAutoRebootWithLoggedOnUsers'

$polExisted = Test-Path $polPath
$gptExisted = Test-Path $gptPath
Add-Result 'Baseline' 'PASS' ("Registry.pol existed: $polExisted; GPT.ini existed: $gptExisted")

function Wait-ForPolicyValue {
  param([int]$Seconds)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $v = (Get-ItemProperty -Path $policyValueKey -Name $valueName -ErrorAction SilentlyContinue).$valueName
    if ($v -eq 1) { return $true }
  }
  return $false
}

# --- Phase 1: Registry.pol alone, no GPT.ini.
New-Item -ItemType Directory -Force -Path $gpoDir | Out-Null
[System.IO.File]::WriteAllBytes($polPath, (New-RegistryPol -Key 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ValueName $valueName -Type 4 -Data ([byte[]]@(1, 0, 0, 0))))
& gpupdate /target:computer /force | Out-Null
$phase1 = Wait-ForPolicyValue -Seconds 60
Add-Result 'Phase 1: Registry.pol without GPT.ini' $(if ($phase1) { 'PASS' } else { 'FAIL' }) ("policy value applied: $phase1")

# Clean the applied value so phase 2 starts from zero (keep Registry.pol).
Remove-ItemProperty -Path $policyValueKey -Name $valueName -Force -ErrorAction SilentlyContinue

# --- Phase 2: with a GPT.ini machine revision, bumped between applies.
$gptContent = @"
[General]
Version=1
DisplayName=Local Group Policy
Description=Local Group Policy
"@
Set-Content -Path $gptPath -Value $gptContent -Encoding ASCII
& gpupdate /target:computer /force | Out-Null
$phase2 = Wait-ForPolicyValue -Seconds 60
Add-Result 'Phase 2a: GPT.ini Version=1' $(if ($phase2) { 'PASS' } else { 'FAIL' }) ("policy value applied: $phase2")

Remove-ItemProperty -Path $policyValueKey -Name $valueName -Force -ErrorAction SilentlyContinue
(Get-Content $gptPath) -replace 'Version=1', 'Version=2' | Set-Content $gptPath -Encoding ASCII
& gpupdate /target:computer /force | Out-Null
$phase3 = Wait-ForPolicyValue -Seconds 60
Add-Result 'Phase 2b: GPT.ini Version bumped to 2' $(if ($phase3) { 'PASS' } else { 'FAIL' }) ("policy value applied: $phase3")

# --- Reverse everything.
if (-not $polExisted) { Remove-Item $polPath -Force -ErrorAction SilentlyContinue }
if (-not $gptExisted) { Remove-Item $gptPath -Force -ErrorAction SilentlyContinue }
& gpupdate /target:computer /force | Out-Null
Start-Sleep -Seconds 5
Remove-ItemProperty -Path $policyValueKey -Name $valueName -Force -ErrorAction SilentlyContinue
$clean = (-not (Test-Path $polPath)) -and (-not (Test-Path $gptPath)) -and
  (-not (Get-ItemProperty -Path $policyValueKey -Name $valueName -ErrorAction SilentlyContinue))
Add-Result 'Reverse' $(if ($clean) { 'PASS' } else { 'FAIL' }) ("machine state restored: $clean")

$results | ConvertTo-Json | Set-Content $resultsPath -Encoding UTF8
Set-Content $donePath 'done' -Encoding ASCII
Write-Output 'GPT.INI EXPERIMENT COMPLETE'
exit 0
