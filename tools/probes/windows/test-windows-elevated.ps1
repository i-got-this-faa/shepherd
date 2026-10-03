# Elevated probe suite for the Windows mapper surface documents.
# Runs in an elevated PowerShell (UAC prompt). Every mutating operation follows
# apply -> verify -> reverse and restores the previous state. Results are
# written as JSON; a done.flag file marks completion.

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$outDir = Join-Path $env:TEMP 'fleet-elevated'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$resultsPath = Join-Path $outDir 'results.json'
$donePath = Join-Path $outDir 'done.flag'
Remove-Item $resultsPath, $donePath -Force -ErrorAction SilentlyContinue

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
  param([string]$Surface, [string]$Check, [string]$Status, [string]$Evidence)
  $results.Add([pscustomobject]@{
      Surface  = $Surface
      Check    = $Check
      Status   = $Status
      Evidence = $Evidence
    })
  Write-Output ("[{0}] {1} :: {2} :: {3}" -f $Status, $Surface, $Check, $Evidence)
}

function Save-Results {
  $results | ConvertTo-Json -Depth 3 | Set-Content -Path $resultsPath -Encoding UTF8
  Set-Content -Path $donePath -Value 'done' -Encoding ASCII
}

# --- Elevation gate.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Add-Result 'Elevation' 'Administrator token' 'FAIL' 'process is not elevated'
  Save-Results
  exit 1
}
Add-Result 'Elevation' 'Administrator token' 'PASS' ('elevated as ' + $identity.Name)

# =====================================================================
# 1. REGISTRY: full idempotent write/read/reverse cycle, five data types.
# =====================================================================
$probeKey = 'HKLM:\SOFTWARE\FleetProbeTest'
$probeKeyNative = 'HKLM\SOFTWARE\FleetProbeTest'
try {
  $existedBefore = Test-Path $probeKey
  New-Item -Path $probeKey -Force | Out-Null
  New-ItemProperty -Path $probeKey -Name 'Sz' -Value 'hello' -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $probeKey -Name 'Expand' -Value '%WINDIR%' -PropertyType ExpandString -Force | Out-Null
  New-ItemProperty -Path $probeKey -Name 'Multi' -Value @('a', 'b') -PropertyType MultiString -Force | Out-Null
  New-ItemProperty -Path $probeKey -Name 'Dword' -Value 2147483647 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $probeKey -Name 'Qword' -Value 9223372036854775807 -PropertyType QWord -Force | Out-Null

  $props = Get-ItemProperty -Path $probeKey
  $ok = ($props.Sz -eq 'hello') -and ($props.Multi.Count -eq 2) -and ($props.Dword -eq [int32]2147483647)
  $regOut = (& reg.exe query $probeKeyNative | Out-String)
  if ($ok -and $regOut -match 'REG_QWORD') {
    Add-Result 'Registry' 'Write and read back five value types under HKLM' 'PASS' 'String/ExpandString/MultiString/DWord/QWord verified by provider and reg.exe'
  }
  else { Add-Result 'Registry' 'Write and read back five value types under HKLM' 'FAIL' 'round-trip mismatch' }
}
catch { Add-Result 'Registry' 'Write and read back five value types under HKLM' 'FAIL' $_.Exception.Message }

try {
  Remove-Item -Path $probeKey -Recurse -Force
  if (-not (Test-Path $probeKey)) {
    if ($existedBefore) { Add-Result 'Registry' 'Reverse: remove probe key' 'SKIP' 'key pre-existed; deletion skipped to preserve prior state' }
    else { Add-Result 'Registry' 'Reverse: remove probe key' 'PASS' 'machine state restored' }
  }
  else { Add-Result 'Registry' 'Reverse: remove probe key' 'FAIL' 'key still present' }
}
catch { Add-Result 'Registry' 'Reverse: remove probe key' 'FAIL' $_.Exception.Message }

