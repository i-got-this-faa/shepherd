# FleetAgent core: settings, journal, plan validation, provider dispatch,
# plan execution, reports, and drift. Resource providers live in Resources\
# and are dot-sourced at import; the dispatch table maps resource names to
# provider functions.

#Requires -Version 5.1

# =====================================================================
# Settings and environment
# =====================================================================
$script:FleetAgentSettings = @{}

function Initialize-FleetAgentSettings {
  param([hashtable]$Settings)
  $script:FleetAgentSettings = $Settings
}

function Get-FleetAgentSettings { return $script:FleetAgentSettings }

function Test-FleetAgentElevated {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FleetAgentCurrentUserSid {
  return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-FleetAgentEdition {
  # Edition detection drives provider capability decisions. Home lacks the
  # local Group Policy engine (see docs/platforms/windows/group-policy.md), so the
  # policy provider falls back to direct Policies-hive writes there.
  $caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
  if ($caption -match '(?i)home') { return 'Home' }
  if ($caption -match '(?i)server') { return 'Server' }
  return 'ProOrHigher'
}

function Get-FleetEdition { return Get-FleetAgentEdition }

function Get-FleetAgentPayloadEntries {
  # Enumerates payload key/value pairs for both hashtable and PSCustomObject
  # payloads.
  param($Data)
  if ($Data -is [hashtable]) {
    return @($Data.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value }
      })
  }
  return @($Data.PSObject.Properties)
}

function Invoke-FleetAgentTimeboxed {
  # Runs a CLI with a hard timeout; prevents an interactive prompt in a
  # hidden window from blocking the agent forever.
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
    return @{ TimedOut = $true; Output = "TIMEOUT after ${TimeoutSec}s"; ExitCode = -1 }
  }
  return @{ TimedOut = $false; Output = ($outTask.Result + $errTask.Result); ExitCode = $proc.ExitCode }
}

# =====================================================================
# winget exit-code taxonomy (docs/platforms/windows/winget.md)
# =====================================================================
$script:FleetAgentWingetExitCodes = @{
  '0x8a150014' = 'no-packages-found'
  '0x8a150016' = 'ambiguous-match'
  '0x8a15002b' = 'no-applicable-update'
  '0x8a150010' = 'no-applicable-installer'
  '0x8a150101' = 'package-in-use'
  '0x8a150102' = 'install-in-progress'
  '0x8a150103' = 'file-in-use'
  '0x8a150109' = 'reboot-required-to-finish'
  '0x8a15010a' = 'reboot-required-to-install'
  '0x8a15010d' = 'already-installed'
  '0x8a15010e' = 'downgrade-refused'
  '0x8a150041' = 'package-agreements-not-accepted'
  '0x8a150046' = 'source-agreements-not-accepted'
  '0x8a150076' = 'interactive-auth-required'
  '0x8a150011' = 'installer-hash-mismatch'
  '0x8a150060' = 'archive-malware-scan-failed'
}

function Convert-FleetAgentWingetExitCode {
  param([Parameter(Mandatory)][string]$Code)
  $key = $Code.ToLowerInvariant()
  if ($key -match '^0x0+$' -or $key -eq '0' -or $key -eq '0x00000000') {
    return [pscustomobject]@{ Category = 'ok'; Meaning = 'success' }
  }
  $meaning = $script:FleetAgentWingetExitCodes[$key]
  switch ($meaning) {
    'no-applicable-update' { return [pscustomobject]@{ Category = 'unchanged'; Meaning = $meaning } }
    'already-installed' { return [pscustomobject]@{ Category = 'unchanged'; Meaning = $meaning } }
    'reboot-required-to-finish' { return [pscustomobject]@{ Category = 'reboot-required'; Meaning = $meaning } }
    'reboot-required-to-install' { return [pscustomobject]@{ Category = 'reboot-required'; Meaning = $meaning } }
    'package-in-use' { return [pscustomobject]@{ Category = 'blocked'; Meaning = $meaning } }
    'install-in-progress' { return [pscustomobject]@{ Category = 'blocked'; Meaning = $meaning } }
    'file-in-use' { return [pscustomobject]@{ Category = 'blocked'; Meaning = $meaning } }
    'interactive-auth-required' { return [pscustomobject]@{ Category = 'blocked'; Meaning = $meaning } }
    'installer-hash-mismatch' { return [pscustomobject]@{ Category = 'blocked'; Meaning = $meaning } }
    'archive-malware-scan-failed' { return [pscustomobject]@{ Category = 'blocked'; Meaning = $meaning } }
    'no-applicable-installer' { return [pscustomobject]@{ Category = 'unsupported'; Meaning = $meaning } }
    $null {
      try {
        if ($key -match '^0x[0-9a-f]+$') {
          if ([Convert]::ToInt64($key, 16) -eq 0) { return [pscustomobject]@{ Category = 'ok'; Meaning = 'success' } }
        }
        elseif ($key -match '^\d+$' -and [int64]$key -eq 0) {
          return [pscustomobject]@{ Category = 'ok'; Meaning = 'success' }
        }
      } catch { }
      return [pscustomobject]@{ Category = 'failed'; Meaning = 'raw installer or unknown exit code' }
    }
    default { return [pscustomobject]@{ Category = 'failed'; Meaning = $meaning } }
  }
}

