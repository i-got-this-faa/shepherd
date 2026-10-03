# Service state provider: query, ensure startup type and running state,
# create missing services when data.binaryPath is declared (schema
# extension), and reverse from the journal. Requires elevation.

function Get-FleetAgentServiceState {
  param($Entry, $Context)
  if (-not $Context.Elevated) { throw 'UNSUPPORTED: service.state requires elevation' }
  $svc = Get-Service -Name $Entry.id -ErrorAction SilentlyContinue
  if (-not $svc) { return @{ Exists = $false } }
  return @{ Exists = $true; Status = [string]$svc.Status; StartType = [string]$svc.StartType }
}

function Set-FleetAgentService {
  param($Entry, $Context)
  if (-not $Context.Elevated) { throw 'UNSUPPORTED: service.state requires elevation' }
  $svc = Get-Service -Name $Entry.id -ErrorAction SilentlyContinue

  if (-not $svc) {
    $binaryPath = $Entry.data.binaryPath
    if ($Entry.ensure -eq 'absent') { return 'unchanged: service already absent' }
    if (-not $binaryPath) { throw "service '$($Entry.id)' does not exist and data.binaryPath is not declared" }
    if ($Context.Mode -eq 'audit') { return 'drifted: service missing but plan says present' }
    $displayName = $Entry.data.displayName
    if ($displayName) {
      New-Service -Name $Entry.id -BinaryPathName $binaryPath -DisplayName $displayName -StartupType Manual -ErrorAction Stop | Out-Null
    }
    else {
      New-Service -Name $Entry.id -BinaryPathName $binaryPath -StartupType Manual -ErrorAction Stop | Out-Null
    }
    $Context.JournalAdd.Publish('create-service', @{ Existed = $false }, @{ Created = $true })
    $svc = Get-Service -Name $Entry.id -ErrorAction Stop
  }

  $previous = @{ Status = [string]$svc.Status; StartType = [string]$svc.StartType }
  $desiredStatus = if ($Entry.data.status) { $Entry.data.status } else { $previous.Status }
  $desiredStart = if ($Entry.data.startupType) { $Entry.data.startupType } else { $previous.StartType }
  $matchesState = ($previous.Status -ieq $desiredStatus -and $previous.StartType -ieq $desiredStart)
  if ($matchesState) { return 'unchanged: service already in desired state' }
  if ($Context.Mode -eq 'audit') { return 'drifted: service state differs from plan' }

  $Context.JournalAdd.Publish('set-service', $previous, @{ Status = $desiredStatus; StartType = $desiredStart })
  if ($previous.StartType -ine $desiredStart) { Set-Service -Name $Entry.id -StartupType $desiredStart -ErrorAction Stop }
  if ($desiredStatus -ieq 'running' -and $svc.Status -ine 'Running') { Start-Service -Name $Entry.id -ErrorAction Stop }
  if ($desiredStatus -ieq 'stopped' -and $svc.Status -ine 'Stopped') { Stop-Service -Name $Entry.id -Force -ErrorAction Stop }
  return "service set to $desiredStatus/$desiredStart"
}

function Undo-FleetAgentService {
  param($JournalEntry)
  $PreviousState = $JournalEntry.PreviousState
  $name = ($JournalEntry.ResourceId -split ':', 2)[1]
  if ($JournalEntry.Operation -eq 'create-service' -or $PreviousState.Existed -eq $false) {
    & sc.exe delete $name | Out-Null
    return
  }
  Set-Service -Name $name -StartupType $PreviousState.StartType -ErrorAction SilentlyContinue
  if ($PreviousState.Status -eq 'Running') { Start-Service -Name $name -ErrorAction SilentlyContinue }
  elseif ($PreviousState.Status -eq 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
}