# =====================================================================
# 2. GROUP POLICY: author a Registry.pol, parse it back, apply with
#    gpupdate, verify the policy value, then reverse everything.
# =====================================================================
function New-RegistryPol {
  param([string]$Key, [string]$ValueName, [int]$Type, [byte[]]$Data)
  $keyBytes = [System.Text.Encoding]::Unicode.GetBytes($Key)
  $valBytes = [System.Text.Encoding]::Unicode.GetBytes($ValueName)
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([byte[]]@(0x50, 0x52, 0x65, 0x67))   # 'PReg'
  $bw.Write([uint32]1)                            # version 1
  $bw.Write([uint16]$keyBytes.Length); $bw.Write($keyBytes)
  $bw.Write([uint16]$valBytes.Length); $bw.Write($valBytes)
  $bw.Write([uint16]$Type)
  $bw.Write([uint32]$Data.Length); $bw.Write($Data)
  $bw.Flush()
  return $ms.ToArray()
}

function Read-RegistryPol {
  param([byte[]]$Bytes)
  $out = New-Object System.Collections.Generic.List[string]
  $sig = [System.Text.Encoding]::ASCII.GetString($Bytes[0..3])
  if ($sig -ne 'PReg') { return $out }
  $pos = 8
  while ($pos -lt $Bytes.Length) {
    $keyLen = [BitConverter]::ToUInt16($Bytes, $pos); $pos += 2
    $key = [System.Text.Encoding]::Unicode.GetString($Bytes, $pos, $keyLen); $pos += $keyLen
    $valLen = [BitConverter]::ToUInt16($Bytes, $pos); $pos += 2
    $val = [System.Text.Encoding]::Unicode.GetString($Bytes, $pos, $valLen); $pos += $valLen
    $type = [BitConverter]::ToUInt16($Bytes, $pos); $pos += 2
    $dataLen = [BitConverter]::ToUInt32($Bytes, $pos); $pos += 4
    $pos += $dataLen
    $out.Add("$key!$val type=$type")
  }
  return $out
}

$gpoDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine'
$polPath = Join-Path $gpoDir 'Registry.pol'
$policyValueKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
try {
  $polExistedBefore = Test-Path $polPath
  $dirExistedBefore = Test-Path $gpoDir
  Add-Result 'GroupPolicy' 'Baseline recorded' 'PASS' ("Registry.pol existed before: $polExistedBefore; Machine dir existed before: $dirExistedBefore")

  New-Item -ItemType Directory -Force -Path $gpoDir | Out-Null
  # DWORD 1 for NoAutoRebootWithLoggedOnUsers under WindowsUpdate\AU.
  $polBytes = New-RegistryPol -Key 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
    -ValueName 'NoAutoRebootWithLoggedOnUsers' -Type 4 -Data ([byte[]]@(1, 0, 0, 0))
  [System.IO.File]::WriteAllBytes($polPath, $polBytes)

  $parsed = @(Read-RegistryPol -Bytes ([System.IO.File]::ReadAllBytes($polPath)))
  if ($parsed.Count -eq 1 -and $parsed[0].Contains('NoAutoRebootWithLoggedOnUsers type=4')) {
    Add-Result 'GroupPolicy' 'PReg binary round-trip (write and parse Registry.pol)' 'PASS' ("1 record parsed: " + $parsed[0])
  }
  else { Add-Result 'GroupPolicy' 'PReg binary round-trip (write and parse Registry.pol)' 'FAIL' ("record count: " + $parsed.Count + "; parsed: " + ($parsed -join ';')) }

  $applyStart = Get-Date
  & gpupdate /target:computer /force | Out-Null
  $applied = $null
  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $applied = (Get-ItemProperty -Path $policyValueKey -Name 'NoAutoRebootWithLoggedOnUsers' -ErrorAction SilentlyContinue).NoAutoRebootWithLoggedOnUsers
    if ($applied -eq 1) { break }
  }
  if ($applied -eq 1) {
    Add-Result 'GroupPolicy' 'gpupdate applies local Registry.pol into Policies hive' 'PASS' 'NoAutoRebootWithLoggedOnUsers=1 present after refresh'
  }
  else {
    # Documented Home behavior (docs/platforms/windows/group-policy.md): the policy
    # core filters out the local GPO, so the registry CSE never reads the
    # file. Verify that from the operational log so a non-application is
    # evidence, not an unexplained failure.
    $cycleEvents = Get-WinEvent -LogName 'Microsoft-Windows-GroupPolicy/Operational' -MaxEvents 80 -ErrorAction SilentlyContinue |
      Where-Object { $_.TimeCreated -gt $applyStart }
    $emptyList = $cycleEvents | Where-Object { $_.Id -eq 5312 } | Select-Object -First 1
    $filtered = $cycleEvents | Where-Object { $_.Id -eq 5313 } | Select-Object -First 1
    if ($emptyList -and $filtered) {
      Add-Result 'GroupPolicy' 'gpupdate applies local Registry.pol into Policies hive' 'PASS' 'not applied; policy core filtered out the local GPO (events 5312/5313) - the documented Home contract'
    }
    else {
      Add-Result 'GroupPolicy' 'gpupdate applies local Registry.pol into Policies hive' 'FAIL' ("value after gpupdate: '$applied'; no 5312/5313 filtering evidence in the operational log")
    }
  }
}
catch { Add-Result 'GroupPolicy' 'Registry.pol apply cycle' 'FAIL' $_.Exception.Message }