# =====================================================================
# PReg (Registry.pol) codec -- format per docs/platforms/windows/group-policy.md:
# header 'PReg' + version 1, then sequential records: keyLen(2), key
# UTF-16LE, valLen(2), valueName UTF-16LE, type(2), dataLen(4), data.
# =====================================================================
function ConvertTo-FleetAgentRegistryPolBytes {
  param([Parameter(Mandatory)][object[]]$Records)
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([byte[]]@(0x50, 0x52, 0x65, 0x67))
  $bw.Write([uint32]1)
  foreach ($r in $Records) {
    $keyBytes = [System.Text.Encoding]::Unicode.GetBytes([string]$r.Key)
    $valBytes = [System.Text.Encoding]::Unicode.GetBytes([string]$r.ValueName)
    $bw.Write([uint16]$keyBytes.Length); $bw.Write($keyBytes)
    $bw.Write([uint16]$valBytes.Length); $bw.Write($valBytes)
    $bw.Write([uint16][int]$r.Type)
    $bw.Write([uint32]$r.Data.Length); $bw.Write([byte[]]$r.Data)
  }
  $bw.Flush()
  return $ms.ToArray()
}

function ConvertFrom-FleetAgentRegistryPolBytes {
  param([Parameter(Mandatory)][byte[]]$Bytes)
  $records = New-Object System.Collections.Generic.List[object]
  $truncated = $false
  if ($Bytes.Length -lt 8) { throw 'PReg buffer shorter than the 8-byte header' }
  $sig = [System.Text.Encoding]::ASCII.GetString($Bytes[0..3])
  if ($sig -ne 'PReg') { throw "bad PReg signature '$sig'" }
  $version = [BitConverter]::ToUInt32($Bytes, 4)
  if ($version -ne 1) { throw "unsupported PReg version $version" }
  $pos = 8
  while ($pos -lt $Bytes.Length) {
    $remaining = $Bytes.Length - $pos
    if ($remaining -lt 2) { $truncated = $true; break }
    $keyLen = [BitConverter]::ToUInt16($Bytes, $pos)
    if ($remaining -lt (2 + $keyLen + 2)) { $truncated = $true; break }
    $key = [System.Text.Encoding]::Unicode.GetString($Bytes, $pos + 2, $keyLen)
    $valLen = [BitConverter]::ToUInt16($Bytes, $pos + 2 + $keyLen)
    if ($remaining -lt (2 + $keyLen + 2 + $valLen + 6)) { $truncated = $true; break }
    $val = [System.Text.Encoding]::Unicode.GetString($Bytes, $pos + 2 + $keyLen + 2, $valLen)
    $type = [BitConverter]::ToUInt16($Bytes, $pos + 2 + $keyLen + 2 + $valLen)
    $dataLen = [BitConverter]::ToUInt32($Bytes, $pos + 2 + $keyLen + 2 + $valLen + 2)
    $dataStart = $pos + 2 + $keyLen + 2 + $valLen + 2 + 4
    if (($Bytes.Length - $dataStart) -lt $dataLen) { $truncated = $true; break }
    $data = New-Object byte[] $dataLen
    [Array]::Copy($Bytes, $dataStart, $data, 0, $dataLen)
    $pos = $dataStart + $dataLen
    $records.Add([pscustomobject]@{ Key = $key; ValueName = $val; Type = $type; Data = $data })
  }
  return [pscustomobject]@{ Records = $records; Truncated = $truncated }
}

# =====================================================================
# Journal: in-memory list, optionally persisted as JSON lines.
# =====================================================================
$script:FleetAgentJournal = New-Object System.Collections.Generic.List[object]

