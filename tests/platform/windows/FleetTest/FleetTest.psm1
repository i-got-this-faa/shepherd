# FleetTest module: test results framework plus thin wrappers that route
# the test tiers onto the real FleetAgent module. The reference executor
# WAS the agent skeleton; the agent module is now the implementation and
# the suite runs against it unchanged.

#Requires -Version 5.1

$agentModule = Join-Path $PSScriptRoot '..\..\..\..\apps\node-daemon\reference\powershell\FleetAgent.psm1'
if (Test-Path $agentModule) { Import-Module $agentModule -Global -Force }

# =====================================================================
# Results framework
# =====================================================================
$script:FleetResults = New-Object System.Collections.Generic.List[object]
$script:FleetRunName = ''

function Initialize-FleetTestRun {
  param([Parameter(Mandatory)][string]$Name)
  $script:FleetResults = New-Object System.Collections.Generic.List[object]
  $script:FleetRunName = $Name
}

function Add-FleetResult {
  param([string]$Surface, [string]$Check,
    [ValidateSet('PASS', 'FAIL', 'PENDING', 'UNSUPPORTED')][string]$Status,
    [string]$Evidence)
  $script:FleetResults.Add([pscustomobject]@{
      Run      = $script:FleetRunName
      Surface  = $Surface
      Check    = $Check
      Status   = $Status
      Evidence = $Evidence
    })
}

function Invoke-FleetCheck {
  param([string]$Surface, [string]$Check, [Parameter(Mandatory)][scriptblock]$Body)
  try {
    $evidence = & $Body
    if ($evidence -is [string] -and $evidence.StartsWith('UNSUPPORTED:')) {
      Add-FleetResult -Surface $Surface -Check $Check -Status 'UNSUPPORTED' -Evidence $evidence.Substring(12)
      return
    }
    if ($evidence) {
      Add-FleetResult -Surface $Surface -Check $Check -Status 'PASS' -Evidence ([string]$evidence)
    }
    else {
      Add-FleetResult -Surface $Surface -Check $Check -Status 'FAIL' -Evidence 'check returned no evidence'
    }
  }
  catch {
    Add-FleetResult -Surface $Surface -Check $Check -Status 'FAIL' -Evidence $_.Exception.Message
  }
}

function Complete-FleetTestRun {
  # Prints on the host stream (never captured, even from `exit (...)`),
  # writes results JSON, and returns 0/1. UNSUPPORTED is verified
  # documented behavior, not a failure.
  param([string]$OutFile)
  $failed = @($script:FleetResults | Where-Object Status -eq 'FAIL').Count
  $passed = @($script:FleetResults | Where-Object Status -eq 'PASS').Count
  $pending = @($script:FleetResults | Where-Object Status -eq 'PENDING').Count
  $unsupported = @($script:FleetResults | Where-Object Status -eq 'UNSUPPORTED').Count

  $script:FleetResults | Format-Table Run, Surface, Check, Status, Evidence -AutoSize -Wrap | Out-Host
  Write-Host "Result [$script:FleetRunName]: $passed passed, $failed failed, $pending pending, $unsupported unsupported."

  if ($OutFile) {
    $script:FleetResults | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding UTF8
  }
  if ($failed -gt 0) { return 1 }
  return 0
}

# =====================================================================
# Environment helpers
# =====================================================================
function Test-FleetElevated { return Test-FleetAgentElevated }
function Get-FleetCurrentUserSid { return Get-FleetAgentCurrentUserSid }
function Get-FleetEdition {
  $caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
  if ($caption -match '(?i)home') { return 'Home' }
  if ($caption -match '(?i)server') { return 'Server' }
  return 'ProOrHigher'
}
function Get-FleetAgentEdition { return Get-FleetEdition }

function Invoke-TimeboxedFleet {
  param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSec = 300)
  return Invoke-FleetAgentTimeboxed -FileName $FileName -Arguments $Arguments -TimeoutSec $TimeoutSec
}

# =====================================================================
# Wrappers over the agent module (keeps tier files stable)
# =====================================================================
function Initialize-FleetJournal { Initialize-FleetAgentJournal }
function Add-FleetJournalEntry { param([string]$PlanId, [string]$ResourceId, [string]$Operation, $PreviousState, $NewState)
  Add-FleetAgentJournalEntry @PSBoundParameters }
function Get-FleetJournal { return Get-FleetAgentJournal }
function Get-FleetJournalWriteCount { param([string]$PlanId) return Get-FleetAgentJournalWriteCount -PlanId $PlanId }
function Test-FleetPlan { param($Plan) return Test-FleetAgentPlan -Plan $Plan }
function Invoke-FleetPlan { param($Plan) return Invoke-FleetAgentPlan -Plan $Plan }
function Undo-FleetPlan { param([string]$PlanId) return Undo-FleetAgentPlan -PlanId $PlanId }
function ConvertTo-RegistryPolBytes { param($Records) return ConvertTo-FleetAgentRegistryPolBytes -Records $Records }
function ConvertFrom-RegistryPolBytes { param($Bytes) return ConvertFrom-FleetAgentRegistryPolBytes -Bytes $Bytes }
function Convert-FleetWingetExitCode { param([string]$Code) return Convert-FleetAgentWingetExitCode -Code $Code }

Export-ModuleMember -Function @(
  'Initialize-FleetTestRun', 'Add-FleetResult', 'Invoke-FleetCheck', 'Complete-FleetTestRun',
  'Test-FleetElevated', 'Get-FleetCurrentUserSid', 'Get-FleetEdition', 'Get-FleetAgentEdition',
  'ConvertTo-RegistryPolBytes', 'ConvertFrom-RegistryPolBytes', 'Convert-FleetWingetExitCode',
  'Initialize-FleetJournal', 'Add-FleetJournalEntry', 'Get-FleetJournal', 'Get-FleetJournalWriteCount',
  'Test-FleetPlan', 'Invoke-FleetPlan', 'Undo-FleetPlan', 'Invoke-TimeboxedFleet'
)
