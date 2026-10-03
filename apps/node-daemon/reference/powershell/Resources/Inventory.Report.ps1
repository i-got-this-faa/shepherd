# Inventory provider: builds the normalized fleet inventory document.
# Software inventory of record is the registry uninstall keys; Win32_Product
# is never queried (MSI reconfiguration side effect); wmic is never used
# (removed from Windows). Elevation-gated sections degrade gracefully.

function Get-FleetAgentInventoryState {
  param($Entry, $Context)
  $inv = @{}
  $inv['ComputerName'] = $env:COMPUTERNAME
  $inv['UserSid'] = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $inv['CollectedAt'] = (Get-Date).ToString('o')

  # OS fingerprint: build + UBR, never ProductName (it still says
  # 'Windows 10 ...' on Windows 11) and never Version (10.0 on both).
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $ubr = $cv.UBR
    $inv['Os'] = @{
      Caption    = $os.Caption
      Version    = "$($os.Version).$($os.BuildNumber).$($ubr)"
      Build      = [int]$os.BuildNumber
      IsWin11    = ([int]$os.BuildNumber -ge 22000)
      DisplayVersion = $cv.DisplayVersion
      EditionID  = $cv.EditionID
      LastBoot   = $os.LastBootUpTime
    }
  }
  catch { $inv['Os'] = @{ Error = $_.Exception.Message } }

  try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $mem = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object Capacity -Sum).Sum
    $inv['Hardware'] = @{
      Manufacturer = $cs.Manufacturer
      Model        = $cs.Model
      LogicalProcessors = $cs.NumberOfLogicalProcessors
      Cpu          = $cpu.Name
      Cores        = $cpu.NumberOfCores
      MemoryBytes  = $mem
      BiosSerial   = $bios.SerialNumber
      BiosVersion  = $bios.SMBIOSBIOSVersion
    }
  }
  catch { $inv['Hardware'] = @{ Error = $_.Exception.Message } }

  try {
    $inv['Disks'] = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
      ForEach-Object { @{ DeviceID = $_.DeviceID; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1); Volume = $_.VolumeName } })
  }
  catch { $inv['Disks'] = @() }

  try {
    $inv['NetworkAdapters'] = @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -ErrorAction Stop |
      ForEach-Object { @{ Name = $_.Name; Description = $_.InterfaceDescription; MacAddress = $_.MacAddress } })
  }
  catch { $inv['NetworkAdapters'] = @() }

  # Software inventory of record: the uninstall databases (both views plus
  # per-user), not WMI.
  try {
    $software = @()
    foreach ($view in @(
        @{ Root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Source = '64' },
        @{ Root = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Source = '32' },
        @{ Root = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Source = 'user' })) {
      if (-not (Test-Path $view.Root)) { continue }
      foreach ($k in (Get-ChildItem $view.Root -ErrorAction SilentlyContinue)) {
        $name = $k.GetValue('DisplayName')
        if (-not $name) { continue }
        $software += @{ Name = $name; Version = $k.GetValue('DisplayVersion'); Publisher = $k.GetValue('Publisher'); Source = $view.Source }
      }
    }
    $inv['Software'] = $software
  }
  catch { $inv['Software'] = @() }

  try {
    $hotfixes = @(Get-HotFix -ErrorAction Stop)
    $latest = $hotfixes | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $inv['Hotfixes'] = @{ Count = $hotfixes.Count; Latest = $latest.HotFixID }
  }
  catch { $inv['Hotfixes'] = @{ Count = 0 } }

  try {
    $mp = Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpComputerStatus' -ErrorAction Stop
    $inv['Defender'] = @{ AMServiceEnabled = [bool]$mp.AMServiceEnabled; AntivirusEnabled = [bool]$mp.AntivirusEnabled; RealTimeProtectionEnabled = [bool]$mp.RealTimeProtectionEnabled; SignatureVersion = $mp.AntivirusSignatureVersion }
  }
  catch { $inv['Defender'] = $null }

  if ($Context.Elevated) {
    try {
      $tpm = Get-Tpm -ErrorAction Stop
      $inv['Tpm'] = @{ Present = [bool]$tpm.TpmPresent; Ready = [bool]$tpm.TpmReady }
    }
    catch { $inv['Tpm'] = $null }
    try {
      $inv['SecureBoot'] = Confirm-SecureBootUEFI -ErrorAction Stop
    }
    catch { $inv['SecureBoot'] = $null }
    try {
      $inv['BitLocker'] = @(Get-BitLockerVolume -ErrorAction Stop | ForEach-Object { @{ MountPoint = $_.MountPoint; ProtectionStatus = [string]$_.ProtectionStatus } })
    }
    catch { $inv['BitLocker'] = $null }
  }
  else {
    $inv['Tpm'] = $null
    $inv['SecureBoot'] = $null
    $inv['BitLocker'] = $null
    $inv['ElevationNote'] = 'TPM, SecureBoot, and BitLocker sections require elevation'
  }

  return $inv
}

function Set-FleetAgentInventoryReport {
  param($Entry, $Context)
  $inv = Get-FleetAgentInventoryState -Entry $Entry -Context $Context
  $Context.JournalAdd.Publish('inventory-report', $null, $inv)
  $softwareCount = @($inv.Software).Count
  return "unchanged: $($inv.Os.Caption) build $($inv.Os.Build).$($inv.Os.DisplayVersion); $softwareCount software entries"
}

function Undo-FleetAgentInventoryReport {
  param($JournalEntry)
  return
}