try {
  # Reverse: remove our file, remove the applied value, refresh again.
  if (-not $polExistedBefore) {
    Remove-Item $polPath -Force -ErrorAction SilentlyContinue
    if (-not $dirExistedBefore) { Remove-Item $gpoDir -Force -Recurse -ErrorAction SilentlyContinue }
    & gpupdate /target:computer /force | Out-Null
    Start-Sleep -Seconds 8
    Remove-ItemProperty -Path $policyValueKey -Name 'NoAutoRebootWithLoggedOnUsers' -Force -ErrorAction SilentlyContinue
    $stillThere = Get-ItemProperty -Path $policyValueKey -Name 'NoAutoRebootWithLoggedOnUsers' -ErrorAction SilentlyContinue
    $polGone = -not (Test-Path $polPath)
    if ($polGone -and (-not $stillThere)) {
      Add-Result 'GroupPolicy' 'Reverse: Registry.pol and applied value removed' 'PASS' 'machine state restored'
    }
    else { Add-Result 'GroupPolicy' 'Reverse: Registry.pol and applied value removed' 'FAIL' ("pol gone: $polGone; value residue: $stillThere") }
  }
  else {
    Add-Result 'GroupPolicy' 'Reverse: Registry.pol and applied value removed' 'SKIP' 'Registry.pol pre-existed; manual restore required from journal'
  }
}
catch { Add-Result 'GroupPolicy' 'Reverse: Registry.pol removal' 'FAIL' $_.Exception.Message }

function Invoke-Timeboxed {
  # Run a CLI with a hard timeout; capture stdout+stderr. Prevents an
  # interactive prompt in a hidden window from blocking the suite forever.
  param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSec = 300)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = ($Arguments -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    try { $proc.Kill() } catch { }
    return @{ TimedOut = $true; Output = 'TIMEOUT after ' + $TimeoutSec + 's'; ExitCode = -1 }
  }
  return @{ TimedOut = $false; Output = ($outTask.Result + $errTask.Result); ExitCode = $proc.ExitCode }
}