function Initialize-FleetAgentJournal {
  $script:FleetAgentJournal = New-Object System.Collections.Generic.List[object]
}

function Add-FleetAgentJournalEntry {
  param([string]$PlanId, [string]$ResourceId, [string]$Operation, $PreviousState, $NewState)
  $entry = [pscustomobject]@{
    JournalId     = [guid]::NewGuid().ToString()
    Timestamp     = (Get-Date).ToString('o')
    PlanId        = $PlanId
    ResourceId    = $ResourceId
    Operation     = $Operation
    PreviousState = $PreviousState
    NewState      = $NewState
    Reversed      = $false
  }
  $script:FleetAgentJournal.Add($entry)
  $journalPath = $script:FleetAgentSettings['JournalPath']
  if ($journalPath) {
    $dir = Split-Path -Parent $journalPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $entry | ConvertTo-Json -Depth 6 | Add-Content -Path $journalPath -Encoding UTF8
  }
  return $entry
}

function Get-FleetAgentJournal { return $script:FleetAgentJournal }

function Get-FleetAgentJournalWriteCount {
  param([string]$PlanId)
  # Count real state mutations: script runs and inventory reports are
  # audit-trail entries with no reversal semantics.
  $nonMutating = @('observe', 'script-run', 'inventory-report')
  $writes = @($script:FleetAgentJournal | Where-Object { $_.Operation -notin $nonMutating })
  if ($PlanId) { $writes = @($writes | Where-Object { $_.PlanId -eq $PlanId }) }
  return $writes.Count
}

# =====================================================================
# Plan validation (planVersion 1, docs/platforms/windows/plan-schema.md)
# =====================================================================
$script:FleetAgentRegistryTypes = @('REG_SZ', 'REG_EXPAND_SZ', 'REG_MULTI_SZ', 'REG_DWORD', 'REG_QWORD', 'REG_BINARY')
$script:FleetAgentResourceNames = @(
  'registry.value', 'registry.key', 'policy.setting', 'package.winget',
  'service.state', 'task.scheduled', 'update.settings', 'update.scan',
  'update.install', 'inventory.report', 'script.fleet'
)

function Test-FleetAgentPlan {
  param([Parameter(Mandatory)]$Plan)
  $errors = New-Object System.Collections.Generic.List[string]

  if ($Plan.planVersion -ne 1) { $errors.Add("planVersion must be 1, got '$($Plan.planVersion)'") }
  foreach ($f in @('planId', 'fleetId', 'machineId')) {
    $v = $Plan.$f
    if (-not $v -or $v -isnot [string]) { $errors.Add("$f must be a non-empty string") }
  }
  if ($Plan.mode -and $Plan.mode -notin @('audit', 'apply')) { $errors.Add('mode must be audit or apply') }
  if (-not $Plan.resources) {
    $errors.Add('resources must be a non-empty array')
    return [pscustomobject]@{ Valid = $false; Errors = $errors }
  }

  $ids = @()
  $index = -1
  foreach ($entry in $Plan.resources) {
    $index++
    $label = "resources[$index]"
    if ($entry.resource -notin $script:FleetAgentResourceNames) { $errors.Add("$label unknown resource '$($entry.resource)'") }
    if (-not $entry.id -or $entry.id -isnot [string]) { $errors.Add("$label id must be a non-empty string") }
    if ($entry.ensure -and $entry.ensure -notin @('present', 'absent')) { $errors.Add("$label ensure must be present or absent") }
    if ($entry.mode -and $entry.mode -notin @('audit', 'apply')) { $errors.Add("$label mode must be audit or apply") }
    if ($entry.rebootBehavior -and $entry.rebootBehavior -notin @('report', 'allow')) { $errors.Add("$label rebootBehavior must be report or allow") }
    if ($entry.timeoutSec -and ($entry.timeoutSec -isnot [int] -or $entry.timeoutSec -le 0)) { $errors.Add("$label timeoutSec must be a positive integer") }

    if ($entry.resource -like 'registry.*' -and $entry.id -match '(?i)^HKEY_CURRENT_USER|^HKCU:') {
      $errors.Add("$label HKCU is forbidden; address per-user state with userSid")
    }
    if ($entry.resource -eq 'registry.value') {
      $type = $entry.data.type
      if ($type -and $type -notin $script:FleetAgentRegistryTypes) { $errors.Add("$label data.type '$type' is not a supported registry type") }
      if ($entry.ensure -eq 'present' -and -not $type) { $errors.Add("$label data.type is required when ensure is present") }
    }
    if ($entry.resource -eq 'policy.setting') {
      if ($entry.data.scope -and $entry.data.scope -notin @('machine', 'user')) { $errors.Add("$label data.scope must be machine or user") }
      if ($entry.data.engineMode -and $entry.data.engineMode -notin @('auto', 'direct', 'registryPol')) { $errors.Add("$label data.engineMode must be auto, direct, or registryPol") }
    }

    $ids += $entry.id
  }

  $index = -1
  foreach ($entry in $Plan.resources) {
    $index++
    foreach ($dep in @($entry.dependsOn) | Where-Object { $_ }) {
      $depId = $dep -replace '^[a-z.]+:', ''
      if ($depId -notin $ids) { $errors.Add("resources[$index] dependsOn '$dep' does not resolve") }
    }
  }

  # Cycle detection: Kahn's algorithm.
  $byId = @{}
  foreach ($entry in $Plan.resources) { $byId[$entry.id] = $entry }
  $inDegree = @{}
  foreach ($entry in $Plan.resources) {
    $deps = @($entry.dependsOn) | Where-Object { $_ }
    $inDegree[$entry.id] = @($deps).Count
  }
  $queue = New-Object System.Collections.Queue
  foreach ($k in $inDegree.Keys) { if ($inDegree[$k] -eq 0) { $queue.Enqueue($k) } }
  $visited = 0
  while ($queue.Count -gt 0) {
    $node = $queue.Dequeue()
    $visited++
    foreach ($entry in $Plan.resources) {
      $deps = @($entry.dependsOn) | Where-Object { $_ }
      foreach ($dep in $deps) {
        if (($dep -replace '^[a-z.]+:', '') -eq $node) {
          $inDegree[$entry.id]--
          if ($inDegree[$entry.id] -eq 0) { $queue.Enqueue($entry.id) }
        }
      }
    }
  }
  if ($visited -lt $byId.Count) { $errors.Add('dependsOn contains a cycle') }

  return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors }
}

