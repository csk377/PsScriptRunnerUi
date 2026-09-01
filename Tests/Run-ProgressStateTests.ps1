[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PsScriptRunnerUi.psd1') -Force

# Exercise private state transitions with explicit batches; no WPF dispatcher or sleeps.
& (Get-Module PsScriptRunnerUi) {
    function Assert-True {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { throw $Message }
    }
    function New-TestRecord {
        param([int]$Id, [string]$Activity, [int]$Parent = -1, [int]$Percent = 0, [switch]$Completed)
        $record = [System.Management.Automation.ProgressRecord]::new($Id, $Activity, "$Activity status")
        $record.ParentActivityId = $Parent
        $record.PercentComplete = $Percent
        if ($Completed) { $record.RecordType = 'Completed' }
        return $record
    }

    $state = @{ Progress = @{}; ProgressRecordsRead = 0L; Result = $null }
    Update-ScriptProgressState $state @()
    $empty = Get-ScriptProgressSelection $state
    Assert-True ($null -eq $empty.Parent -and $null -eq $empty.Child) 'Empty progress must not select any activities.'

    Update-ScriptProgressState $state @(
        (New-TestRecord 1 'Old parent' -Percent 10)
        (New-TestRecord 2 'Older child' -Parent 1 -Percent 50)
        (New-TestRecord 10 'Other parent' -Percent 30)
        (New-TestRecord 11 'Other child' -Parent 10 -Percent 60)
        (New-TestRecord 1 'Latest parent' -Percent 75)
        (New-TestRecord 3 'Latest child' -Parent 1 -Percent 20)
    )
    $selection = Get-ScriptProgressSelection $state
    Assert-True ($selection.Parent.Activity -eq 'Latest parent' -and $selection.Parent.PercentComplete -eq 75) 'The latest root update was not selected.'
    Assert-True ($null -ne $selection.Child -and $selection.Child.Activity -eq 'Latest child' -and $selection.Child.PercentComplete -eq 20) 'The latest direct child was not selected.'
    Assert-True ($state.ProgressRecordsRead -eq 6 -and $state.Progress.Count -eq 5) 'Coalescing must count every record but retain only the latest per ID.'

    Update-ScriptProgressState $state @((New-TestRecord 3 'Latest child' -Parent 1 -Completed))
    Assert-True ((Get-ScriptProgressSelection $state).Child.Activity -eq 'Older child') 'Completing a child must reveal the previous active child.'
    Update-ScriptProgressState $state @((New-TestRecord 2 'Older child' -Parent 1 -Completed))
    Assert-True ($null -eq (Get-ScriptProgressSelection $state).Child) 'Completed children must be hidden.'
    Update-ScriptProgressState $state @((New-TestRecord 1 'Latest parent' -Completed))
    Assert-True ((Get-ScriptProgressSelection $state).Parent.Activity -eq 'Other parent') 'Completing a root must reveal the previous active root.'
    Update-ScriptProgressState $state @(
        (New-TestRecord 11 'Other child' -Parent 10 -Completed)
        (New-TestRecord 10 'Other parent' -Completed)
    )
    Assert-True ($state.Progress.Count -eq 0 -and $state.ProgressRecordsRead -eq 11) 'Completion must empty the active set and still count every record.'

    # Parent completion does not remove its children.
    Update-ScriptProgressState $state @(
        (New-TestRecord 1 'First parent')
        (New-TestRecord 2 'Surviving child' -Parent 1)
    )
    Update-ScriptProgressState $state @((New-TestRecord 1 'First parent' -Completed))
    Assert-True ((Get-ScriptProgressSelection $state).Parent.Activity -eq 'Surviving child') 'An orphan remains eligible for the overall display.'
    Update-ScriptProgressState $state @(
        (New-TestRecord 1 'Intermediate parent')
        (New-TestRecord 1 'Intermediate parent' -Completed)
        (New-TestRecord 1 'Reused parent' -Percent -1)
    )
    $reused = Get-ScriptProgressSelection $state
    Assert-True ($reused.Parent.Activity -eq 'Reused parent' -and $reused.Parent.PercentComplete -eq -1) 'Completion and reuse within one batch must retain the new activity.'
    Assert-True ($null -ne $reused.Child -and $reused.Child.Activity -eq 'Surviving child') 'Reusing a parent ID must associate its surviving child with the new parent.'

    $pipeline = [powershell]::Create()
    try {
        $state = @{
            Progress = @{}; ProgressRecordsRead = 0L; Result = $null
            ErrorRecords = [System.Collections.Generic.List[System.Management.Automation.ErrorRecord]]::new()
            Output       = New-ScriptOutputState
        }
        $failure = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('first'),
            'First', [System.Management.Automation.ErrorCategory]::InvalidData, 'item-1')
        $pipeline.Streams.Error.Add($failure)
        Assert-True (-not (Receive-ScriptProgress $pipeline $state $false)) 'An error-only poll must not refresh progress.'
        Assert-True ($pipeline.Streams.Error.Count -eq 0 -and $state.ErrorRecords.Count -eq 1 -and
            [object]::ReferenceEquals($state.ErrorRecords[0], $failure)) 'Draining errors must retain the full original record.'
        $pipeline.Streams.Error.Add($failure)
        [void] (Receive-ScriptProgress $pipeline $state $false)
        [void] (Receive-ScriptProgress $pipeline $state $false)
        Assert-True ($state.ErrorRecords.Count -eq 2) 'Repeated emissions must be retained, but empty polls must not duplicate errors.'
        $pipeline.Streams.Information.Add([System.Management.Automation.InformationRecord]::new('discarded message', 'test'))
        Assert-True (-not (Receive-ScriptProgress $pipeline $state $false)) 'An information-only poll must not request a display refresh.'
        Assert-True ($pipeline.Streams.Information.Count -eq 0) 'An idle poll must still discard information when capture is disabled.'
        $pipeline.Streams.Information.Add([System.Management.Automation.InformationRecord]::new('forwarded message', 'test'))
        $received = @(Receive-ScriptProgress $pipeline $state $true 6>&1)
        Assert-True ($received.Count -eq 2 -and $received[0].MessageData.ToString() -eq 'forwarded message' -and $received[1] -eq $false) 'An idle poll must forward information without requesting a display refresh.'
        $pipeline.Streams.Progress.Add((New-TestRecord 1 'Drained activity'))
        Assert-True (Receive-ScriptProgress $pipeline $state $false) 'A progress batch must request a display refresh.'
        Assert-True ($pipeline.Streams.Progress.Count -eq 0 -and $state.ProgressRecordsRead -eq 1) 'The progress stream was not drained exactly once.'
        Assert-True (-not (Receive-ScriptProgress $pipeline $state $false)) 'The next empty poll must not request another refresh.'
        Assert-True ($state.ProgressRecordsRead -eq 1) 'An empty poll must not change the record count.'
    }
    finally { $pipeline.Dispose(); $state.Output.Buffer.Dispose() }
}

Write-Output 'Progress state, selection, and stream-drain checks passed.'