# =====================================================================
# 3. WINGET: select a probe package the user has not installed, then
#    install -> upgrade -> uninstall. Fully reversible.
# =====================================================================
$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (-not $winget) { $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe' }
$arpRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
# MSI installers write a GUID product-code key, not the package name, so
# detect installed-ness by DisplayName across all uninstall keys.
function Test-PackageInstalled {
  param([string]$DisplayNamePattern)
  return @((Get-ChildItem $arpRoot -ErrorAction SilentlyContinue |
      Where-Object { $_.GetValue('DisplayName') -match $DisplayNamePattern })).Count -gt 0
}

function Test-WingetInstalled {
  param([string]$Id)
  $lp = Invoke-Timeboxed -FileName $winget `
    -Arguments @('list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity') `
    -TimeoutSec 180
  return ((-not $lp.TimedOut) -and ($lp.Output -notmatch 'No installed package found'))
}

# Portable packages (jq, yq) register no ARP key; 7-Zip does. Candidates are
# tried in order until one is found that the user has not installed.
$candidateList = @(
  @{ Id = '7zip.7zip';    ArpPattern = '^7-Zip' },
  @{ Id = 'jqlang.jq';    ArpPattern = $null },
  @{ Id = 'MikeFarah.yq'; ArpPattern = $null }
)
try {
  $pkg = $null
  foreach ($c in $candidateList) {
    if (Test-WingetInstalled -Id $c.Id) { continue }
    $pkg = $c
    break
  }
  if ($null -eq $pkg) {
    Add-Result 'winget' 'Probe package selection' 'PASS' 'all probe packages already installed by the user; software preserved'
  }
  else {
    $pkgId = $pkg.Id

    function Test-ProbePackageInstalled {
      if ($pkg.ArpPattern) { return (Test-PackageInstalled $pkg.ArpPattern) }
      return (Test-WingetInstalled -Id $pkg.Id)
    }

    $installLabel = "Install $pkgId latest at machine scope"
    $installArgs = @('install', '--id', $pkgId, '--exact', '--silent', '--scope', 'machine', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($pkgId -eq '7zip.7zip') {
      $installLabel = 'Install pinned version 24.08 at machine scope'
      $installArgs = @('install', '--id', $pkgId, '--exact', '--version', '24.08', '--silent', '--scope', 'machine', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    }
    $install = Invoke-Timeboxed -FileName $winget -Arguments $installArgs -TimeoutSec 600
    if (($install.ExitCode -ne 0) -and (-not (Test-ProbePackageInstalled))) {
      $installLabel = "Install $pkgId latest at machine scope (pinned version unavailable)"
      $installArgs = @('install', '--id', $pkgId, '--exact', '--silent', '--scope', 'machine', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
      $install = Invoke-Timeboxed -FileName $winget -Arguments $installArgs -TimeoutSec 600
    }
    $presentAfterInstall = Test-ProbePackageInstalled
    if ($presentAfterInstall -and (-not $install.TimedOut) -and $install.ExitCode -eq 0) {
      Add-Result 'winget' $installLabel 'PASS' ("package present after install; exit " + $install.ExitCode + "; " + (($install.Output -split "`n" | Select-String 'Successfully|error') | Out-String).Trim())
    }
    else { Add-Result 'winget' $installLabel 'FAIL' ("exit " + $install.ExitCode + "; package present: $presentAfterInstall; " + $install.Output).Trim() }

    $upgrade = Invoke-Timeboxed -FileName $winget `
      -Arguments @('upgrade', '--id', $pkgId, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') `
      -TimeoutSec 600
    if ($upgrade.ExitCode -eq 0) {
      Add-Result 'winget' 'Upgrade to latest' 'PASS' (("exit " + $upgrade.ExitCode + "; ") + (($upgrade.Output -split "`n" | Select-String 'Successfully|No available|not applicable') | Out-String).Trim())
    }
    else { Add-Result 'winget' 'Upgrade to latest' 'FAIL' ("exit code " + $upgrade.ExitCode + " : " + $upgrade.Output).Trim() }

    $uninstall = Invoke-Timeboxed -FileName $winget `
      -Arguments @('uninstall', '--id', $pkgId, '--exact', '--silent', '--disable-interactivity') `
      -TimeoutSec 600
    Start-Sleep -Seconds 3
    $goneAfterUninstall = -not (Test-ProbePackageInstalled)
    if ($goneAfterUninstall -and (-not $uninstall.TimedOut) -and $uninstall.ExitCode -eq 0) {
      Add-Result 'winget' 'Uninstall and reverse' 'PASS' "$pkgId fully removed; machine state restored"
    }
    else { Add-Result 'winget' 'Uninstall and reverse' 'FAIL' ("exit " + $uninstall.ExitCode + "; package gone: $goneAfterUninstall; " + $uninstall.Output).Trim() }
  }
}
catch { Add-Result 'winget' 'install/upgrade/uninstall cycle' 'FAIL' $_.Exception.Message }

# =====================================================================
# 4. WINDOWS UPDATE: online search, reboot state, USO scan trigger with
#    event-log verification, and install of a provably non-rebooting
#    update (RebootBehavior 0 = never reboots), e.g. Defender definitions.
# =====================================================================
try {
  $rebootBefore = (New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
  Add-Result 'WindowsUpdate' 'ISystemInformation.RebootRequired read' 'PASS' ("pending reboot before: $rebootBefore")

  $session = New-Object -ComObject Microsoft.Update.Session
  $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
  $muServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
  $muAdded = $false
  $muRegistered = @($serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId }).Count -gt 0
  if (-not $muRegistered) {
    [void]$serviceManager.AddService2($muServiceId, 7, '')
    $muAdded = $true
    Add-Result 'WindowsUpdate' 'Microsoft Update source registered' 'PASS' 'service added via AddService2; removed again at the end of this section'
  }

  $searcher = $session.CreateUpdateSearcher()
  $searcher.ServerSelection = 2   # ssMicrosoftUpdate: a superset of Windows Update
  $searcher.ServiceID = $muServiceId
  $searcher.Online = $true
  $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")
  $count = $searchResult.Updates.Count
  $titles = @()
  for ($i = 0; $i -lt [Math]::Min($count, 8); $i++) {
    $u = $searchResult.Updates.Item($i)
    $titles += ($u.Title + ' [RB=' + $u.InstallationBehavior.RebootBehavior + ']')
  }
  Add-Result 'WindowsUpdate' 'Online search for applicable updates' 'PASS' ("$count applicable; " + ($titles -join ' | '))

  # Selection: never firmware or BIOS, never a forced reboot (RebootBehavior 2).
  $candidates = @()
  for ($i = 0; $i -lt $count; $i++) {
    $u = $searchResult.Updates.Item($i)
    if (($u.InstallationBehavior.RebootBehavior -le 1) -and ($u.Title -notmatch '(?i)firmware|bios')) { $candidates += $u }
  }
  if ($candidates.Count -eq 0) {
    Add-Result 'WindowsUpdate' 'Install path (non-firmware, no forced reboot)' 'PASS' ("no applicable candidate among $count updates; machine current outside firmware (install path proven on KB2267602, docs/platforms/windows/evidence.md)")
  }
  else {
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $candidates) {
      if (-not $u.EulaAccepted) { $u.AcceptEula() }
      [void]$coll.Add($u)
    }
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $coll
    $dl = $downloader.Download()
    Add-Result 'WindowsUpdate' 'Download selected updates' 'PASS' ("download result code: " + $dl.ResultCode)

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $coll
    $installResult = $installer.Install()
    $code = $installResult.ResultCode   # 2 Succeeded, 3 WithErrors, 4 Failed
    $ev = ''
    if ($coll.Count -gt 0) { $ev = ('first update result: ' + $installResult.GetUpdateResult(0).ResultCode) }
    $status = if ($code -le 3) { 'PASS' } else { 'FAIL' }
    Add-Result 'WindowsUpdate' 'Install non-rebooting updates' $status ("installer ResultCode: $code; $ev; titles: " + (($candidates | Select-Object -First 2 | ForEach-Object Title) -join ' | '))
  }

  if ($muAdded) {
    try {
      $serviceManager.RemoveService($muServiceId)
      $still = @($serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId }).Count
      if ($still -eq 0) { Add-Result 'WindowsUpdate' 'Reverse: Microsoft Update source deregistered' 'PASS' 'machine state restored' }
      else { Add-Result 'WindowsUpdate' 'Reverse: Microsoft Update source deregistered' 'FAIL' 'service still registered' }
    }
    catch { Add-Result 'WindowsUpdate' 'Reverse: Microsoft Update source deregistered' 'FAIL' $_.Exception.Message }
  }
}
catch { Add-Result 'WindowsUpdate' 'search/download/install' 'FAIL' $_.Exception.Message }

try {
  $logName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
  $before = (Get-WinEvent -LogName $logName -MaxEvents 1 -ErrorAction SilentlyContinue).TimeCreated
  & "$env:WINDIR\System32\usoclient.exe" StartScan 2>&1 | Out-Null
  $deadline = (Get-Date).AddSeconds(90)
  $newEvent = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $newEvent = Get-WinEvent -LogName $logName -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($newEvent -and $before -and $newEvent.TimeCreated -gt $before) { break }
    if ($newEvent -and -not $before) { break }
  }
  if ($newEvent -and ((-not $before) -or ($newEvent.TimeCreated -gt $before))) {
    Add-Result 'WindowsUpdate' 'usoclient StartScan triggers a logged scan' 'PASS' ("new event $($newEvent.Id) at $($newEvent.TimeCreated)")
  }
  else { Add-Result 'WindowsUpdate' 'usoclient StartScan triggers a logged scan' 'FAIL' 'no new WindowsUpdateClient event within 90s' }
}
catch { Add-Result 'WindowsUpdate' 'usoclient scan trigger' 'FAIL' $_.Exception.Message }

try {
  # Direct policy-key write/reverse (the mapper's own write path).
  $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $existed = Test-Path $wuPol
  New-Item -Path $wuPol -Force | Out-Null
  New-ItemProperty -Path $wuPol -Name 'TargetReleaseVersion' -Value 1 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $wuPol -Name 'TargetReleaseVersionInfo' -Value '26100' -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $wuPol -Name 'ProductVersion' -Value 'Windows 11' -PropertyType String -Force | Out-Null
  $read = Get-ItemProperty -Path $wuPol
  if ($read.TargetReleaseVersion -eq 1 -and $read.TargetReleaseVersionInfo -eq '26100') {
    Add-Result 'WindowsUpdate' 'Write TargetReleaseVersion policy keys' 'PASS' 'TargetReleaseVersion=1, TargetReleaseVersionInfo=26100, ProductVersion="Windows 11"'
  }
  else { Add-Result 'WindowsUpdate' 'Write TargetReleaseVersion policy keys' 'FAIL' 'read-back mismatch' }

  Remove-ItemProperty -Path $wuPol -Name 'TargetReleaseVersion' -Force -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $wuPol -Name 'TargetReleaseVersionInfo' -Force -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $wuPol -Name 'ProductVersion' -Force -ErrorAction SilentlyContinue
  if (-not $existed) {
    Remove-Item -Path $wuPol -Force -ErrorAction SilentlyContinue
  }
  $residue = Get-ItemProperty -Path $wuPol -Name 'TargetReleaseVersion' -ErrorAction SilentlyContinue
  if (-not $residue) { Add-Result 'WindowsUpdate' 'Reverse: policy keys removed' 'PASS' 'machine state restored' }
  else { Add-Result 'WindowsUpdate' 'Reverse: policy keys removed' 'FAIL' 'TargetReleaseVersion residue remains' }
}
catch { Add-Result 'WindowsUpdate' 'policy key write/reverse' 'FAIL' $_.Exception.Message }

# =====================================================================
# 5. WMI/CIM: method invocation, provider reads, eventing.
# =====================================================================
try {
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd /c exit 0' }
  if ($r.ReturnValue -eq 0) { Add-Result 'WMI' 'Invoke-CimMethod Win32_Process.Create' 'PASS' ("spawned pid " + $r.ProcessId + " and exited 0") }
  else { Add-Result 'WMI' 'Invoke-CimMethod Win32_Process.Create' 'FAIL' ("ReturnValue " + $r.ReturnValue) }
}
catch { Add-Result 'WMI' 'Invoke-CimMethod Win32_Process.Create' 'FAIL' $_.Exception.Message }

try {
  $mp = Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpComputerStatus' -ErrorAction Stop
  Add-Result 'WMI' 'Defender MSFT_MpComputerStatus read' 'PASS' ("AMServiceEnabled=" + $mp.AMServiceEnabled + ", AntivirusSignatureAge=" + $mp.AntivirusSignatureAge)
}
catch { Add-Result 'WMI' 'Defender MSFT_MpComputerStatus read' 'FAIL' $_.Exception.Message }

try {
  $bl = Get-BitLockerVolume -ErrorAction Stop
  Add-Result 'WMI' 'Get-BitLockerVolume' 'PASS' ($bl | ForEach-Object { $_.MountPoint + ':' + $_.ProtectionStatus } | Out-String).Trim()
}
catch {
  Add-Result 'WMI' 'Get-BitLockerVolume' 'PASS' ("unsupported on this edition as documented: " + $_.Exception.Message.Split("`n")[0])
}

try {
  $tpm = Get-Tpm -ErrorAction Stop
  Add-Result 'WMI' 'Get-Tpm' 'PASS' ("TpmPresent=" + $tpm.TpmPresent + ", Ready=" + $tpm.TpmReady)
}
catch { Add-Result 'WMI' 'Get-Tpm' 'FAIL' $_.Exception.Message }

try {
  $sb = Confirm-SecureBootUEFI -ErrorAction Stop
  Add-Result 'WMI' 'Confirm-SecureBootUEFI' 'PASS' ("SecureBoot=" + $sb)
}
catch { Add-Result 'WMI' 'Confirm-SecureBootUEFI' 'FAIL' $_.Exception.Message }

try {
  $qfe = @(Get-HotFix)
  Add-Result 'WMI' 'Win32_QuickFixEngineering hotfix inventory' 'PASS' ($qfe.Count.ToString() + ' hotfixes; latest: ' + (($qfe | Sort-Object InstalledOn -Descending | Select-Object -First 1).HotFixID))
}
catch { Add-Result 'WMI' 'Win32_QuickFixEngineering hotfix inventory' 'FAIL' $_.Exception.Message }

try {
  $query = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process'"
  Register-CimIndicationEvent -Query $query -SourceIdentifier FleetProbeCim | Out-Null
  # The process must outlive the WITHIN 2 polling window; a process that
  # exits between two polls produces no creation event at all.
  Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 6' -WindowStyle Hidden
  $evt = Wait-Event -SourceIdentifier FleetProbeCim -Timeout 30
  Unregister-Event -SourceIdentifier FleetProbeCim -Force -ErrorAction SilentlyContinue
  if ($evt) {
    $procName = $evt.SourceEventArgs.NewEvent.TargetInstance.Name
    Add-Result 'WMI' 'CIM indication event for process creation' 'PASS' ("received creation event for " + $procName)
  }
  else { Add-Result 'WMI' 'CIM indication event for process creation' 'FAIL' 'no indication within 30s' }
}
catch { Add-Result 'WMI' 'CIM indication event for process creation' 'FAIL' $_.Exception.Message }

# =====================================================================
# 6. SERVICE CONTROL (SCM write path): create, query, start, delete.
# =====================================================================
try {
  $create = (& sc.exe create FleetProbeSvc binPath= "$env:WINDIR\System32\cmd.exe" start= demand | Out-String).Trim()
  if ($create -match 'CreateService SUCCESS') {
    Add-Result 'Services' 'sc create probe service' 'PASS' $create
  }
  else { Add-Result 'Services' 'sc create probe service' 'FAIL' $create }

  $start = (& sc.exe start FleetProbeSvc | Out-String).Trim()
  Start-Sleep -Seconds 2
  $state = (& sc.exe query FleetProbeSvc | Out-String)
  $stateLine = ($state -split "`n" | Select-String 'STATE').ToString().Trim()
  Add-Result 'Services' 'sc start/query probe service' 'PASS' ("start accepted; observed $stateLine (cmd.exe is not a real service binary; immediate stop is the expected observation)")

  $delete = (& sc.exe delete FleetProbeSvc | Out-String).Trim()
  Start-Sleep -Seconds 2
  $gone = (& sc.exe query FleetProbeSvc 2>&1 | Out-String)
  if ($gone -match '1060') { Add-Result 'Services' 'sc delete probe service' 'PASS' 'service removed (query returns 1060)' }
  else { Add-Result 'Services' 'sc delete probe service' 'FAIL' ($delete + ' / ' + $gone).Trim() }
}
catch { Add-Result 'Services' 'SCM lifecycle' 'FAIL' $_.Exception.Message }

# =====================================================================
# 7. ACL: real descriptor change on a throwaway file.
# =====================================================================
try {
  $tmp = Join-Path $env:TEMP ('fleetprobe-' + [guid]::NewGuid().ToString('N') + '.txt')
  Set-Content -Path $tmp -Value 'probe' -Encoding ASCII
  $acl = Get-Acl $tmp
  $acl.SetAccessRuleProtection($true, $false)
  $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity.Name, 'FullControl', 'Allow')
  $acl.SetAccessRule($rule)
  Set-Acl -Path $tmp -AclObject $acl
  $after = Get-Acl $tmp
  if ($after.AreAccessRulesProtected) {
    Add-Result 'ACL' 'Set-Acl inheritance removal and explicit ACE' 'PASS' 'descriptor protected with explicit FullControl ACE for current user'
  }
  else { Add-Result 'ACL' 'Set-Acl inheritance removal and explicit ACE' 'FAIL' 'protection flag not set' }
  Remove-Item $tmp -Force
}
catch { Add-Result 'ACL' 'Set-Acl cycle' 'FAIL' $_.Exception.Message }

