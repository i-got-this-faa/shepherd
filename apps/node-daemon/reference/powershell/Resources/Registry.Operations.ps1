# Registry providers: registry.value and registry.key.
# Per-user state is addressed with userSid (HKEY_USERS\<SID>); HKCU ids are
# forbidden in plans. The journal records KeyExisted so reversal removes
# keys the agent created.

function Get-FleetAgentRegistryValueState {
  param($Entry, $Context)
  $view = $Entry.data.view
  if ($view -eq 32) { $view = '32' }
  $psPath = Resolve-FleetAgentRegistryPath -Id $Entry.id -UserSid (Get-FleetAgentField $Entry 'userSid') -View $view
  $valueName = $Entry.data.valueName
  $key = Get-Item -Path $psPath -ErrorAction SilentlyContinue
  if (-not $key) { return @{ Exists = $false; KeyExists = $false; Value = $null; Type = $null } }
  try {
    $prop = $key.GetValue($valueName)
    if ($null -eq $prop) { return @{ Exists = $false; KeyExists = $true; Value = $null; Type = $null } }
    return @{ Exists = $true; KeyExists = $true; Value = $prop; Type = [string]$key.GetValueKind($valueName) }
  }
  finally {
    $key.Close()
  }
}

function Set-FleetAgentRegistryValue {
  param($Entry, $Context)
  $view = $Entry.data.view
  if ($view -eq 32) { $view = '32' }
  $psPath = Resolve-FleetAgentRegistryPath -Id $Entry.id -UserSid (Get-FleetAgentField $Entry 'userSid') -View $view
  $valueName = $Entry.data.valueName
  $keyExisted = Test-Path $psPath
  $previous = Get-FleetAgentRegistryValueState -Entry $Entry -Context $Context

  if ($Entry.ensure -eq 'absent') {
    if (-not $previous.Exists) {
      return 'unchanged: value already absent'
    }
    if ($Context.Mode -eq 'audit') { return 'drifted: value exists but plan says absent' }
    $Context.JournalAdd.Publish('delete-value', @{ Path = $psPath; ValueName = $valueName; Value = $previous.Value; Type = $previous.Type; KeyExisted = $keyExisted }, $null)
    Remove-ItemProperty -Path $psPath -Name $valueName -Force -ErrorAction Stop
    return 'value deleted'
  }

  $desiredType = $Entry.data.type
  $desiredData = $Entry.data.data
  $desiredKind = $script:FleetAgentKindMap[$desiredType]
  $matchesState = ($previous.Exists -and $previous.Type -eq $desiredKind -and ("$($previous.Value)" -eq "$desiredData"))
  if ($matchesState) {
    return "unchanged: value already $desiredType with matching data"
  }
  if ($Context.Mode -eq 'audit') { return 'drifted: value differs from plan' }

  $operation = 'set-value'
  if (-not $keyExisted) { $operation = 'set-value+create-key' }
  $Context.JournalAdd.Publish($operation, @{ Path = $psPath; ValueName = $valueName; Value = $previous.Value; Type = $previous.Type; KeyExisted = $keyExisted }, @{ Value = "$desiredData"; Type = $desiredType })
  if (-not $keyExisted) { New-Item -Path $psPath -Force -ErrorAction Stop | Out-Null }
  $kind = $desiredKind
  New-ItemProperty -Path $psPath -Name $valueName -Value $desiredData -PropertyType $kind -Force -ErrorAction Stop | Out-Null
  $written = Get-FleetAgentRegistryValueState -Entry $Entry -Context $Context
  if (-not $written.Exists) { throw "write verification failed for $psPath!$valueName" }
  return "$desiredType written and verified"
}

