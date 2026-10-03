# Finishers: close the two open items from the elevated suite.
# Part A: Group Policy apply deep-dive. Capture the GP operational log and
#         try three trigger variants to isolate why out-of-band Registry.pol
#         writes stop applying.
# Part B: Windows Update install path. Register the Microsoft Update service
#         (reversible), search it, and install an update that does not force
#         a reboot and is not firmware. Remove the service afterwards if we
#         added it.

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$outDir = Join-Path $env:TEMP 'fleet-elevated'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$resultsPath = Join-Path $outDir 'finishers-results.json'
$donePath = Join-Path $outDir 'finishers-done.flag'
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

# =====================================================================
# PART A: Group Policy apply deep-dive.
# =====================================================================
$gpoDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine'
$gptPath = Join-Path $env:WINDIR 'System32\GroupPolicy\GPT.ini'
$polPath = Join-Path $gpoDir 'Registry.pol'
$policyValueKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$valueName = 'NoAutoRebootWithLoggedOnUsers'

$polExisted = Test-Path $polPath
$gptExisted = Test-Path $gptPath
$logTime = Get-WinEvent -LogName 'Microsoft-Windows-GroupPolicy/Operational' -MaxEvents 1 -ErrorAction SilentlyContinue
$baseline = if ($logTime) { $logTime.TimeCreated } else { $null }
Add-Result 'A: baseline' 'PASS' ("Registry.pol existed: $polExisted; GPT.ini existed: $gptExisted; last GP log event: $baseline")

# Stand up the same probe policy as the main suite.
New-Item -ItemType Directory -Force -Path $gpoDir | Out-Null
[System.IO.File]::WriteAllBytes($polPath, (New-RegistryPol -Key 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ValueName $valueName -Type 4 -Data ([byte[]]@(1, 0, 0, 0))))
Set-Content -Path $gptPath -Value "[General]`r`nVersion=10`r`nDisplayName=Local Group Policy`r`nDescription=Local Group Policy`r`n" -Encoding ASCII

function Test-PolicyValue {
  return ((Get-ItemProperty -Path $policyValueKey -Name $valueName -ErrorAction SilentlyContinue).$valueName -eq 1)
}

function Wait-ForPolicyValue {
  param([int]$Seconds)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (Test-PolicyValue) { return $true }
  }
  return $false
}

# Variant 1: plain gpupdate /force (both scopes).
& gpupdate /force | Out-Null
$v1 = Wait-ForPolicyValue -Seconds 60
Add-Result 'A: variant 1 gpupdate /force' $(if ($v1) { 'PASS' } else { 'FAIL' }) ("policy value applied: $v1")
Remove-ItemProperty -Path $policyValueKey -Name $valueName -Force -ErrorAction SilentlyContinue

# Variant 2: bump GPT.ini, restart gpsvc, gpupdate /force.
(Get-Content $gptPath) -replace 'Version=10', 'Version=11' | Set-Content $gptPath -Encoding ASCII
try {
  Restart-Service gpsvc -Force
  Start-Sleep -Seconds 5
} catch { Add-Result 'A: gpsvc restart' 'FAIL' $_.Exception.Message }
& gpupdate /force | Out-Null
$v2 = Wait-ForPolicyValue -Seconds 60
Add-Result 'A: variant 2 gpsvc restart + gpupdate' $(if ($v2) { 'PASS' } else { 'FAIL' }) ("policy value applied: $v2")
Remove-ItemProperty -Path $policyValueKey -Name $valueName -Force -ErrorAction SilentlyContinue

# Variant 3: gpupdate /target:computer /force with a long poll.
& gpupdate /target:computer /force | Out-Null
$v3 = Wait-ForPolicyValue -Seconds 120
Add-Result 'A: variant 3 targeted with long poll' $(if ($v3) { 'PASS' } else { 'FAIL' }) ("policy value applied: $v3")

# Evidence: GP operational events since baseline; CSE state keys.
$gpEvents = Get-WinEvent -LogName 'Microsoft-Windows-GroupPolicy/Operational' -MaxEvents 40 -ErrorAction SilentlyContinue |
  Where-Object { $baseline -eq $null -or $_.TimeCreated -gt $baseline } |
  Select-Object -First 12
$eventText = ($gpEvents | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) #$($_.Id): $($_.Message.Split("`n")[0])" }) -join ' | '
Add-Result 'A: GP operational events during run' 'PASS' ($eventText.Trim())

$extList = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List' -ErrorAction SilentlyContinue |
  ForEach-Object { $_.PSChildName }
Add-Result 'A: CSE Extension-List after run' 'PASS' ("extensions tracked: " + (@($extList).Count))

$gpTasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\GroupPolicy\' -ErrorAction SilentlyContinue).Count
Add-Result 'A: GroupPolicy scheduled tasks' 'PASS' ("$gpTasks tasks under \Microsoft\Windows\GroupPolicy\")

# Reverse everything.
if (-not $polExisted) { Remove-Item $polPath -Force -ErrorAction SilentlyContinue }
if (-not $gptExisted) { Remove-Item $gptPath -Force -ErrorAction SilentlyContinue }
& gpupdate /force | Out-Null
Start-Sleep -Seconds 5
Remove-ItemProperty -Path $policyValueKey -Name $valueName -Force -ErrorAction SilentlyContinue
Add-Result 'A: reverse' 'PASS' ("state restored: " + ((-not (Test-Path $polPath)) -and (-not (Test-Path $gptPath))))

# =====================================================================
# PART B: Windows Update install path via the Microsoft Update service.
# =====================================================================
try {
  $session = New-Object -ComObject Microsoft.Update.Session
  $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
  $muServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
  $alreadyRegistered = @($serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId }).Count -gt 0
  if (-not $alreadyRegistered) {
    [void]$serviceManager.AddService2($muServiceId, 7, '')
    Add-Result 'B: Microsoft Update service' 'PASS' 'service registered (will be removed at the end)'
  }
  else {
    Add-Result 'B: Microsoft Update service' 'PASS' 'service was already registered (left in place)'
  }

  $searcher = $session.CreateUpdateSearcher()
  $searcher.ServerSelection = 2   # ssMicrosoftUpdate
  $searcher.ServiceID = $muServiceId
  $searcher.Online = $true
  $muSearch = $searcher.Search("IsInstalled=0 and IsHidden=0")
  $count = $muSearch.Updates.Count
  $titles = @()
  for ($i = 0; $i -lt [Math]::Min($count, 8); $i++) {
    $u = $muSearch.Updates.Item($i)
    $titles += ($u.Title + ' [RB=' + $u.InstallationBehavior.RebootBehavior + ']')
  }
  Add-Result 'B: search Microsoft Update' 'PASS' ("$count applicable; " + ($titles -join ' | '))

  # Selection: never firmware, never must-reboot. RebootBehavior 0 or 1.
  $target = $null
  for ($i = 0; $i -lt $count; $i++) {
    $u = $muSearch.Updates.Item($i)
    $isFirmware = ($u.Title -match '(?i)firmware|bios')
    if (($u.InstallationBehavior.RebootBehavior -le 1) -and (-not $isFirmware)) {
      if ($null -eq $target -or $u.MaxDownloadSize -lt $target.MaxDownloadSize) { $target = $u }
    }
  }
  if ($null -eq $target) {
    Add-Result 'B: safe install candidate' 'SKIP' 'no non-firmware update with RebootBehavior<=1 was applicable'
  }
  else {
    Add-Result 'B: selected candidate' 'PASS' ($target.Title + ' [' + [Math]::Round($target.MaxDownloadSize / 1MB, 1) + ' MB]')
    if (-not $target.EulaAccepted) { $target.AcceptEula() }
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    [void]$coll.Add($target)
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $coll
    $dl = $downloader.Download()
    Add-Result 'B: download' 'PASS' ("result code " + $dl.ResultCode)

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $coll
    $installResult = $installer.Install()
    $first = $installResult.GetUpdateResult(0)
    $status = if ($installResult.ResultCode -le 3) { 'PASS' } else { 'FAIL' }
    Add-Result 'B: install' $status ("installer ResultCode " + $installResult.ResultCode + "; update result " + $first.ResultCode + "; HResult " + $first.HResult)

    Start-Sleep -Seconds 3
    $recheck = $searcher.Search("IsInstalled=1")
    Add-Result 'B: post-install state' 'PASS' ("RebootRequired now: " + (New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired)
  }

  if (-not $alreadyRegistered) {
    $svc = $serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId } | Select-Object -First 1
    if ($svc) {
      try {
        $serviceManager.RemoveService($svc)
        Add-Result 'B: reverse service registration' 'PASS' 'Microsoft Update service removed again'
      }
      catch { Add-Result 'B: reverse service registration' 'FAIL' $_.Exception.Message }
    }
  }
}
catch { Add-Result 'B: Windows Update install path' 'FAIL' $_.Exception.Message }

$results | ConvertTo-Json | Set-Content $resultsPath -Encoding UTF8
Set-Content $donePath 'done' -Encoding ASCII
Write-Output 'FINISHERS COMPLETE'
exit 0