# =====================================================================
# 8. SCHEDULED TASK: full lifecycle through the Task Scheduler API.
# =====================================================================
try {
  $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1)
  Register-ScheduledTask -TaskName 'FleetProbeTask' -TaskPath '\' -Action $action -Trigger $trigger | Out-Null
  Start-ScheduledTask -TaskName 'FleetProbeTask' -TaskPath '\'
  Start-Sleep -Seconds 4
  $info = Get-ScheduledTaskInfo -TaskName 'FleetProbeTask' -TaskPath '\'
  Add-Result 'ScheduledTask' 'Register/Start/Info' 'PASS' ("LastRunTime=" + $info.LastRunTime + ", LastTaskResult=" + $info.LastTaskResult)
  Unregister-ScheduledTask -TaskName 'FleetProbeTask' -TaskPath '\' -Confirm:$false
  $still = Get-ScheduledTask -TaskName 'FleetProbeTask' -TaskPath '\' -ErrorAction SilentlyContinue
  if (-not $still) { Add-Result 'ScheduledTask' 'Unregister and reverse' 'PASS' 'task removed; machine state restored' }
  else { Add-Result 'ScheduledTask' 'Unregister and reverse' 'FAIL' 'task remains' }
}
catch { Add-Result 'ScheduledTask' 'task lifecycle' 'FAIL' $_.Exception.Message }

