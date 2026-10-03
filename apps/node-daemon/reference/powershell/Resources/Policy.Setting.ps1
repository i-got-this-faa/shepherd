# Group Policy provider: authors local policy the way a domain controller
# would, so native tooling stays valid.
#
# Two engine modes (data.engineMode, default 'auto'):
#   'registryPol' - write records into the local GPO Registry.pol, bump
#     GPT.ini, trigger a refresh. The supported path on Pro and higher.
#   'direct'      - write the policy values straight into the
#     SOFTWARE\Policies hives through the registry. Required on Home,
#     where the policy core filters out the local GPO entirely
#     (docs/platforms/windows/group-policy.md, evidence: operational log events
#     5312/5313).
# 'auto' picks registryPol on Pro/Server and direct on Home.
#
# Payload: { scope: 'machine'|'user', engineMode: 'auto'|'direct'|'registryPol',
#             values: [ { keyPath ('SOFTWARE\Policies\...'), valueName, type (REG_*), data } ],
#             refresh: bool (default true) }
# ensure 'absent' removes the declared values from Registry.pol ('**del.'
# semantics at refresh) or deletes the direct values.

$script:FleetAgentRegPolTypeCodes = @{
  'REG_SZ' = 1; 'REG_EXPAND_SZ' = 2; 'REG_BINARY' = 3; 'REG_DWORD' = 4
  'REG_MULTI_SZ' = 7; 'REG_QWORD' = 11
}

function Get-FleetAgentPolicyState {
  param($Entry, $Context)
  $state = @{ EngineMode = (Resolve-FleetAgentPolicyEngineMode -Entry $Entry -Context $Context); Values = @() }
  $scope = if ($Entry.data.scope) { $Entry.data.scope } else { 'machine' }
  $hiveRoot = if ($scope -eq 'user') { throw 'UNSUPPORTED: user-scope policy needs per-user hive addressing (v1 supports machine scope)' } else { 'HKLM:\SOFTWARE\Policies' }
  foreach ($v in Get-FleetAgentPolicyValues -Entry $Entry) {
    $fullPath = Join-FleetAgentPolicyPath -HiveRoot $hiveRoot -KeyPath $v.keyPath
    $key = Get-Item -Path $fullPath -ErrorAction SilentlyContinue
    $current = if ($key) { $key.GetValue($v.valueName) } else { $null }
    $state.Values += @{ KeyPath = $v.keyPath; ValueName = $v.valueName; Data = $current }
  }
  return $state
}

function Set-FleetAgentPolicy {
  param($Entry, $Context)
  $engineMode = Resolve-FleetAgentPolicyEngineMode -Entry $Entry -Context $Context
  $values = Get-FleetAgentPolicyValues -Entry $Entry
  if ($values.Count -eq 0) { throw 'UNSUPPORTED: policy.setting payload declares no values' }
  $scope = if ($Entry.data.scope) { $Entry.data.scope } else { 'machine' }
  if ($scope -ne 'machine') { throw 'UNSUPPORTED: user-scope policy needs per-user hive addressing (v1 supports machine scope)' }

  if ($engineMode -eq 'registryPol') {
    if (-not $Context.Elevated) { throw 'UNSUPPORTED: registryPol engine requires elevation' }
    return Set-FleetAgentPolicyViaRegistryPol -Values $values -Ensure $Entry.ensure -Entry $Entry -Context $Context
  }
  return Set-FleetAgentPolicyViaDirectHive -Values $values -Ensure $Entry.ensure -Entry $Entry -Context $Context
}

function Resolve-FleetAgentPolicyEngineMode {
  param($Entry, $Context)
  $requested = $Entry.data.engineMode
  if ($requested -and $requested -ne 'auto') { return $requested }
  if ($Context.Edition -eq 'Home') { return 'direct' }
  return 'registryPol'
}

function Get-FleetAgentPolicyValues {
  # Normalizes data.values into @{ keyPath; valueName; type; data } entries.
  param($Entry)
  $out = New-Object System.Collections.Generic.List[object]
  $rawValues = $Entry.data.values
  if ($rawValues -is [System.Collections.IEnumerable] -and $rawValues -isnot [string] -and $rawValues -isnot [hashtable]) {
    foreach ($item in $rawValues) {
      if (-not $item) { continue }
      $out.Add([pscustomobject]@{
        keyPath   = [string]$item.keyPath
        valueName = [string]$item.valueName
        type      = [string]$item.type
        data      = $item.data
      })
    }
  }
  elseif ($rawValues -is [hashtable]) {
    foreach ($item in $rawValues.Values) {
      if (-not $item) { continue }
      $out.Add([pscustomobject]@{
        keyPath   = [string]$item.keyPath
        valueName = [string]$item.valueName
        type      = [string]$item.type
        data      = $item.data
      })
    }
  }
  elseif ($rawValues) {
    foreach ($v in Get-FleetAgentPayloadEntries -Data $rawValues) {
      $item = $v.Value
      if (-not $item) { continue }
      $out.Add([pscustomobject]@{
        keyPath   = [string]$item.keyPath
        valueName = [string]$item.valueName
        type      = [string]$item.type
        data      = $item.data
      })
    }
  }
  return , $out.ToArray()
}

