Set-StrictMode -Version 2.0

function Test-ScriptCancellationRequested {
    [CmdletBinding()]
    param()

    $context = Get-Variable -Name '__UiScriptContext' -Scope Global -ErrorAction SilentlyContinue
    return ($null -ne $context -and $context.Value.Cancellation.IsCancellationRequested)
}

function Assert-ScriptNotCancelled {
    [CmdletBinding()]
    param()

    if (Test-ScriptCancellationRequested) {
        throw [System.OperationCanceledException]::new('The script observed a cancellation request.')
    }
}

function Update-ProgressControls {
    param($ProgressControls, $Record)

    $ProgressControls.Activity.Text = $Record.Activity
    $ProgressControls.Status.Text = $Record.StatusDescription
    $ProgressControls.Bar.IsIndeterminate = $Record.PercentComplete -lt 0 -or $Record.PercentComplete -gt 100
    if (-not $ProgressControls.Bar.IsIndeterminate) { $ProgressControls.Bar.Value = $Record.PercentComplete }
}

function Show-ScriptOutcome {
    param($Controls, [string] $Status, [string] $Message)

    $Controls.CancelButton.Visibility = 'Collapsed'
    $Controls.CloseButton.Visibility = 'Visible'
    $Controls.CloseButton.IsEnabled = $true
    $Controls.ChildPanel.Visibility = 'Collapsed'
    $Controls.Parent.Bar.IsIndeterminate = $false
    $Controls.Parent.Bar.Value = 100
    $Controls.Parent.Activity.Text = $Status
    $Controls.Parent.Status.Text = $Message
    $colors = switch ($Status) {
        'Completed' { @('#EDF8EE', '#B7DABC', '#245D32') }
        { $_ -in @('Cancelled', 'CompletedWithErrors') } {
            $Controls.Parent.Bar.Foreground = '#D1A522'
            @('#FFF8DB', '#E5CE80', '#705A16')
        }
        'Failed' {
            $Controls.Parent.Bar.Foreground = '#C34444'
            @('#FDECEC', '#E7BABA', '#702828')
        }
    }
    $Controls.Parent.Panel.Background = $colors[0]
    $Controls.Parent.Panel.BorderBrush = $colors[1]
    $Controls.Parent.Activity.Foreground = $colors[2]
    $Controls.Parent.Status.Foreground = $colors[2]
}