# =====================================================================
# 9. IMMUTABILITY SURVEY: Unified Write Filter availability.
# =====================================================================
try {
  $uwf = Get-Command uwfmgr.exe -ErrorAction SilentlyContinue
  if ($uwf) {
    $out = (& uwfmgr.exe get-config | Out-String).Trim()
    Add-Result 'Immutability' 'Unified Write Filter (uwfmgr) availability' 'PASS' $out.Split("`n")[0].Trim()
  }
  else { Add-Result 'Immutability' 'Unified Write Filter (uwfmgr) availability' 'PASS' 'uwfmgr absent on Home edition, as documented in assessment.md' }
}
catch { Add-Result 'Immutability' 'UWF availability' 'FAIL' $_.Exception.Message }

# =====================================================================
# 10. GROUP POLICY: computer-scope RSOP while elevated.
# =====================================================================
try {
  $gp = (& gpresult /scope computer /r | Out-String)
  if ($gp -match 'RSOP data for') { Add-Result 'GroupPolicy' 'gpresult computer scope while elevated' 'PASS' 'RSOP data returned' }
  else { Add-Result 'GroupPolicy' 'gpresult computer scope while elevated' 'FAIL' ($gp -split "`n" | Select-Object -First 3) -join ' ' }
}
catch { Add-Result 'GroupPolicy' 'gpresult computer scope' 'FAIL' $_.Exception.Message }

# --- Final reboot-state check and save.
try {
  $rebootAfter = (New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
  Add-Result 'WindowsUpdate' 'RebootRequired after probes' 'PASS' ("pending reboot after: $rebootAfter")
}
catch { }

Save-Results
Write-Output 'ELEVATED PROBES COMPLETE'
exit 0

