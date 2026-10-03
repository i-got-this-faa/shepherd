# winget package provider: exact-id installs, upgrades, and removals with
# hard timeouts, full agreement flags, and exit codes mapped through the
# documented taxonomy. Machine scope requires elevation. Audit mode
# observes and reports drift without touching the machine.

function Get-FleetAgentWingetPackageState {
  param($Entry, $Context)
  $winget = Resolve-FleetAgentWingetPath
  $probe = Invoke-FleetAgentTimeboxed -FileName $winget `
    -Arguments @('list', '--id', $Entry.data.packageId, '--exact', '--accept-source-agreements', '--disable-interactivity') `
    -TimeoutSec 180
  if ($probe.TimedOut) { throw "BLOCKED: winget list timed out after 180s" }
  if ($probe.Output -match 'No installed package found') {
    return @{ Installed = $false; Version = $null }
  }
  $version = $null
  if ($probe.Output -match [regex]::Escape($Entry.data.packageId) + '\s+(\S+)') { $version = $Matches[1] }
  return @{ Installed = $true; Version = $version }
}

function Set-FleetAgentWingetPackage {
  param($Entry, $Context)
  $winget = Resolve-FleetAgentWingetPath
  $packageId = $Entry.data.packageId
  $scope = if ($Entry.data.scope) { $Entry.data.scope } else { 'machine' }
  if ($scope -eq 'machine' -and -not $Context.Elevated) {
    throw 'UNSUPPORTED: machine-scope package management requires elevation'
  }

  $previous = Get-FleetAgentWingetPackageState -Entry $Entry -Context $Context
  $desiredVersion = if ($Entry.data.version) { $Entry.data.version } else { 'latest' }

  if ($Entry.ensure -eq 'absent') {
    if (-not $previous.Installed) { return 'unchanged: package already absent' }
    if ($Context.Mode -eq 'audit' -or $Entry.mode -eq 'audit') { return 'drifted: package installed but plan says absent' }
    $Context.JournalAdd.Publish('winget-uninstall', @{ Installed = $true; Version = $previous.Version }, @{ Installed = $false })
    $uninstall = Invoke-FleetAgentTimeboxed -FileName $winget `
      -Arguments @('uninstall', '--id', $packageId, '--exact', '--silent', '--disable-interactivity') `
      -TimeoutSec 600
    $mapped = Map-FleetAgentWingetResult -ExitCode $uninstall.ExitCode -Output $uninstall.Output -Verb 'uninstall'
    return $mapped
  }

  if ($previous.Installed) {
    $versionMatches = ($desiredVersion -ne 'latest' -and $previous.Version -eq $desiredVersion)
    if ($versionMatches) { return "unchanged: package already installed at $desiredVersion" }
    if ($Context.Mode -eq 'audit' -or $Entry.mode -eq 'audit') {
      if ($desiredVersion -eq 'latest') { return 'unchanged: package installed; latest check requires apply (upgrade)' }
      return "drifted: package at $($previous.Version), plan wants $desiredVersion"
    }
    # Installed: upgrade when 'latest' was requested and a newer version
    # exists; a no-upgrade result maps to unchanged through the taxonomy.
    # The upgrade mutates the machine, so it is journaled before it runs;
    # version reversal is not possible (no old-version source guarantee)
    # and the evidence records that honestly.
    $Context.JournalAdd.Publish('winget-upgrade', @{ Installed = $true; Version = $previous.Version }, @{ Installed = $true; Version = 'latest' })
    $upgrade = Invoke-FleetAgentTimeboxed -FileName $winget `
      -Arguments @('upgrade', '--id', $packageId, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') `
      -TimeoutSec 600
    $mapped = Map-FleetAgentWingetResult -ExitCode $upgrade.ExitCode -Output $upgrade.Output -Verb 'upgrade'
    return $mapped
  }

  if ($Context.Mode -eq 'audit' -or $Entry.mode -eq 'audit') { return 'drifted: package missing but plan says present' }
  $Context.JournalAdd.Publish('winget-install', @{ Installed = $false; Version = $null }, @{ Installed = $true })
  $installArgs = @('install', '--id', $packageId, '--exact', '--silent', "--scope", $scope, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--source', 'winget')
  if ($desiredVersion -ne 'latest') { $installArgs += @('--version', $desiredVersion) }
  $install = Invoke-FleetAgentTimeboxed -FileName $winget -Arguments $installArgs -TimeoutSec 600
  return Map-FleetAgentWingetResult -ExitCode $install.ExitCode -Output $install.Output -Verb 'install'
}

function Undo-FleetAgentWingetPackage {
  param($JournalEntry)
  $PreviousState = $JournalEntry.PreviousState
  if ($PreviousState.Installed) { return 'previous state had the package installed; no reversal performed' }
  $winget = Resolve-FleetAgentWingetPath
  $packageId = ($JournalEntry.ResourceId -split ':', 2)[1]
  $uninstall = Invoke-FleetAgentTimeboxed -FileName $winget `
    -Arguments @('uninstall', '--id', $packageId, '--exact', '--silent', '--disable-interactivity') `
    -TimeoutSec 600
  if ($uninstall.ExitCode -ne 0 -and $uninstall.Output -notmatch '(?i)Successfully uninstalled') {
    throw "winget undo uninstall exit $($uninstall.ExitCode): $($uninstall.Output)"
  }
}

function Resolve-FleetAgentWingetPath {
  $winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
  if (-not $winget) { $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe' }
  if (-not (Test-Path $winget)) { throw 'UNSUPPORTED: winget (App Installer) is not available' }
  return $winget
}

function Map-FleetAgentWingetResult {
  param([int]$ExitCode, [string]$Output, [string]$Verb)
  $hex = '0x{0:X8}' -f ($ExitCode -band 0xFFFFFFFF)
  $mapped = Convert-FleetAgentWingetExitCode -Code $hex
  $tail = ($Output.Trim() -split "`n" | Select-Object -Last 2) -join ' | '

  if ($Output -match '(?i)Successfully\s+(installed|uninstalled|upgraded)') {
    if ($Output -match '(?i)reboot.*required') {
      return "reboot-required: success; reboot required to complete ($hex); $tail"
    }
    return "$Verb succeeded ($hex)"
  }
  if ($Output -match '(?i)No (newer package versions are available|applicable update found)') {
    return "unchanged: no-applicable-update ($hex)"
  }
  if ($ExitCode -eq 0 -or $hex -eq '0x00000000') {
    if ($Output -match '(?i)reboot.*required') {
      return "reboot-required: success; reboot required to complete ($hex); $tail"
    }
    return "$Verb succeeded ($hex)"
  }

  switch ($mapped.Category) {
    'ok' { return "$Verb succeeded ($hex)" }
    'unchanged' { return "unchanged: $($mapped.Meaning) ($hex)" }
    'reboot-required' { return "reboot-required: $($mapped.Meaning) ($hex); $tail" }
    'blocked' { throw "BLOCKED: $($mapped.Meaning) ($hex): $tail" }
    'unsupported' { throw "UNSUPPORTED: $($mapped.Meaning) ($hex)" }
    default { throw "winget $Verb failed: $($mapped.Meaning) ($hex): $tail" }
  }
}