function Join-FleetAgentPolicyPath {
  param([string]$HiveRoot, [string]$KeyPath)
  $kp = $KeyPath -replace '^SOFTWARE\\Policies\\', ''
  return (Join-Path $HiveRoot $kp)
}

function Convert-FleetAgentPolicyDataToBytes {
  param([string]$Type, $Data)
  switch ($Type) {
    'REG_SZ' { return [System.Text.Encoding]::Unicode.GetBytes("$Data" + [char]0) }
    'REG_EXPAND_SZ' { return [System.Text.Encoding]::Unicode.GetBytes("$Data" + [char]0) }
    'REG_MULTI_SZ' {
      $ms = New-Object System.IO.MemoryStream
      foreach ($s in @($Data)) {
        $ms.Write([System.Text.Encoding]::Unicode.GetBytes("$s" + [char]0), 0, ("$s" + [char]0).Length * 2)
      }
      $ms.Write([byte[]]@(0, 0), 0, 2)
      return $ms.ToArray()
    }
    'REG_DWORD' { return [BitConverter]::GetBytes([uint32]$Data) }
    'REG_QWORD' { return [BitConverter]::GetBytes([uint64]$Data) }
    'REG_BINARY' { return [byte[]]$Data }
    default { throw "unsupported policy value type '$Type'" }
  }
}

function Set-FleetAgentPolicyViaRegistryPol {
  param($Values, [string]$Ensure, $Entry, $Context)
  $gpoDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine'
  $polPath = Join-Path $gpoDir 'Registry.pol'
  $gptPath = Join-Path $env:WINDIR 'System32\GroupPolicy\GPT.ini'
  $polExisted = Test-Path $polPath
  $gptExisted = Test-Path $gptPath

  # Merge with existing records: upsert ours, and on 'absent' emit the
  # documented '**del.' delete-record instead.
  $existing = @()
  if ($polExisted) {
    $parsed = ConvertFrom-FleetAgentRegistryPolBytes -Bytes ([System.IO.File]::ReadAllBytes($polPath))
    $existing = @($parsed.Records)
  }
  $keyPaths = @{}
  $newRecords = @()
  foreach ($v in $Values) {
    $keyPaths[$v.keyPath] = $true
    $existing = @($existing | Where-Object { -not ($_.Key -ieq $v.keyPath -and $_.ValueName -ieq $v.valueName) })
    if ($Ensure -eq 'present') {
      $newRecords += @{
        Key       = $v.keyPath
        ValueName = $v.valueName
        Type      = $script:FleetAgentRegPolTypeCodes[$v.type]
        Data      = (Convert-FleetAgentPolicyDataToBytes -Type $v.type -Data $v.data)
      }
    }
    else {
      $newRecords += @{
        Key       = $v.keyPath
        ValueName = '**del.' + $v.valueName
        Type      = 4
        Data      = [byte[]]@(0, 0, 0, 0)
      }
    }
  }
  $allRecords = @($existing) + @($newRecords)

  $previousGptVersion = 0
  if ($gptExisted) {
    $m = (Get-Content $gptPath -Raw) | Select-String 'Version\s*=\s*(\d+)' | Select-Object -First 1
    if ($m) { $previousGptVersion = [int]$m.Matches[0].Groups[1].Value }
  }

  if ($Context.Mode -eq 'audit') {
    # Audit inspects the Registry.pol content without touching it.
    $drifted = $false
    foreach ($v in $Values) {
      $present = @($existing | Where-Object { $_.Key -ieq $v.keyPath -and $_.ValueName -ieq $v.valueName }).Count -gt 0
      if (($Ensure -eq 'present' -and -not $present) -or ($Ensure -eq 'absent' -and $present)) { $drifted = $true }
    }
    if ($drifted) { return 'drifted: Registry.pol does not match the declared policy' }
    return 'unchanged: Registry.pol already matches'
  }

  $Context.JournalAdd.Publish('set-policy-registrypol',
    @{ PolExisted = $polExisted; GptExisted = $gptExisted; GptVersion = $previousGptVersion; Values = $Values },
    @{ AppliedRecords = $allRecords.Count })

  if (-not $polExisted) { New-Item -ItemType Directory -Force -Path $gpoDir -ErrorAction Stop | Out-Null }
  [System.IO.File]::WriteAllBytes($polPath, (ConvertTo-FleetAgentRegistryPolBytes -Records $allRecords))

  # GPT.ini version bump: the engine tracks the GPO version through it.
  $newVersion = $previousGptVersion + 1
  if ($gptExisted) {
    $content = Get-Content $gptPath -Raw
    if ($content -match 'Version\s*=\s*\d+') {
      $content = $content -replace 'Version\s*=\s*\d+', "Version=$newVersion"
    }
    else {
      $content = $content + "`r`nVersion=$newVersion"
    }
    Set-Content -Path $gptPath -Value $content -Encoding ASCII
  }
  else {
    Set-Content -Path $gptPath -Value "[General]`r`nVersion=$newVersion`r`nDisplayName=Local Group Policy`r`nDescription=Local Group Policy`r`n" -Encoding ASCII
  }

  if ($Entry.data.refresh -ne $false) {
    & gpupdate /target:computer /force | Out-Null
  }
  return "Registry.pol written ($($allRecords.Count) records), GPT.ini bumped to $newVersion, refresh triggered"
}

