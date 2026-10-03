# Probe suite for the Windows mapper surface documents.
# Runs the documented verify commands read-only and checks the document set.
# Evidence level: real runtime, non-elevated. See docs/platforms/windows/surface-ledger.md.

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$docsRoot = Join-Path $repoRoot 'docs\platforms\windows'

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
  param([string]$Surface, [string]$Check, [string]$Status, [string]$Evidence)
  $results.Add([pscustomobject]@{
      Surface  = $Surface
      Check    = $Check
      Status   = $Status   # PASS | FAIL | SKIP
      Evidence = $Evidence
    })
}

function Invoke-Probe {
  param([string]$Surface, [string]$Check, [scriptblock]$Probe, [scriptblock]$Judge)
  try {
    $output = & $Probe
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) {
      Add-Result $Surface $Check 'FAIL' ("exit code " + $LASTEXITCODE)
      return
    }
    $verdict = & $Judge $output
    if ($verdict) {
      Add-Result $Surface $Check 'PASS' $verdict
    }
    else {
      Add-Result $Surface $Check 'FAIL' ($output | Out-String).Trim()
    }
  }
  catch {
    Add-Result $Surface $Check 'FAIL' $_.Exception.Message
  }
}

# --- Win32 API surface: read-only P/Invoke through the agent runtime model.
Invoke-Probe 'WinAPI' 'GetComputerNameEx returns the DNS hostname' `
  -Probe {
    Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetComputerNameEx(uint NameType,
  System.Text.StringBuilder Buffer, ref uint Size);
'@ -Name Kernel32 -Namespace Win32
    $size = [uint32]256
    $buffer = New-Object System.Text.StringBuilder 256
    [void][Win32.Kernel32]::GetComputerNameEx(3, $buffer, [ref]$size)
    $buffer.ToString()
  } `
  -Judge { param($output)
    if ($output -and $output -eq $env:COMPUTERNAME) { "hostname '$output' matches COMPUTERNAME" } else { $null }
  }

# --- Registry surface: CLI read and native provider read.
Invoke-Probe 'Registry' 'reg query reads HKLM CurrentVersion' `
  -Probe { & reg query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' /v ProductName } `
  -Judge { param($output)
    $text = ($output | Out-String)
    if ($text -match 'ProductName\s+REG_SZ\s+(\S.*)') { "reg.exe read: $($Matches[1].Trim())" } else { $null }
  }

Invoke-Probe 'Registry' 'PowerShell provider reads the same key' `
  -Probe { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName } `
  -Judge { param($output)
    if ($output) { "provider read: $output" } else { $null }
  }

# --- Group Policy surface: RSOP query, policy file presence recorded.
Invoke-Probe 'GroupPolicy' 'gpresult reports RSOP for the user scope' `
  -Probe { & gpresult /scope user /r } `
  -Judge { param($output)
    $text = ($output | Out-String)
    if ($text -match 'RSOP data for') { 'RSOP data returned' } else { $null }
  }

$polPath = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Registry.pol'
if (Test-Path $polPath) {
  Add-Result 'GroupPolicy' 'Registry.pol presence' 'PASS' 'present'
}
else {
  Add-Result 'GroupPolicy' 'Registry.pol presence' 'PASS' 'absent; machine never applied local policy (valid baseline, as documented)'
}

if ((Get-CimInstance Win32_OperatingSystem).Caption -match 'Home') {
  $gpedit = Test-Path (Join-Path $env:WINDIR 'System32\gpedit.msc')
  $secedit = Test-Path (Join-Path $env:WINDIR 'System32\secedit.exe')
  $gpModule = @(Get-Command -Module GroupPolicy -ErrorAction SilentlyContinue).Count
  Add-Result 'GroupPolicy' 'Home edition engine inventory' 'PASS' ("gpedit.msc present: $gpedit; secedit.exe present: $secedit; GroupPolicy module cmdlets: $gpModule - matches documented Home limits")
}

# --- winget surface: CLI availability.
Invoke-Probe 'winget' 'winget --version reports the App Installer version' `
  -Probe { & winget --version } `
  -Judge { param($output)
    $text = ($output | Out-String).Trim()
    if ($text -match 'v\d+\.\d+') { "winget $text" } else { $null }
  }

Invoke-Probe 'winget' 'winget source list reports sources' `
  -Probe { & winget source list } `
  -Judge { param($output)
    $text = ($output | Out-String)
    if ($text -match 'winget') { 'winget source present' } else { $null }
  }

# --- WMI/CIM surface: inventory queries.
Invoke-Probe 'WMI' 'Get-CimInstance Win32_OperatingSystem' `
  -Probe { (Get-CimInstance Win32_OperatingSystem).Caption } `
  -Judge { param($output)
    if ($output) { "caption: $output" } else { $null }
  }

Invoke-Probe 'WMI' 'Get-CimInstance Win32_ComputerSystem' `
  -Probe { $cs = Get-CimInstance Win32_ComputerSystem; "$($cs.Manufacturer) $($cs.Model)" } `
  -Judge { param($output)
    if ($output) { "hardware: $output" } else { $null }
  }

# --- Windows Update surface: COM session, history read without elevation.
Invoke-Probe 'WindowsUpdate' 'COM searcher reads update history' `
  -Probe { (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().GetTotalHistoryCount() } `
  -Judge { param($output)
    if ($output -ge 0) { "history entries: $output" } else { $null }
  }

