# Windows Update settings provider: writes the fleet's update policy values
# under HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate and reverses
# them from the journal. Requires elevation; values ride on the registry
# surface so a policy refresh never fights the agent.

function Get-FleetAgentUpdateSettingsState {
  param($Entry, $Context)
  if (-not $Context.Elevated) { throw 'UNSUPPORTED: update.settings requires elevation' }
  $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $state = @{}
  foreach ($p in Get-FleetAgentPayloadEntries -Data $Entry.data) {
    $state[$p.Name] = (Get-ItemProperty -Path $polPath -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
  }
  return $state
}

function Set-FleetAgentUpdateSettings {
  param($Entry, $Context)
  if (-not $Context.Elevated) { throw 'UNSUPPORTED: update.settings requires elevation' }
  $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $entries = Get-FleetAgentPayloadEntries -Data $Entry.data

  $previous = @{}
  foreach ($p in $entries) {
    $previous[$p.Name] = (Get-ItemProperty -Path $polPath -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
  }
  $differs = $false
  foreach ($p in $entries) {
    $current = (Get-ItemProperty -Path $polPath -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
    if ("$current" -ne "$($p.Value)") { $differs = $true }
  }
  if (-not $differs) { return 'unchanged: policy values already match' }
  if ($Context.Mode -eq 'audit') { return 'drifted: policy values differ from plan' }

  $Context.JournalAdd.Publish('set-update-policy', $previous, (@($entries) | ForEach-Object { "$($_.Name)=$($_.Value)" }))
  if (-not (Test-Path $polPath)) { New-Item -Path $polPath -Force -ErrorAction Stop | Out-Null }
  foreach ($p in $entries) {
    if ($p.Value -is [int] -or $p.Value -is [long]) {
      New-ItemProperty -Path $polPath -Name $p.Name -Value $p.Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    }
    else {
      New-ItemProperty -Path $polPath -Name $p.Name -Value "$($p.Value)" -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
  }
  return "policy values written: $(($entries | ForEach-Object Name) -join ', ')"
}

function Undo-FleetAgentUpdateSettings {
  param($JournalEntry)
  $PreviousState = $JournalEntry.PreviousState
  $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  foreach ($p in Get-FleetAgentPayloadEntries -Data $PreviousState) {
    if ($null -eq $p.Value -or "$($p.Value)" -eq '') {
      Remove-ItemProperty -Path $polPath -Name $p.Name -Force -ErrorAction SilentlyContinue
    }
    else {
      $v = $p.Value
      if ($v -is [int] -or $v -is [long]) {
        New-ItemProperty -Path $polPath -Name $p.Name -Value $v -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
      }
      else {
        New-ItemProperty -Path $polPath -Name $p.Name -Value "$v" -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
      }
    }
  }
}