function Set-FleetAgentPolicyViaDirectHive {
  param($Values, [string]$Ensure, $Entry, $Context)
  if (-not $Context.Elevated) { throw 'UNSUPPORTED: direct policy writes to HKLM require elevation' }
  $hiveRoot = 'HKLM:\SOFTWARE\Policies'
  $previous = @{}
  foreach ($v in $Values) {
    $fullPath = Join-FleetAgentPolicyPath -HiveRoot $hiveRoot -KeyPath $v.keyPath
    $key = Get-Item -Path $fullPath -ErrorAction SilentlyContinue
    $current = if ($key) { $key.GetValue($v.valueName) } else { $null }
    $previous[$v.keyPath + '|' + $v.valueName] = $current
  }
  $differs = $false
  foreach ($v in $Values) {
    $current = $previous[$v.keyPath + '|' + $v.valueName]
    if ($Ensure -eq 'present' -and "$current" -ne "$($v.data)") { $differs = $true }
    if ($Ensure -eq 'absent' -and $null -ne $current) { $differs = $true }
  }
  if (-not $differs) { return 'unchanged: policy values already match' }
  if ($Context.Mode -eq 'audit') { return 'drifted: policy values differ from plan' }

  $Context.JournalAdd.Publish('set-policy-direct', $previous, (@($Values) | ForEach-Object { "$($_.keyPath)!$($_.valueName)=$($_.data)" }))
  foreach ($v in $Values) {
    $fullPath = Join-FleetAgentPolicyPath -HiveRoot $hiveRoot -KeyPath $v.keyPath
    if ($Ensure -eq 'absent') {
      Remove-ItemProperty -Path $fullPath -Name $v.valueName -Force -ErrorAction SilentlyContinue
      continue
    }
    if (-not (Test-Path $fullPath)) { New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null }
    $kind = $script:FleetAgentKindMap[$v.type]
    New-ItemProperty -Path $fullPath -Name $v.valueName -Value $v.data -PropertyType $kind -Force -ErrorAction Stop | Out-Null
  }
  return "direct policy values written: $(($Values | ForEach-Object { $_.keyPath + '!' + $_.valueName }) -join ', ')"
}

function Undo-FleetAgentPolicy {
  param($JournalEntry)
  $PreviousState = $JournalEntry.PreviousState
  $isDirect = ($JournalEntry.Operation -eq 'set-policy-direct')
  if (-not $isDirect) {
    if ($PreviousState -is [hashtable]) {
      $isDirect = (-not $PreviousState.ContainsKey('Values'))
    }
    else {
      $isDirect = ($null -eq $PreviousState.Values)
    }
  }
  if ($isDirect) {
    # Direct-hive reversal: restore previous values or delete them.
    $polPath = 'HKLM:\SOFTWARE\Policies'
    foreach ($p in Get-FleetAgentPayloadEntries -Data $PreviousState) {
      if ($p.Name -notmatch '\|') { continue }
      $parts = $p.Name -split '\|', 2
      $fullPath = Join-FleetAgentPolicyPath -HiveRoot $polPath -KeyPath $parts[0]
      if ($null -eq $p.Value) {
        Remove-ItemProperty -Path $fullPath -Name $parts[1] -Force -ErrorAction SilentlyContinue
      }
      else {
        if (-not (Test-Path $fullPath)) { New-Item -Path $fullPath -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $fullPath -Name $parts[1] -Value $p.Value -ErrorAction SilentlyContinue
      }
    }
    return
  }
  # registryPol reversal: restore the previous Registry.pol and GPT.ini.
  $gpoDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine'
  $polPath = Join-Path $gpoDir 'Registry.pol'
  $gptPath = Join-Path $env:WINDIR 'System32\GroupPolicy\GPT.ini'
  if (-not $PreviousState.PolExisted) {
    Remove-Item $polPath -Force -ErrorAction SilentlyContinue
  }
  if (-not $PreviousState.GptExisted) {
    Remove-Item $gptPath -Force -ErrorAction SilentlyContinue
  }
  elseif ($PreviousState.GptVersion -gt 0) {
    $content = Get-Content $gptPath -Raw
    $content = $content -replace 'Version\s*=\s*\d+', "Version=$($PreviousState.GptVersion)"
    Set-Content -Path $gptPath -Value $content -Encoding ASCII
  }
  & gpupdate /target:computer /force | Out-Null
}
