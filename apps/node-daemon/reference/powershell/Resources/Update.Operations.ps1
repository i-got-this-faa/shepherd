# Windows Update provider operations: scan trigger, targeted install inside a
# maintenance window, install-state query, and the no-op reversal. Evidence is
# a single observed-fact line per action; install rides the Microsoft Update
# COM API inline (the executor's per-resource timeout bounds the whole call).

function Set-FleetAgentUpdateScan {
  # Non-convergent observation trigger: fires StartScan and verifies the
  # WindowsUpdateClient operational log produced a new event afterwards.
  param($Entry, $Context)

  $logName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
  $baselineEvent = Get-WinEvent -LogName $logName -MaxEvents 1 -ErrorAction SilentlyContinue
  $baseline = [datetime]::MinValue
  if ($baselineEvent) { $baseline = $baselineEvent.TimeCreated }

  $null = & "$env:WINDIR\System32\usoclient.exe" StartScan

  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $newest = Get-WinEvent -LogName $logName -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($newest -and $newest.TimeCreated -gt $baseline) {
      return ('scan triggered; new WindowsUpdateClient event Id={0} TimeCreated={1} (usoclient StartScan)' -f $newest.Id, $newest.TimeCreated.ToString('o'))
    }
  }
  throw 'BLOCKED: scan trigger produced no WindowsUpdateClient event within 90s'
}

function Set-FleetAgentUpdateInstall {
  # Downloads and installs applicable non-firmware updates via the Microsoft
  # Update COM API. COM calls run inline under the executor timeout; the MU
  # service registration is removed again in finally whenever this function
  # added it.
  param($Entry, $Context)

  if (-not $Context.Elevated) { throw 'UNSUPPORTED: update.install requires elevation' }
  if (-not $Context.Settings.MaintenanceWindowActive) { throw 'BLOCKED: update.install requires an active maintenance window' }

  $muServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
  $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
  $addedService = $false
  $removeNote = ''
  $evidence = ''

  try {
    $registered = @($serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId })
    if ($registered.Count -eq 0) {
      $addedService = $true
      try { [void]$serviceManager.AddService2($muServiceId, 7, '') }
      catch { throw ('BLOCKED: Microsoft Update service registration failed: {0}' -f $_.Exception.Message) }
    }

    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2
    $searcher.ServiceID = $muServiceId
    $searcher.Online = $true
    $searchResult = $searcher.Search('IsInstalled=0 and IsHidden=0')
    $totalCount = @($searchResult.Updates).Count

    $candidates = @($searchResult.Updates | Where-Object {
      ($null -ne $_.InstallationBehavior) -and ($_.InstallationBehavior.RebootBehavior -le 1) -and ($_.Title -notmatch '(?i)firmware|bios')
    })

    if ($candidates.Count -eq 0) {
      $evidence = ('no applicable non-firmware update among {0} (mu-service-added={1})' -f $totalCount, $addedService)
    }
    else {
      $installColl = New-Object -ComObject Microsoft.Update.UpdateColl
      foreach ($update in $candidates) {
        if (-not $update.EulaAccepted) { [void]$update.AcceptEula() }
        [void]$installColl.Add($update)
      }

      $downloader = $session.CreateUpdateDownloader()
      $downloader.Updates = $installColl
      $downloadResult = $downloader.Download()
      $downloadCode = [int]$downloadResult.ResultCode

      $installer = $session.CreateUpdateInstaller()
      $installer.Updates = $installColl
      $installResult = $installer.Install()
      $installCode = [int]$installResult.ResultCode
      $firstUpdate = $installResult.GetUpdateResult(0)
      $rebootRequired = [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired

      $titles = @($candidates | ForEach-Object { $_.Title })
      $Context.JournalAdd.Publish('update-install', @{ Titles = $titles }, @{ ResultCode = $installCode })

      $facts = ('installed [{0}]; download ResultCode={1}; install ResultCode={2}; first-update ResultCode={3} HResult=0x{4:X8}; mu-service-added={5}' -f ($titles -join '; '), $downloadCode, $installCode, [int]$firstUpdate.ResultCode, ($firstUpdate.HResult -band 0xFFFFFFFF), $addedService)
      if ($rebootRequired) { $evidence = 'reboot-required: ' + $facts } else { $evidence = $facts }
    }
  }
  finally {
    if ($addedService) {
      try { [void]$serviceManager.RemoveService($muServiceId) }
      catch { $removeNote = (' (MU service deregistration failed: {0})' -f $_.Exception.Message) }
    }
  }

  return ($evidence + $removeNote)
}

function Get-FleetAgentUpdateInstallState {
  # Quick state probe: reboot flag from SystemInfo plus an offline pending count.
  param($Entry, $Context)

  $rebootRequired = [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
  $pendingCount = $null
  try {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $searcher.Online = $false
    $pendingCount = @($searcher.Search('IsInstalled=0 and IsHidden=0').Updates).Count
  }
  catch { $pendingCount = $null }
  return @{ RebootRequired = $rebootRequired; PendingCount = $pendingCount }
}

function Undo-FleetAgentUpdateInstall {
  # Updates are owned and rolled back by Windows; never uninstall from here.
  param($PreviousState, $Context)
  return 'Windows owns OS rollback; no reversal performed'
}