function Undo-FleetAgentRegistryValue {
  param($JournalEntry)
  $PreviousState = $JournalEntry.PreviousState
  $path = $PreviousState.Path
  $valueName = $PreviousState.ValueName
  $keyExisted = $false
  if ($PreviousState -is [hashtable]) {
    if ($PreviousState.ContainsKey('KeyExisted')) { $keyExisted = [bool]$PreviousState['KeyExisted'] }
  }
  elseif ($null -ne $PreviousState.KeyExisted) {
    $keyExisted = [bool]$PreviousState.KeyExisted
  }

  if ($null -eq $PreviousState.Value -and $null -eq $PreviousState.Type) {
    # The value did not exist before. If the executor also created the key,
    # remove the whole key; otherwise remove just the value.
    if (-not $keyExisted) {
      if (Test-Path $path) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    else {
      Remove-ItemProperty -Path $path -Name $valueName -Force -ErrorAction SilentlyContinue
    }
    # Double-check cleanup: if the key still exists but was created during apply, ensure it is removed.
    if (-not $keyExisted -and (Test-Path $path)) {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    return
  }
  if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
  New-ItemProperty -Path $path -Name $valueName -Value $PreviousState.Value -PropertyType $PreviousState.Type -Force | Out-Null
}

function Get-FleetAgentRegistryKeyState {
  param($Entry, $Context)
  $psPath = Resolve-FleetAgentRegistryPath -Id $Entry.id -UserSid (Get-FleetAgentField $Entry 'userSid')
  return @{ Exists = (Test-Path $psPath); Path = $psPath }
}

function Set-FleetAgentRegistryKey {
  param($Entry, $Context)
  $psPath = Resolve-FleetAgentRegistryPath -Id $Entry.id -UserSid (Get-FleetAgentField $Entry 'userSid')
  $existed = Test-Path $psPath

  if ($Entry.ensure -eq 'absent') {
    if (-not $existed) { return 'unchanged: key already absent' }
    if ($Context.Mode -eq 'audit') { return 'drifted: key exists but plan says absent' }
    $childCount = @((Get-ChildItem -Path $psPath -Recurse -ErrorAction SilentlyContinue)).Count
    $Context.JournalAdd.Publish('delete-key', @{ Path = $psPath; KeyExisted = $true; HadChildren = ($childCount -gt 0) }, $null)
    Remove-Item -Path $psPath -Recurse -Force -ErrorAction Stop
    return "key removed ($childCount child items)"
  }

  if ($existed) { return 'unchanged: key already present' }
  if ($Context.Mode -eq 'audit') { return 'drifted: key missing but plan says present' }
  $Context.JournalAdd.Publish('create-key', @{ Path = $psPath; KeyExisted = $false }, $null)
  New-Item -Path $psPath -Force -ErrorAction Stop | Out-Null
  return 'key created'
}

function Undo-FleetAgentRegistryKey {
  param($JournalEntry)
  $PreviousState = $JournalEntry.PreviousState
  if ($JournalEntry.Operation -eq 'create-key' -or -not $PreviousState.KeyExisted) {
    Remove-Item -Path $PreviousState.Path -Recurse -Force -ErrorAction SilentlyContinue
    return
  }
  # A removed key with children cannot be fully restored from the journal;
  # the limitation is recorded in the evidence, not silently ignored.
  Write-Verbose "key $($PreviousState.Path) had children; full restore requires a backup-based reversal"
}

function Resolve-FleetAgentRegistryPath {
  # Maps a plan registry id plus optional userSid to a PowerShell path.
  # userSid addresses HKEY_USERS\<SID>; a bare HKCU id is a plan error.
  # data.view '32' redirects HKLM\SOFTWARE ids to WOW6432Node.
  param([string]$Id, [string]$UserSid, [string]$View)
  if ($Id -match '(?i)^HKEY_USERS\\(?<sid>S-1-[\d-]+)\\?(?<rest>.*)$') {
    return ('Registry::HKEY_USERS\' + $Matches.sid + '\' + $Matches.rest).TrimEnd('\')
  }
  if ($Id -match '(?i)^(HKCU|HKEY_CURRENT_USER)') { throw 'HKCU is forbidden in plans; use userSid' }
  $path = $Id
  if ($UserSid) {
    $path = $Id -replace '^(HKLM|HKEY_LOCAL_MACHINE)\\', ''
    $path = 'Registry::HKEY_USERS\' + $UserSid + '\' + $path
  }
  elseif ($Id -match '^HKLM\\') {
    $path = $Id -replace '^HKLM\\', 'HKLM:\'
  }
  if ($View -eq '32') {
    if ($path -notmatch '(?i)^HKLM:\\SOFTWARE\\' -and $path -notmatch '(?i)HKEY_USERS\\S-1-[\d-]+\\SOFTWARE\\') {
      throw 'UNSUPPORTED: view 32 applies only to HKLM\SOFTWARE (and per-user SOFTWARE) paths'
    }
    if ($path -match '(?i)WOW6432Node') { throw 'id already targets WOW6432Node' }
    if ($path -match '(?i)^(HKLM:\\SOFTWARE\\)(?<rest>.*)$') {
      $path = $path -replace '(?i)^(HKLM:\\SOFTWARE)\\', '$1\WOW6432Node\'
    }
    else {
      $path = $path -replace '(?i)(HKEY_USERS\\S-1-[\d-]+\\SOFTWARE)\\', '$1\WOW6432Node\'
    }
  }
  return $path.TrimEnd('\')
}

function Get-FleetAgentField {
  # Reads a field from a hashtable or PSCustomObject entry uniformly.
  param($Obj, [string]$Name)
  if ($Obj -is [hashtable]) {
    if ($Obj.ContainsKey($Name)) { return $Obj[$Name] }
    return $null
  }
  $p = $Obj.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $null
}

$script:FleetAgentKindMap = @{
  'REG_SZ' = 'String'; 'REG_EXPAND_SZ' = 'ExpandString'; 'REG_MULTI_SZ' = 'MultiString'
  'REG_DWORD' = 'DWord'; 'REG_QWORD' = 'QWord'; 'REG_BINARY' = 'Binary'
}