# =====================================================================
# Provider dispatch and execution
# =====================================================================
$script:FleetAgentProviders = @{
  'registry.value'    = @{ Get = 'Get-FleetAgentRegistryValueState'; Set = 'Set-FleetAgentRegistryValue'; Undo = 'Undo-FleetAgentRegistryValue' }
  'registry.key'      = @{ Get = 'Get-FleetAgentRegistryKeyState'; Set = 'Set-FleetAgentRegistryKey'; Undo = 'Undo-FleetAgentRegistryKey' }
  'policy.setting'    = @{ Get = 'Get-FleetAgentPolicyState'; Set = 'Set-FleetAgentPolicy'; Undo = 'Undo-FleetAgentPolicy' }
  'package.winget'    = @{ Get = 'Get-FleetAgentWingetPackageState'; Set = 'Set-FleetAgentWingetPackage'; Undo = 'Undo-FleetAgentWingetPackage' }
  'service.state'     = @{ Get = 'Get-FleetAgentServiceState'; Set = 'Set-FleetAgentService'; Undo = 'Undo-FleetAgentService' }
  'task.scheduled'    = @{ Get = 'Get-FleetAgentTaskState'; Set = 'Set-FleetAgentScheduledTask'; Undo = 'Undo-FleetAgentScheduledTask' }
  'update.settings'   = @{ Get = 'Get-FleetAgentUpdateSettingsState'; Set = 'Set-FleetAgentUpdateSettings'; Undo = 'Undo-FleetAgentUpdateSettings' }
  'update.scan'       = @{ Get = $null; Set = 'Set-FleetAgentUpdateScan'; Undo = $null }
  'update.install'    = @{ Get = 'Get-FleetAgentUpdateInstallState'; Set = 'Set-FleetAgentUpdateInstall'; Undo = 'Undo-FleetAgentUpdateInstall' }
  'inventory.report'  = @{ Get = 'Get-FleetAgentInventoryState'; Set = 'Set-FleetAgentInventoryReport'; Undo = 'Undo-FleetAgentInventoryReport' }
  'script.fleet'      = @{ Get = 'Get-FleetAgentScriptState'; Set = 'Set-FleetAgentScript'; Undo = 'Undo-FleetAgentScript' }
}

