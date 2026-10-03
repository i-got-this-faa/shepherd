# Unit tier: pure logic, no machine mutation.

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\FleetTest\FleetTest.psm1') -Force
Initialize-FleetTestRun -Name 'unit'

# --- PReg codec -------------------------------------------------------
Invoke-FleetCheck -Surface 'PReg' -Check 'round-trips multiple records of all types' -Body {
  $records = @(
    @{ Key = 'SOFTWARE\Policies\Fleet'; ValueName = 'Sz'; Type = 1; Data = [System.Text.Encoding]::Unicode.GetBytes('hello') }
    @{ Key = 'SOFTWARE\Policies\Fleet'; ValueName = 'Dword'; Type = 4; Data = [byte[]]@(1, 0, 0, 0) }
    @{ Key = 'SOFTWARE\Policies\Fleet'; ValueName = '**del.Old'; Type = 4; Data = [byte[]]@(0, 0, 0, 0) }
    @{ Key = 'SOFTWARE\Policies\Fleet'; ValueName = 'Binary'; Type = 3; Data = [byte[]]@(0xDE, 0xAD, 0xBE, 0xEF) }
  )
  $bytes = ConvertTo-RegistryPolBytes -Records $records
  $parsed = ConvertFrom-RegistryPolBytes -Bytes $bytes
  if ($parsed.Truncated) { throw 'round-trip reported truncation' }
  if ($parsed.Records.Count -ne 4) { throw "expected 4 records, got $($parsed.Records.Count)" }
  if ($parsed.Records[0].ValueName -ne 'Sz') { throw 'record 0 mismatch' }
  if ($parsed.Records[2].ValueName -ne '**del.Old') { throw 'delete prefix not preserved' }
  if ($parsed.Records[3].Data[0] -ne 0xDE -or $parsed.Records[3].Data[3] -ne 0xEF) { throw 'binary data mismatch' }
  return '4 records round-tripped, **del. prefix preserved'
}

Invoke-FleetCheck -Surface 'PReg' -Check 'rejects a bad signature' -Body {
  try { ConvertFrom-RegistryPolBytes -Bytes ([byte[]]@(0, 0, 0, 0, 0, 0, 0, 0)) | Out-Null }
  catch { return "threw: $($_.Exception.Message)" }
  throw 'bad signature was accepted'
}

Invoke-FleetCheck -Surface 'PReg' -Check 'rejects an unsupported version' -Body {
  $bytes = [byte[]]@(0x50, 0x52, 0x65, 0x67, 9, 0, 0, 0)
  try { ConvertFrom-RegistryPolBytes -Bytes $bytes | Out-Null }
  catch { return "threw: $($_.Exception.Message)" }
  throw 'unsupported version was accepted'
}

Invoke-FleetCheck -Surface 'PReg' -Check 'flags a truncated trailing record' -Body {
  $good = ConvertTo-RegistryPolBytes -Records @(
    @{ Key = 'K'; ValueName = 'V'; Type = 4; Data = [byte[]]@(1, 0, 0, 0) }
  )
  $cut = New-Object byte[] ($good.Length - 3)
  [Array]::Copy($good, $cut, $cut.Length)
  $parsed = ConvertFrom-RegistryPolBytes -Bytes $cut
  if (-not $parsed.Truncated) { throw 'truncation not detected' }
  if ($parsed.Records.Count -ne 0) { throw 'partial record should not parse' }
  return 'truncation flagged, no partial record emitted'
}