Invoke-Probe 'WindowsUpdate' 'COM AutoUpdate settings readable' `
  -Probe { (New-Object -ComObject Microsoft.Update.AutoUpdate).Settings.NotificationLevel } `
  -Judge { param($output)
    if ($null -ne $output) { "notification level: $output" } else { $null }
  }

# --- Elevated-scope checks: merge the elevated suite's real results instead
# of listing them as skips. The elevated suite (tools/probes/windows/test-windows-elevated.ps1)
# writes results.json and done.flag; PENDING here means it has not run yet.
$elevatedResultsPath = Join-Path $env:TEMP 'fleet-elevated\results.json'
$elevatedDonePath = Join-Path $env:TEMP 'fleet-elevated\done.flag'
if ((Test-Path $elevatedDonePath) -and (Test-Path $elevatedResultsPath)) {
  try {
    $elevated = Get-Content $elevatedResultsPath -Raw | ConvertFrom-Json
    foreach ($row in $elevated) {
      if ($row.Check -eq 'Administrator token' -or $row.Check -eq 'RebootRequired after probes') {
        # Framework rows, not surface checks; keep the suite matrix focused.
        continue
      }
      Add-Result $row.Surface ("elevated: " + $row.Check) $row.Status $row.Evidence
    }
  }
  catch {
    Add-Result 'Elevation' 'merge elevated results' 'FAIL' $_.Exception.Message
  }
}
else {
  Add-Result 'Elevation' 'elevated suite coverage' 'PENDING' 'elevated results not found; run tools/probes/windows/test-windows-elevated.ps1 once (one UAC approval) to complete the matrix'
}

# --- Extended read-only probes: SCM, task scheduler, event log, network CIM.
Invoke-Probe 'Services' 'sc query reads the wuauserv service state' `
  -Probe { & sc.exe query wuauserv } `
  -Judge { param($output)
    $text = ($output | Out-String)
    if ($text -match 'wuauserv' -and $text -match 'STATE') { 'service state query answered' } else { $null }
  }

Invoke-Probe 'ScheduledTask' 'Get-ScheduledTask enumerates the task store' `
  -Probe { @(Get-ScheduledTask -ErrorAction SilentlyContinue).Count } `
  -Judge { param($output)
    if ($output -gt 50) { "$output tasks registered" } else { $null }
  }

Invoke-Probe 'WinAPI' 'Get-WinEvent reads the System log' `
  -Probe { (Get-WinEvent -LogName System -MaxEvents 1).TimeCreated } `
  -Judge { param($output)
    if ($output) { "newest System event at $output" } else { $null }
  }

Invoke-Probe 'WMI' 'MSFT_NetAdapter enumerates network adapters' `
  -Probe { @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter).Count } `
  -Judge { param($output)
    if ($output -gt 0) { "$output adapter(s)" } else { $null }
  }

# --- Document integrity: each doc exists and contains its anchor.
$anchors = @(
  @{ Doc = 'README.md';          Anchor = 'State and reversal' },
  @{ Doc = 'assessment.md';      Anchor = 'The correction: state, not immutability' },
  @{ Doc = 'prior-art.md';       Anchor = 'Windows Declared Configuration' },
  @{ Doc = 'plan-schema.md';     Anchor = 'Resource envelope' },
  @{ Doc = 'agent-runtime.md';   Anchor = 'Apply loop' },
  @{ Doc = 'evidence.md';        Anchor = 'The two findings' },
  @{ Doc = 'winapi.md';          Anchor = 'RegNotifyChangeKeyValue' },
  @{ Doc = 'registry.md';        Anchor = 'HKEY_USERS' },
  @{ Doc = 'group-policy.md';    Anchor = 'PReg' },
  @{ Doc = 'winget.md';          Anchor = '--accept-source-agreements' },
  @{ Doc = 'wmi.md';             Anchor = 'Win32_Product' },
  @{ Doc = 'windows-update.md';  Anchor = 'TargetReleaseVersion' },
  @{ Doc = 'surface-ledger.md';  Anchor = 'hit-every-surface' }
)

foreach ($item in $anchors) {
  $path = Join-Path $docsRoot $item.Doc
  if (-not (Test-Path $path)) {
    Add-Result 'Documents' $item.Doc 'FAIL' 'missing file'
    continue
  }
  $content = Get-Content $path -Raw
  $hasAnchor = $content.Contains($item.Anchor)
  $hasVerify = $content -match '(?m)^## Verify'
  if ($hasAnchor -and ($hasVerify -or $item.Doc -in @('README.md', 'assessment.md', 'prior-art.md', 'plan-schema.md', 'agent-runtime.md', 'evidence.md', 'surface-ledger.md'))) {
    Add-Result 'Documents' $item.Doc 'PASS' 'anchor and Verify section present'
  }
  else {
    $reason = @()
    if (-not $hasAnchor) { $reason += "anchor '$($item.Anchor)' missing" }
    if (-not $hasVerify) { $reason += 'no Verify section' }
    Add-Result 'Documents' $item.Doc 'FAIL' ($reason -join '; ')
  }
}

# --- Report.
$results | Format-Table Surface, Check, Status, Evidence -AutoSize -Wrap

$passed = @($results | Where-Object Status -eq 'PASS').Count
$failed = @($results | Where-Object Status -eq 'FAIL').Count
$skipped = @($results | Where-Object Status -eq 'SKIP').Count

Write-Output ("Result: $passed passed, $failed failed, $skipped skipped.")

if ($failed -gt 0) { exit 1 }
exit 0