function New-ScriptOutcome {
    param($Pipeline, $Context, $EndError, $ErrorRecords, [timespan] $Duration, [long] $ProgressRecordsRead)

    # Terminating errors can be reported only by EndInvoke, not by the error stream.
    # Prefer the original record over the method-call wrapper created by EndInvoke.
    $terminatingError = $null
    if ($null -ne $EndError -or $Pipeline.InvocationStateInfo.State -eq 'Failed') {
        $reason = $Pipeline.InvocationStateInfo.Reason
        if ($reason -is [System.Management.Automation.IContainsErrorRecord]) {
            $terminatingError = $reason.ErrorRecord
        }
        elseif ($null -ne $reason) {
            $terminatingError = [System.Management.Automation.ErrorRecord]::new(
                $reason, 'ScriptTerminatingError', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        }
        else { $terminatingError = $EndError }

        # Do not duplicate a terminal record already delivered by the stream.
        $alreadyRecorded = $false
        foreach ($record in $ErrorRecords) {
            if ([object]::ReferenceEquals($record, $terminatingError) -or
                [object]::ReferenceEquals($record.Exception, $terminatingError.Exception)) {
                $alreadyRecorded = $true
                break
            }
        }
        if (-not $alreadyRecorded) { $ErrorRecords.Add($terminatingError) }
    }

    $errorRecord = if ($null -ne $terminatingError) { $terminatingError }
        elseif ($ErrorRecords.Count -gt 0) { $ErrorRecords[0] } else { $null }
    $status = if ($null -ne $terminatingError) { 'Failed' }
        elseif ($Context.Cancelled -and $ErrorRecords.Count -gt 0) { 'Failed' }
        elseif ($Context.Cancelled) { 'Cancelled' }
        elseif ($ErrorRecords.Count -gt 0) { 'CompletedWithErrors' }
        else { 'Completed' }
    $cancellationWasRequested = $Context.Cancellation.IsCancellationRequested
    $message = switch ($status) {
        'Completed' {
            if ($cancellationWasRequested) { 'Completed normally after a cancellation request.' }
            else { 'Completed successfully.' }
        }
        'Cancelled' { 'Cancelled after script cleanup completed.' }
        'CompletedWithErrors' {
            $summary = 'Completed with {0} error(s).' -f $ErrorRecords.Count
            if ($cancellationWasRequested) { $summary += ' Cancellation was requested, but the script completed normally.' }
            $summary
        }
        'Failed' {
            $exception = $errorRecord.Exception
            if ($null -ne $errorRecord.ErrorDetails -and
                -not [string]::IsNullOrWhiteSpace($errorRecord.ErrorDetails.Message)) {
                $errorRecord.ErrorDetails.Message
            } else { $exception.Message }
        }
    }

    [pscustomobject]@{
        Result = [pscustomobject]@{
            Status = $status
            Duration = $Duration
            CancellationWasRequested = $cancellationWasRequested
            ErrorRecord = $errorRecord
            ErrorRecords = $ErrorRecords.ToArray()
            ErrorCount = $ErrorRecords.Count
            ProgressRecordsRead = $ProgressRecordsRead
        }
        Message = $message
    }
}

function Update-ScriptProgressState {
    param($State, $Batch)

    # Visit newest records first: retain only the last update for each activity.
    $seen = @{}
    for ($i = $Batch.Count - 1; $i -ge 0; $i--) {
        $record = $Batch[$i]
        if ($seen.ContainsKey($record.ActivityId)) { continue }
        $seen[$record.ActivityId] = $true
        if ($record.RecordType -eq 'Completed') {
            $State.Progress.Remove($record.ActivityId)
        }
        else {
            $State.Progress[$record.ActivityId] = @{
                Record = $record
                Sequence = $State.ProgressRecordsRead + $i
            }
        }
    }
    $State.ProgressRecordsRead += $Batch.Count
}

function New-ScriptOutputState {
    param([string] $OutputLevel = 'None', [bool] $ShowOutput = $false)

    @{
        Level = (@{ None = 0; Error = 1; Warn = 2; Info = 3; Verbose = 4; Debug = 5 })[$OutputLevel]
        ShowOutput = $ShowOutput
        Buffer = [System.Management.Automation.PSDataCollection[psobject]]::new()
        Text = [System.Text.StringBuilder]::new()
        MaxCharacters = 65536
        Truncated = $false
        Changed = $false
    }
}

function Add-ScriptOutput {
    param($OutputState, [string] $Stream, $Record)

    # Only called for visible records. Formatting must not turn script data into a UI fault.
    try {
        $message = switch ($Stream) {
            'Output' {
                if ($Record -is [string]) { $Record }
                else { ($Record | Out-String -Width 160 -ErrorAction Stop).TrimEnd() }
            }
            'Info' { [string] $Record.MessageData }
            'Error' {
                if ($null -ne $Record.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($Record.ErrorDetails.Message)) {
                    $Record.ErrorDetails.Message
                }
                else { $Record.Exception.Message }
            }
            default { $Record.Message }
        }
    }
    catch { $message = '<Unable to format this record.>' }

    $line = '[{0}] {1}{2}' -f $Stream, $message, [Environment]::NewLine
    if ($line.Length -gt $OutputState.MaxCharacters) {
        $line = $line.Substring($line.Length - $OutputState.MaxCharacters)
        $OutputState.Truncated = $true
    }
    $excess = $OutputState.Text.Length + $line.Length - $OutputState.MaxCharacters
    if ($excess -gt 0) {
        [void] $OutputState.Text.Remove(0, $excess)
        $OutputState.Truncated = $true
    }
    [void] $OutputState.Text.Append($line)
    $OutputState.Changed = $true
}

function Receive-ScriptOutputStreams {
    param($Pipeline, $State, [bool] $CaptureHostOutput)

    foreach ($record in $Pipeline.Streams.Error.ReadAll()) {
        $State.ErrorRecords.Add($record)
        if ($State.Output.Level -ge 1) { Add-ScriptOutput $State.Output 'Error' $record }
    }
    if ($State.Output.Level -ge 3 -or $CaptureHostOutput) {
        foreach ($record in $Pipeline.Streams.Information.ReadAll()) {
            if ($State.Output.Level -ge 3) { Add-ScriptOutput $State.Output 'Info' $record }
            if ($CaptureHostOutput) { Write-Host ([string] $record.MessageData) }
        }
    }
    else { $Pipeline.Streams.Information.Clear() }

    foreach ($stream in @(
        @{ Buffer = $Pipeline.Streams.Warning; Level = 2; Label = 'Warn' }
        @{ Buffer = $Pipeline.Streams.Verbose; Level = 4; Label = 'Verbose' }
        @{ Buffer = $Pipeline.Streams.Debug; Level = 5; Label = 'Debug' }
    )) {
        if ($State.Output.Level -ge $stream.Level) {
            foreach ($record in $stream.Buffer.ReadAll()) { Add-ScriptOutput $State.Output $stream.Label $record }
        }
        else { $stream.Buffer.Clear() }
    }
    if ($State.Output.ShowOutput) {
        foreach ($record in $State.Output.Buffer.ReadAll()) { Add-ScriptOutput $State.Output 'Output' $record }
    }
    else { $State.Output.Buffer.Clear() }
}

function Receive-ScriptProgress {
    param($Pipeline, $State, [bool] $CaptureHostOutput)

    $batch = $Pipeline.Streams.Progress.ReadAll()
    if ($batch.Count -gt 0) { Update-ScriptProgressState $State $batch }
    Receive-ScriptOutputStreams $Pipeline $State $CaptureHostOutput
    return ($batch.Count -gt 0)
}

function Update-ScriptOutputDisplay {
    param($OutputState, $Controls)

    if (-not $OutputState.Changed) { return }
    $followTail = $Controls.OutputText.VerticalOffset -ge $Controls.OutputText.ExtentHeight - $Controls.OutputText.ViewportHeight - 1
    $offset = $Controls.OutputText.VerticalOffset
    $Controls.OutputText.Text = $OutputState.Text.ToString()
    if ($followTail) { $Controls.OutputText.ScrollToEnd() }
    else { $Controls.OutputText.ScrollToVerticalOffset($offset) }
    if ($OutputState.Truncated) { $Controls.OutputTruncation.Visibility = 'Visible' }
    $OutputState.Changed = $false
}

function Get-ScriptProgressSelection {
    param($State)

    $records = @($State.Progress.Values | Sort-Object { $_.Sequence } -Descending)
    $parent = $records | Where-Object { $_.Record.ParentActivityId -lt 0 } | Select-Object -First 1
    if ($null -eq $parent -and $records.Count -gt 0) { $parent = $records[0] }
    $child = $records | Where-Object { $null -ne $parent -and $_.Record.ParentActivityId -eq $parent.Record.ActivityId } | Select-Object -First 1
    [pscustomobject]@{
        Parent = if ($null -ne $parent) { $parent.Record } else { $null }
        Child = if ($null -ne $child) { $child.Record } else { $null }
    }
}

function Update-ScriptProgressDisplay {
    param($State, $Controls)

    $selection = Get-ScriptProgressSelection $State
    $Controls.ChildPanel.Visibility = 'Collapsed'
    if ($null -eq $selection.Parent) {
        $Controls.Parent.Activity.Text = 'Waiting for progress'
        $Controls.Parent.Status.Text = 'No active progress records.'
        $Controls.Parent.Bar.IsIndeterminate = $true
        return
    }

    Update-ProgressControls $Controls.Parent $selection.Parent
    if ($null -ne $selection.Child) {
        $Controls.ChildPanel.Visibility = 'Visible'
        Update-ProgressControls $Controls.Child $selection.Child
    }
}

function Invoke-UiScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [hashtable] $Parameters = @{},
        [string] $WorkingDirectory,
        $Owner,
        [switch] $CaptureHostOutput,
        [switch] $CloseOnSuccess,
        [string] $HeadingText = 'Run script',
        [ValidateSet('None', 'Error', 'Warn', 'Info', 'Verbose', 'Debug')]
        [string] $OutputLevel = 'None',
        [switch] $ShowOutput
    )

    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Invoke-UiScript requires an STA UI thread. Start Windows PowerShell with -STA.'
    }
    $scriptFile = Get-Item -LiteralPath $FilePath -ErrorAction Stop
    if ($scriptFile.PSProvider.Name -ne 'FileSystem' -or $scriptFile.PSIsContainer -or $scriptFile.Extension -ne '.ps1') {
        throw 'FilePath must name an existing PowerShell script (.ps1).'
    }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = (Get-Location).Path }
    $directory = Get-Item -LiteralPath $WorkingDirectory -ErrorAction Stop
    if ($directory.PSProvider.Name -ne 'FileSystem' -or -not $directory.PSIsContainer) {
        throw 'WorkingDirectory must be an existing filesystem directory.'
    }

    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    $xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Xaml\ProgressWindow.xaml') -Raw
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)

    if ($null -ne $Owner) { $window.Owner = $Owner }
    $window.FindName('HeadingText').Text = $HeadingText
    $controls = @{
        Parent = [pscustomobject]@{
            Panel = $window.FindName('OverallPanel')
            Activity = $window.FindName('OverallActivity')
            Status = $window.FindName('OverallStatus')
            Bar = $window.FindName('OverallProgress')
        }
        Child = [pscustomobject]@{
            Activity = $window.FindName('ChildActivity')
            Status = $window.FindName('ChildStatus')
            Bar = $window.FindName('ChildProgress')
        }
    }
    foreach ($name in @('ChildPanel', 'CancelButton', 'CloseButton', 'OutputPanel', 'OutputText', 'OutputTruncation')) {
        $controls[$name] = $window.FindName($name)
    }
    if ($OutputLevel -ne 'None' -or $ShowOutput) { $controls.OutputPanel.Visibility = 'Visible' }

    $cancellation = [System.Threading.CancellationTokenSource]::new()
    $context = [hashtable]::Synchronized(@{ Cancellation = $cancellation; Cancelled = $false })
    # All state below belongs to the UI thread; only context is shared with the worker.
    $state = @{
        Progress = @{}; ProgressRecordsRead = 0L; Result = $null; Ended = $false; Fault = $null
        ErrorRecords = [System.Collections.Generic.List[System.Management.Automation.ErrorRecord]]::new()
        Output = New-ScriptOutputState $OutputLevel ([bool] $ShowOutput)
    }
    $runspace = $null
    $pipeline = $null
    $async = $null
    $inputBuffer = $null
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [timespan]::FromMilliseconds(75)
    $cancel = {
        if ($cancellation.IsCancellationRequested -or $null -ne $state.Result) { return }
        $cancellation.Cancel()
        $controls.CancelButton.IsEnabled = $false
        $controls.CancelButton.Content = 'Cancelling...'
    }
    $controls.CancelButton.add_Click({ & $cancel })
    $controls.CloseButton.add_Click({ $window.Close() })
    $window.add_Closing({
        param($closingWindow, $closingEventArgs)
        if ($null -eq $state.Result -and $null -eq $state.Fault) {
            $closingEventArgs.Cancel = $true
            & $cancel
        }
    })

    try {
        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $initialState.ImportPSModule([string[]] @((Join-Path $PSScriptRoot 'PsScriptRunnerUi.psd1')))
        $runspace = [runspacefactory]::CreateRunspace($initialState)
        $runspace.ApartmentState = 'MTA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('__UiScriptContext', $context)
        # Emission is independent of display filtering. Scripts can override these preferences.
        foreach ($preference in @('InformationPreference', 'VerbosePreference', 'DebugPreference')) {
            $runspace.SessionStateProxy.SetVariable($preference, [System.Management.Automation.ActionPreference]::Continue)
        }
        $pipeline = [powershell]::Create()
        $pipeline.Runspace = $runspace
        [void] $pipeline.AddScript({
            param($Path, $Arguments, $Directory)
            Set-Location -LiteralPath $Directory -ErrorAction Stop
            try { & $Path @Arguments }
            catch [System.OperationCanceledException] {
                if (-not $global:__UiScriptContext.Cancellation.IsCancellationRequested) { throw }
                $global:__UiScriptContext.Cancelled = $true
            }
        }.ToString()).AddArgument($scriptFile.FullName).AddArgument($Parameters).AddArgument($directory.FullName)

        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        # A completed input buffer allows a script with no pipeline input to finish.
        $inputBuffer = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $inputBuffer.Complete()
        $async = $pipeline.BeginInvoke($inputBuffer, $state.Output.Buffer)
        $timer.add_Tick({
            try {
                $completed = $async.IsCompleted
                $endError = $null
                if ($completed) {
                    $state.Ended = $true
                    try { [void] $pipeline.EndInvoke($async) }
                    catch { $endError = $_ }
                }
                $progressChanged = Receive-ScriptProgress $pipeline $state ([bool] $CaptureHostOutput)
                if (-not $completed) {
                    if ($progressChanged) { Update-ScriptProgressDisplay $state $controls }
                    Update-ScriptOutputDisplay $state.Output $controls
                    return
                }

                $timer.Stop()
                $clock.Stop()
                $streamErrorCount = $state.ErrorRecords.Count
                $outcome = New-ScriptOutcome -Pipeline $pipeline -Context $context -EndError $endError `
                    -ErrorRecords $state.ErrorRecords `
                    -Duration $clock.Elapsed -ProgressRecordsRead $state.ProgressRecordsRead
                $state.Result = $outcome.Result
                if ($state.Output.Level -ge 1) {
                    for ($i = $streamErrorCount; $i -lt $state.ErrorRecords.Count; $i++) {
                        Add-ScriptOutput $state.Output 'Error' $state.ErrorRecords[$i]
                    }
                }
                Update-ScriptOutputDisplay $state.Output $controls
                Show-ScriptOutcome $controls $state.Result.Status $outcome.Message
                if ($state.Result.Status -eq 'Completed' -and $CloseOnSuccess) { $window.Close() }
            }
            catch {
                # Stop dispatching a broken UI callback; the finally block waits for cooperative cleanup.
                $state.Fault = $_
                $timer.Stop()
                $cancellation.Cancel()
                $window.Close()
            }
        })
        $timer.Start()
        [void] $window.ShowDialog()
        if ($null -ne $state.Fault) { throw $state.Fault }
        return $state.Result
    }
    finally {
        $timer.Stop()
        if ($null -ne $async -and -not $state.Ended) {
            $cancellation.Cancel()
            # A broken/closed UI must not leave the worker's buffers accumulating during cleanup.
            $state.Output.Level = 0
            $state.Output.ShowOutput = $false
            while (-not $async.IsCompleted) {
                $pipeline.Streams.Progress.Clear()
                Receive-ScriptOutputStreams $pipeline $state $false
                [void] $async.AsyncWaitHandle.WaitOne(75)
            }
            try { [void] $pipeline.EndInvoke($async) } catch { }
            $pipeline.Streams.Progress.Clear()
            Receive-ScriptOutputStreams $pipeline $state $false
        }
        if ($null -ne $pipeline) { $pipeline.Dispose() }
        if ($null -ne $runspace) { $runspace.Dispose() }
        if ($null -ne $inputBuffer) { $inputBuffer.Dispose() }
        $state.Output.Buffer.Dispose()
        $cancellation.Dispose()
    }
}

Export-ModuleMember -Function Invoke-UiScript, Test-ScriptCancellationRequested, Assert-ScriptNotCancelled