# --- Plan schema validator --------------------------------------------
function New-ValidPlan {
  return @{
    planVersion = 1
    planId      = 'p-1'
    fleetId     = 'f-1'
    machineId   = 'm-1'
    mode        = 'apply'
    resources   = @(
      @{ resource = 'registry.value'; id = 'HKLM\SOFTWARE\FleetTest'; ensure = 'present'
         data = @{ valueName = 'Alpha'; type = 'REG_SZ'; data = 'one' } }
      @{ resource = 'script.fleet'; id = 'marker'
         data = @{ content = 'exit 0'; expectedExitCodes = @(0) }
         dependsOn = @('registry.value:HKLM\SOFTWARE\FleetTest') }
    )
  }
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'accepts a valid plan with dependsOn' -Body {
  $v = Test-FleetPlan -Plan (New-ValidPlan)
  if (-not $v.Valid) { throw ($v.Errors -join '; ') }
  return 'valid'
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'rejects a wrong planVersion' -Body {
  $p = New-ValidPlan; $p.planVersion = 2
  $v = Test-FleetPlan -Plan $p
  if ($v.Valid) { throw 'planVersion 2 accepted' }
  return ($v.Errors -join '; ')
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'forbids HKCU in registry resources' -Body {
  $p = New-ValidPlan
  $p.resources[0].id = 'HKCU\SOFTWARE\FleetTest'
  $v = Test-FleetPlan -Plan $p
  if ($v.Valid) { throw 'HKCU id accepted' }
  return ($v.Errors -join '; ')
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'rejects an unknown resource module' -Body {
  $p = New-ValidPlan
  $p.resources[0].resource = 'registry.magic'
  $v = Test-FleetPlan -Plan $p
  if ($v.Valid) { throw 'unknown resource accepted' }
  return ($v.Errors -join '; ')
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'rejects a bad ensure value' -Body {
  $p = New-ValidPlan
  $p.resources[0].ensure = 'maybe'
  $v = Test-FleetPlan -Plan $p
  if ($v.Valid) { throw 'bad ensure accepted' }
  return ($v.Errors -join '; ')
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'rejects an unresolved dependsOn reference' -Body {
  $p = New-ValidPlan
  $p.resources[1].dependsOn = @('registry.value:HKLM\SOFTWARE\DoesNotExist')
  $v = Test-FleetPlan -Plan $p
  if ($v.Valid) { throw 'unresolved dependency accepted' }
  return ($v.Errors -join '; ')
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'detects a dependsOn cycle' -Body {
  $p = New-ValidPlan
  $p.resources[0].dependsOn = @('marker')
  $v = Test-FleetPlan -Plan $p
  if ($v.Valid) { throw 'cycle accepted' }
  return ($v.Errors -join '; ')
}

Invoke-FleetCheck -Surface 'PlanSchema' -Check 'ignores unknown fields' -Body {
  $p = New-ValidPlan
  $p.someFutureField = 'x'
  $p.resources[0].note = 'hi'
  $v = Test-FleetPlan -Plan $p
  if (-not $v.Valid) { throw ($v.Errors -join '; ') }
  return 'unknown fields ignored per versioning rules'
}

# --- winget exit-code map ---------------------------------------------
Invoke-FleetCheck -Surface 'WingetExitCodes' -Check 'maps documented codes to the taxonomy' -Body {
  $cases = @(
    @{ Code = '0'; Expected = 'ok' }
    @{ Code = '0x00000000'; Expected = 'ok' }
    @{ Code = '0x8A15002B'; Expected = 'unchanged' }
    @{ Code = '0x8A15010D'; Expected = 'unchanged' }
    @{ Code = '0x8A150109'; Expected = 'reboot-required' }
    @{ Code = '0x8A150103'; Expected = 'blocked' }
    @{ Code = '0x8A150076'; Expected = 'blocked' }
    @{ Code = '0x8A150010'; Expected = 'unsupported' }
    @{ Code = '0x8A150014'; Expected = 'failed' }
  )
  foreach ($c in $cases) {
    $m = Convert-FleetWingetExitCode -Code $c.Code
    if ($m.Category -ne $c.Expected) { throw "$($c.Code) mapped to $($m.Category), expected $($c.Expected)" }
  }
  return "$($cases.Count) codes mapped correctly"
}

Invoke-FleetCheck -Surface 'WingetExitCodes' -Check 'maps unknown codes to failed' -Body {
  $m = Convert-FleetWingetExitCode -Code '0x8A15FFFF'
  if ($m.Category -ne 'failed') { throw "unknown code mapped to $($m.Category)" }
  return 'unknown code -> failed'
}

# --- Journal -----------------------------------------------------------
Invoke-FleetCheck -Surface 'Journal' -Check 'counts writes per plan and marks reversal' -Body {
  Initialize-FleetJournal
  $e1 = Add-FleetJournalEntry -PlanId 'p1' -ResourceId 'registry.value:K' -Operation 'set-value' -PreviousState $null -NewState @{ v = 1 }
  $e2 = Add-FleetJournalEntry -PlanId 'p1' -ResourceId 'script.fleet:x' -Operation 'run' -PreviousState $null -NewState $null
  $e3 = Add-FleetJournalEntry -PlanId 'p2' -ResourceId 'registry.value:K' -Operation 'set-value' -PreviousState $null -NewState @{ v = 2 }
  if ((Get-FleetJournalWriteCount -PlanId 'p1') -ne 2) { throw 'p1 write count wrong' }
  if ((Get-FleetJournalWriteCount -PlanId 'p2') -ne 1) { throw 'p2 write count wrong' }
  $e1.Reversed = $true
  $stillActive = @(Get-FleetJournal | Where-Object { -not $_.Reversed }).Count
  if ($stillActive -ne 2) { throw 'reversal flag not tracked' }
  return 'write counting and reversal flags verified'
}

$outDir = Join-Path $env:TEMP 'fleet-tests'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
exit (Complete-FleetTestRun -OutFile (Join-Path $outDir 'unit-results.json'))