function Get-FleetAgentResourceId {
  param($Entry)
  return "$($Entry.resource):$($Entry.id)"
}

function Resolve-FleetAgentPlanOrder {
  param([Parameter(Mandatory)]$Plan)
  $ordered = New-Object System.Collections.Generic.List[object]
  $remaining = New-Object System.Collections.Generic.List[object]
  foreach ($e in $Plan.resources) { $remaining.Add($e) }
  $done = New-Object System.Collections.Generic.HashSet[string]
  while ($remaining.Count -gt 0) {
    $progress = $false
    for ($i = 0; $i -lt $remaining.Count; $i++) {
      $e = $remaining[$i]
      $ready = $true
      foreach ($dep in (@($e.dependsOn) | Where-Object { $_ })) {
        if (-not $done.Contains(($dep -replace '^[a-z.]+:', ''))) { $ready = $false; break }
      }
      if ($ready) {
        $ordered.Add($e)
        [void]$done.Add($e.id)
        $remaining.RemoveAt($i)
        $progress = $true
        $i--
      }
    }
    if (-not $progress) { throw 'dependency cycle detected during ordering' }
  }
  return $ordered
}

function Invoke-FleetAgentResource {
  # Dispatches one resource entry to its provider. Returns a report row.
  param($Entry, [ValidateSet('audit', 'apply')][string]$Mode, [string]$PlanId)

  $resourceId = Get-FleetAgentResourceId $Entry
  $started = Get-Date
  $status = 'failed'
  $evidence = ''
  $journalId = $null

  $provider = $script:FleetAgentProviders[$Entry.resource]
  if (-not $provider -or -not $provider.Set) {
    $status = 'unsupported'
    $evidence = "resource '$($Entry.resource)' has no provider"
  }
  else {
    $context = @{
      Elevated = Test-FleetAgentElevated
      Edition  = Get-FleetAgentEdition
      PlanId   = $PlanId
      Mode     = $Mode
      Settings = $script:FleetAgentSettings
    }
    # JournalAdd must be an object with a Publish ScriptMethod: hashtable
    # method-style invocation of stored scriptblocks fails in PS 5.1.
    # Publish swallows the entry's own output so provider evidence stays a
    # single clean string.
    $journalAdd = New-Object PSObject
    $journalAdd | Add-Member -MemberType ScriptMethod -Name Publish -Value {
      param($Operation, $PreviousState, $NewState)
      Add-FleetAgentJournalEntry -PlanId $PlanId -ResourceId $resourceId -Operation $Operation -PreviousState $PreviousState -NewState $NewState | Out-Null
    }
    $context.JournalAdd = $journalAdd
    try {
      if ($provider.Get) {
        $observed = & $provider.Get -Entry $Entry -Context $context
      }
      $evidence = & $provider.Set -Entry $Entry -Context $context
      # Providers return evidence; the executor maps it to the report
      # status contract: audit mismatches report drifted, already-matching
      # state reports unchanged, and reboot-required prefixes flag the
      # report.
      $status = 'applied'
      if ($evidence -match '^(already|unchanged|no applicable|script\.fleet is non-convergent)') { $status = 'unchanged' }
      if ($evidence -match '^drifted') { $status = 'drifted' }
      if ($evidence -match '^reboot-required') { $script:FleetAgentRebootRequired = $true }
    }
    catch {
      $msg = $_.Exception.Message
      if ($msg.StartsWith('UNSUPPORTED:')) { $status = 'unsupported'; $evidence = $msg.Substring(12) }
      elseif ($msg.StartsWith('BLOCKED:')) { $status = 'blocked'; $evidence = $msg.Substring(8) }
      else { $status = 'failed'; $evidence = $msg }
    }
  }

  return [pscustomobject]@{
    ResourceId = $resourceId
    Status     = $status
    Evidence   = $evidence
    ErrorCode  = $null
    JournalId  = $journalId
    DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
  }
}

$script:FleetAgentRebootRequired = $false

