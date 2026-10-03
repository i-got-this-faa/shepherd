# Scheduled task and script providers. Task ids are '<TaskPath><TaskName>'
# (root path '\' only in v1). script.fleet is non-convergent: audit never
# runs it, every apply runs it and reports 'applied'.

function Get-FleetAgentTaskState {
  param($Entry, $Context)
  $taskPath = if ($Entry.data.path) { $Entry.data.path } else { '\' }
  $taskName = $Entry.data.name
  $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
  if (-not $task) { return @{ Exists = $false } }
  $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
  return @{ Exists = $true; State = [string]$task.State; LastTaskResult = $info.LastTaskResult }
}

function Set-FleetAgentScheduledTask {
  param($Entry, $Context)
  $taskPath = if ($Entry.data.path) { $Entry.data.path } else { '\' }
  $taskName = $Entry.data.name
  if ($taskPath -ne '\') { throw 'UNSUPPORTED: only the root task path is supported by this agent version' }

  if ($Entry.ensure -eq 'absent') {
    $existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if (-not $existing) { return 'unchanged: task already absent' }
    if ($Context.Mode -eq 'audit') { return 'drifted: task exists but plan says absent' }
    $Context.JournalAdd.Publish('task-delete', @{ Existed = $true; TaskPath = $taskPath; TaskName = $taskName }, $null)
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
    return 'task removed'
  }

  $action = New-ScheduledTaskAction -Execute $Entry.data.action.execute -Argument $Entry.data.action.arguments
  $triggerAt = $Entry.data.trigger.onceAt
  if ($triggerAt -eq 'now+1h' -or -not $triggerAt) { $triggerAt = (Get-Date).AddHours(1) }
  $trigger = New-ScheduledTaskTrigger -Once -At $triggerAt
  $runLevel = if ($Entry.data.runLevel) { $Entry.data.runLevel } else { 'limited' }
  $runLevelFlag = if ($runLevel -eq 'highest') { 'Highest' } else { 'Limited' }

  $existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
  if ($existing) {
    $existingAction = "$($existing.Actions.Execute) $($existing.Actions.Arguments)"
    $desiredAction = "$($Entry.data.action.execute) $($Entry.data.action.arguments)"
    if ($existingAction -eq $desiredAction) { return 'unchanged: task already present with matching action' }
    if ($Context.Mode -eq 'audit') { return 'drifted: task action differs from plan' }
    $Context.JournalAdd.Publish('task-update', @{ Existed = $true; TaskPath = $taskPath; TaskName = $taskName; Action = $existingAction }, @{ Action = $desiredAction })
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -RunLevel $runLevelFlag -ErrorAction Stop | Out-Null
    return 'task action updated'
  }

  if ($Context.Mode -eq 'audit') { return 'drifted: task missing but plan says present' }
  $Context.JournalAdd.Publish('task-create', @{ Existed = $false; TaskPath = $taskPath; TaskName = $taskName }, @{ Action = $desiredAction })
  Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -RunLevel $runLevelFlag -ErrorAction Stop | Out-Null
  return 'task registered'
}

function Undo-FleetAgentScheduledTask {
  param($JournalEntry)
  $PreviousState = $JournalEntry.PreviousState
  if ($PreviousState.Existed) { return }
  Unregister-ScheduledTask -TaskName $PreviousState.TaskName -TaskPath $PreviousState.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-FleetAgentScriptState {
  param($Entry, $Context)
  return @{ NonConvergent = $true }
}

function Set-FleetAgentScript {
  param($Entry, $Context)
  if ($Context.Mode -eq 'audit') {
    return 'script.fleet is non-convergent; audit performs no run'
  }
  $content = $Entry.data.content
  $expected = @($Entry.data.expectedExitCodes) | Where-Object { $null -ne $_ }
  if ($expected.Count -eq 0) { $expected = @(0) }
  $tmp = Join-Path $env:TEMP ('fleet-agent-script-' + [guid]::NewGuid().ToString('N') + '.ps1')
  Set-Content -Path $tmp -Value $content -Encoding UTF8
  try {
    $timeout = 120
    if ($Entry.timeoutSec) { $timeout = $Entry.timeoutSec }
    $out = Invoke-FleetAgentTimeboxed -FileName 'powershell.exe' `
      -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp) `
      -TimeoutSec $timeout
    if ($out.TimedOut) { throw "BLOCKED: script timed out after ${timeout}s" }
    if ($out.ExitCode -in $expected) {
      $lastLine = ($out.Output.Trim() -split "`n" | Select-Object -Last 1)
      $Context.JournalAdd.Publish('script-run', $null, @{ ExitCode = $out.ExitCode; OutputTail = $lastLine })
      return "exit $($out.ExitCode); $lastLine"
    }
    throw "exit $($out.ExitCode) not in expected [$($expected -join ',')]: $($out.Output)"
  }
  finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Undo-FleetAgentScript {
  param($JournalEntry)
  return
}

