# Cleanup: remove the Microsoft Update service registration that the
# finisher run added, and record the post-install Defender state.

#Requires -Version 5.1

$outDir = Join-Path $env:TEMP 'fleet-elevated'
$resultsPath = Join-Path $outDir 'cleanup-results.json'
$donePath = Join-Path $outDir 'cleanup-done.flag'

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param([string]$Check, [string]$Status, [string]$Evidence)
  $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Evidence = $Evidence })
  Write-Output ("[{0}] {1} :: {2}" -f $Status, $Check, $Evidence)
}

$muServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
$svc = $serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId } | Select-Object -First 1

if ($null -eq $svc) {
  Add-Result 'Microsoft Update service' 'PASS' 'not registered; nothing to remove'
}
else {
  $removed = $false
  $lastError = ''
  try { $serviceManager.RemoveService($svc.ServiceID); $removed = $true }
  catch { $lastError = $_.Exception.Message }
  if (-not $removed) {
    try { $serviceManager.RemoveService($svc); $removed = $true }
    catch { $lastError = $lastError + ' | ' + $_.Exception.Message }
  }
  if (-not $removed) {
    # The managed wrapper path: dispatch through the documented interface.
    try {
      [void]$svc.GetType().InvokeMember('ServiceID', 'GetProperty', $null, $svc, $null)
      $serviceManager.GetType().InvokeMember('RemoveService', 'InvokeMethod', $null, $serviceManager, @($svc.ServiceID))
      $removed = $true
    }
    catch { $lastError = $lastError + ' | ' + $_.Exception.Message }
  }
  $still = $serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId } | Select-Object -First 1
  if ($null -eq $still) {
    Add-Result 'Microsoft Update service' 'PASS' 'removed; machine state restored'
  }
  else {
    Add-Result 'Microsoft Update service' 'FAIL' ("still registered; errors: " + $lastError)
  }
}

try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  Add-Result 'Defender signature after install' 'PASS' ("version " + $mp.AntivirusSignatureVersion + ", age " + $mp.AntivirusSignatureAge + " day(s)")
}
catch { Add-Result 'Defender signature after install' 'FAIL' $_.Exception.Message }

$results | ConvertTo-Json | Set-Content $resultsPath -Encoding UTF8
Set-Content $donePath 'done' -Encoding ASCII
exit 0