function Invoke-FleetAgentPlan {
  # Validates and executes a plan document. Returns a report conforming to
  # docs/platforms/windows/plan-schema.md (reportVersion 1).
  param([Parameter(Mandatory)]$Plan, [hashtable]$Settings)

  if ($Settings) { Initialize-FleetAgentSettings -Settings $Settings }
  if ($null -eq $script:FleetAgentJournal) { Initialize-FleetAgentJournal }
  $script:FleetAgentRebootRequired = $false

  $validation = Test-FleetAgentPlan -Plan $Plan
  if (-not $validation.Valid) {
    throw ('invalid plan: ' + ($validation.Errors -join '; '))
  }
  $mode = if ($Plan.mode) { $Plan.mode } else { 'apply' }
  $ordered = Resolve-FleetAgentPlanOrder -Plan $Plan
  $startedAt = (Get-Date).ToString('o')

  $results = New-Object System.Collections.Generic.List[object]
  foreach ($entry in $ordered) {
    $results.Add((Invoke-FleetAgentResource -Entry $entry -Mode $mode -PlanId $Plan.planId))
  }

  return [pscustomobject]@{
    reportVersion  = 1
    planId         = $Plan.planId
    fleetId        = $Plan.fleetId
    machineId      = $Plan.machineId
    kind           = 'apply'
    mode           = $mode
    startedAt      = $startedAt
    finishedAt     = (Get-Date).ToString('o')
    rebootRequired = $script:FleetAgentRebootRequired
    results        = $results
  }
}

function Undo-FleetAgentPlan {
  # Reverses mutations from the journal in reverse order. With -PlanId,
  # only entries from that plan are reversed. Non-mutating entries (script
  # runs, inventory reports) are skipped: they have no reversal semantics.
  param([string]$PlanId)
  $nonMutating = @('observe', 'script-run', 'inventory-report')
  $undone = 0
  for ($i = $script:FleetAgentJournal.Count - 1; $i -ge 0; $i--) {
    $entry = $script:FleetAgentJournal[$i]
    if ($entry.Reversed) { continue }
    if ($PlanId -and $entry.PlanId -ne $PlanId) { continue }
    if ($entry.Operation -in $nonMutating) { continue }
    $provider = $script:FleetAgentProviders[($entry.ResourceId -split ':', 2)[0]]
    if ($provider -and $provider.Undo) {
      try {
        & $provider.Undo -JournalEntry $entry
        $entry.Reversed = $true
        $undone++
      }
      catch {
        Write-Verbose ("undo failed for $($entry.ResourceId): " + $_.Exception.Message)
      }
    }
  }
  return $undone
}

# =====================================================================
# State, drift, and reporting
# =====================================================================
function Save-FleetAgentState {
  # Persists the last applied plan and report under the state directory.
  param([string]$StateDir, $Plan, $Report)
  if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  $Plan | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $StateDir 'last-plan.json') -Encoding UTF8
  $Report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $StateDir 'last-report.json') -Encoding UTF8
}

function Invoke-FleetAgentDrift {
  # Runs the audit mode of the last applied plan and returns a drift
  # report, or $null when no plan has been applied.
  param([string]$StateDir, [string]$ReportPath)
  $lastPlanPath = Join-Path $StateDir 'last-plan.json'
  if (-not (Test-Path $lastPlanPath)) { return $null }
  $plan = Get-Content $lastPlanPath -Raw | ConvertFrom-Json
  $plan.mode = 'audit'
  $report = Invoke-FleetAgentPlan -Plan $plan
  $report.kind = 'drift'
  if ($ReportPath) {
    $report | ConvertTo-Json -Depth 10 | Set-Content $ReportPath -Encoding UTF8
  }
  return $report
}

# =====================================================================
# Provider loading
# =====================================================================
$providerDir = Join-Path $PSScriptRoot 'Resources'
if (Test-Path $providerDir) {
  Get-ChildItem -Path $providerDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Export-ModuleMember -Function @(
  'Initialize-FleetAgentSettings', 'Get-FleetAgentSettings',
  'Test-FleetAgentElevated', 'Get-FleetAgentCurrentUserSid', 'Get-FleetAgentEdition', 'Get-FleetEdition',
  'Get-FleetAgentPayloadEntries', 'Invoke-FleetAgentTimeboxed', 'Convert-FleetAgentWingetExitCode',
  'ConvertTo-FleetAgentRegistryPolBytes', 'ConvertFrom-FleetAgentRegistryPolBytes',
  'Initialize-FleetAgentJournal', 'Add-FleetAgentJournalEntry', 'Get-FleetAgentJournal', 'Get-FleetAgentJournalWriteCount',
  'Test-FleetAgentPlan', 'Resolve-FleetAgentPlanOrder', 'Invoke-FleetAgentPlan', 'Undo-FleetAgentPlan',
  'Save-FleetAgentState', 'Invoke-FleetAgentDrift'
)
