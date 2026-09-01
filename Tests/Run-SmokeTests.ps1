[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or [System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Use Windows PowerShell 5.1 with -STA.'
}
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsScriptRunnerUi.psd1') -Force
Import-Module (Join-Path $moduleRoot 'PsScriptRunnerUi.Script.psd1') -Force
Add-Type -AssemblyName PresentationFramework
& (Join-Path $PSScriptRoot 'Run-ProgressStateTests.ps1')
& (Join-Path $PSScriptRoot 'Run-OutputStateTests.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (-not (Test-ScriptCancellationRequested)) 'CLI cancellation fallback must be inactive.'
Assert-ScriptNotCancelled
$runspacesBefore = @(Get-Runspace).Count

# Drive real WPF controls on their dispatcher.
$owner = [System.Windows.Window]::new()
$owner.Title = 'PsScriptRunnerUi test owner'
$owner.Width = 1
$owner.Height = 1
$owner.ShowInTaskbar = $false
$owner.Opacity = 0
$owner.Show()
$rows = [System.Collections.Generic.List[object]]::new()
function Invoke-Scenario {
    param([string]$Mode, [string]$Expected, [string]$CancelAction, [string]$ExpectedMessage, [int]$ExpectedErrors = 0,
        [string]$OutputLevel = 'None', [switch]$ShowOutput)

    $metrics = [hashtable]::Synchronized(@{})
    $probe = @{ Sent = $false; TerminalValues = $false; TerminalDetails = 'No completed dialog was observed.' }
    $probe.CancelDisabled = $false
    $probe.LiveOutput = $false
    $probe.OutputText = ''
    $probe.OutputVisible = $false
    $probe.Truncated = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $observer = [System.Windows.Threading.DispatcherTimer]::new()
    $observer.Interval = [timespan]::FromMilliseconds(20)
    $observer.add_Tick({
            foreach ($dialog in @($owner.OwnedWindows)) {
                if ($dialog.FindName('CloseButton').Visibility -ne 'Visible' -and $dialog.FindName('OutputText').Text.Length -gt 0) {
                    $probe.LiveOutput = $true
                }
                if ($CancelAction -and -not $probe.Sent -and $clock.ElapsedMilliseconds -ge 150) {
                    $probe.Sent = $true
                    if ($CancelAction -eq 'Close') { $dialog.Close() }
                    else { $dialog.FindName('CancelButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) }
                    $probe.CancelDisabled = -not $dialog.FindName('CancelButton').IsEnabled
                }
                if ($dialog.FindName('CloseButton').Visibility -eq 'Visible') {
                    $probe.OutputText = $dialog.FindName('OutputText').Text
                    $probe.OutputVisible = $dialog.FindName('OutputPanel').Visibility -eq 'Visible'
                    $probe.Truncated = $dialog.FindName('OutputTruncation').Visibility -eq 'Visible'
                    $probe.TerminalValues = $dialog.FindName('CancelButton').Visibility -eq 'Collapsed' -and
                    $dialog.FindName('CloseButton').IsEnabled -and
                    $dialog.FindName('OverallActivity').Text -eq $Expected -and
                    (-not $ExpectedMessage -or $dialog.FindName('OverallStatus').Text -ceq $ExpectedMessage)
                    if ($Expected -eq 'CompletedWithErrors') {
                        $probe.TerminalValues = $probe.TerminalValues -and
                        $dialog.FindName('OverallPanel').Background.ToString() -eq '#FFFFF8DB'
                    }
                    $probe.TerminalDetails = 'Message={0}; Cancel={1}; CloseEnabled={2}; Activity={3}' -f `
                        $dialog.FindName('OverallStatus').Text, $dialog.FindName('CancelButton').Visibility,
                    $dialog.FindName('CloseButton').IsEnabled, $dialog.FindName('OverallActivity').Text
                    $dialog.Close()
                }
            }
        })
    $observer.Start()
    try {
        $result = Invoke-UiScript -FilePath (Join-Path $PSScriptRoot 'Fixtures\Invoke-TestWorkload.ps1') `
            -Parameters @{ Mode = $Mode; Metrics = $metrics } -Owner $owner -WorkingDirectory $PSScriptRoot `
            -OutputLevel $OutputLevel -ShowOutput:$ShowOutput `
            -CloseOnSuccess:($Expected -ne 'Completed')
        Assert-True ($result.Status -eq $Expected) "$Mode expected $Expected, received $($result.Status)."
        Assert-True ($metrics.Cleanup -eq $true) "$Mode did not finish cleanup."
        Assert-True ($result.ErrorCount -eq $ExpectedErrors -and $result.ErrorRecords.Count -eq $ExpectedErrors) "$Mode did not retain exactly $ExpectedErrors errors."
        Assert-True ($result.ErrorRecords -is [System.Management.Automation.ErrorRecord[]]) "$Mode must return a typed array, including when empty."
        Assert-True $probe.TerminalValues "$Mode did not render its terminal display values correctly. $($probe.TerminalDetails)"
        Assert-True ($probe.OutputVisible -eq ($OutputLevel -ne 'None' -or $ShowOutput)) 'Output panel visibility did not match the selected options.'
        if ($OutputLevel -eq 'None' -and -not $ShowOutput) {
            Assert-True ($probe.OutputText.Length -eq 0) 'Disabled output should not populate the output panel.'
        }
        if ($Mode -in @('AllStreams', 'SuppressDiagnostics')) {
            $rank = [array]::IndexOf(@('None', 'Error', 'Warn', 'Info', 'Verbose', 'Debug'), $OutputLevel)
            $diagnosticsEnabled = $Mode -ne 'SuppressDiagnostics'
            $expectations = @{
                '[Error] error-stream'     = $rank -ge 1
                '[Warn] warning-stream'    = $rank -ge 2
                'information-stream'       = $rank -ge 3 -and $diagnosticsEnabled
                'host-stream'              = $rank -ge 3 -and $diagnosticsEnabled
                '[Verbose] verbose-stream' = $rank -ge 4 -and $diagnosticsEnabled
                '[Debug] debug-stream'     = $rank -ge 5 -and $diagnosticsEnabled
                'success-stream'           = [bool]$ShowOutput
                'final-success'            = [bool]$ShowOutput
                'final-information'        = $rank -ge 3 -and $diagnosticsEnabled
            }
            foreach ($token in $expectations.Keys) {
                Assert-True ($probe.OutputText.Contains($token) -eq $expectations[$token]) "$Mode / $OutputLevel / ShowOutput=$ShowOutput incorrectly displayed $token."
            }
            Assert-True (-not $probe.OutputText.Contains('[Info]')) "$Mode / $OutputLevel / ShowOutput=$ShowOutput prefixed information output."
            Assert-True ($probe.LiveOutput -eq ($rank -gt 0 -or $ShowOutput)) 'Output did not stream before the script finished.'
        }
        if ($Mode -eq 'OutputFlood') {
            Assert-True ($probe.Truncated -and $probe.OutputText.Length -le 65536 -and $probe.OutputText.Contains('final-success')) 'The WPF log did not bound its history or retain final output.'
        }
        if ($Mode -eq 'Throw' -and $OutputLevel -eq 'Error') {
            Assert-True ($probe.OutputText.Contains('[Error] terminating failure')) 'The terminal error was missing from the output panel.'
        }
        if ($Mode -eq 'OutputCancel') {
            Assert-True ($probe.OutputText.Contains('before-cancellation') -and
                $probe.OutputText.Contains('final-information') -and $probe.OutputText.Contains('final-success')) 'Cancellation lost output emitted during cleanup.'
        }
        if ($CancelAction) {
            Assert-True $result.CancellationWasRequested "$Mode lost its cancellation request."
            Assert-True $probe.CancelDisabled "$Mode kept Cancel enabled after a cancellation request."
        }
        if ($ExpectedErrors -gt 0) { Assert-True ($null -ne $result.ErrorRecord) "$Mode lost its error record." }
        else { Assert-True ($null -eq $result.ErrorRecord) "$Mode unexpectedly returned an error." }
        if ($Mode -in @('MultipleErrors', 'ErrorsThenThrow', 'ErrorsIgnoreCancel')) {
            Assert-True ($result.ErrorRecords[0].TargetObject -eq 'item-1' -and
                $result.ErrorRecords[1].TargetObject -eq 'item-2') "$Mode lost error ordering or target details."
            Assert-True ($result.ErrorRecords[0].FullyQualifiedErrorId -match '^FirstItem' -and
                $result.ErrorRecords[0].CategoryInfo.Category -eq 'InvalidData' -and
                $result.ErrorRecords[0].InvocationInfo.ScriptLineNumber -gt 0 -and
                -not [string]::IsNullOrWhiteSpace($result.ErrorRecords[0].ScriptStackTrace)) "$Mode lost structured error details."
        }
        if ($Mode -eq 'MultipleErrors') {
            Assert-True ($metrics.ReachedEnd -and $result.ErrorRecords[2].TargetObject -eq 'cleanup') 'Normal completion must retain the final cleanup error.'
        }
        if ($Mode -eq 'ErrorsThenThrow') {
            Assert-True ($result.ErrorRecords[2].Exception.Message -eq 'terminal failure after item errors' -and
                $result.ErrorRecord -eq $result.ErrorRecords[2]) 'The terminal error must be retained once and selected for the failure summary.'
        }
        if ($Mode -eq 'ErrorDetails') {
            Assert-True ($result.ErrorRecords[0].ErrorDetails.Message -eq 'Friendly failure message.') 'ErrorDetails were lost.'
        }
        if ($Mode -eq 'CaughtError') { Assert-True $metrics.Handled 'The script did not handle its error.' }
        if ($Mode -eq 'IgnoreCancel') { Assert-True $metrics.SawRequest 'The worker did not see the close request.' }
        if ($Mode -eq 'Location') { Assert-True ($metrics.Location -eq $PSScriptRoot) 'WorkingDirectory was not applied.' }
        if ($Mode -eq 'Success') { Assert-True $metrics.ConfirmationHelperAvailable 'The worker did not import Request-UserConfirmation.' }
        $rows.Add([pscustomobject]@{ Scenario = $Mode; Status = $result.Status; ProgressRecords = $result.ProgressRecordsRead })
    }
    finally { $observer.Stop() }
}

try {
    Invoke-Scenario Success Completed
    Invoke-Scenario Throw Failed -ExpectedMessage 'terminating failure' -ExpectedErrors 1
    Invoke-Scenario NestedThrow Failed -ExpectedMessage 'Operation could not complete.' -ExpectedErrors 1
    Invoke-Scenario Error CompletedWithErrors -ExpectedMessage 'Completed with 1 error(s).' -ExpectedErrors 1
    Invoke-Scenario ErrorDetails CompletedWithErrors -ExpectedMessage 'Completed with 1 error(s).' -ExpectedErrors 1
    Invoke-Scenario MultipleErrors CompletedWithErrors -ExpectedMessage 'Completed with 3 error(s).' -ExpectedErrors 3
    Invoke-Scenario ErrorsThenThrow Failed -ExpectedMessage 'terminal failure after item errors' -ExpectedErrors 3
    Invoke-Scenario ErrorActionStop Failed -ExpectedMessage 'escalated failure' -ExpectedErrors 1
    Invoke-Scenario CaughtError Completed
    Invoke-Scenario ErrorsIgnoreCancel CompletedWithErrors -CancelAction Button -ExpectedErrors 2 `
        -ExpectedMessage 'Completed with 2 error(s). Cancellation was requested, but the script completed normally.'
    Invoke-Scenario ForeignCancellation Failed -ExpectedMessage 'not requested' -ExpectedErrors 1
    Invoke-Scenario Cancel Cancelled -CancelAction Button
    Invoke-Scenario Cancel Cancelled -CancelAction Close
    Invoke-Scenario IgnoreCancel Completed -CancelAction Close
    Invoke-Scenario ErrorThenCancel Failed -CancelAction Button -ExpectedMessage 'error before cancellation' -ExpectedErrors 1
    Invoke-Scenario Location Completed
    foreach ($level in @('None', 'Error', 'Warn', 'Info', 'Verbose', 'Debug')) {
        Invoke-Scenario AllStreams CompletedWithErrors -ExpectedErrors 1 -OutputLevel $level
        Invoke-Scenario AllStreams CompletedWithErrors -ExpectedErrors 1 -OutputLevel $level -ShowOutput
    }
    Invoke-Scenario SuppressDiagnostics CompletedWithErrors -ExpectedErrors 1 -OutputLevel Debug -ShowOutput
    Invoke-Scenario OutputFlood CompletedWithErrors -ExpectedErrors 1 -OutputLevel Debug -ShowOutput
    Invoke-Scenario Throw Failed -ExpectedErrors 1 -OutputLevel Error
    Invoke-Scenario OutputCancel Cancelled -CancelAction Button -OutputLevel Info -ShowOutput
    # No observer closes this dialog: success must autoclose after the final drain.
    $metrics = [hashtable]::Synchronized(@{})
    $progressUpdates = 1000
    $result = Invoke-UiScript -FilePath (Join-Path $PSScriptRoot 'Fixtures\Invoke-TestWorkload.ps1') `
        -Parameters @{ Mode = 'ProgressBurst'; Metrics = $metrics; ProgressUpdates = $progressUpdates } `
        -Owner $owner -CloseOnSuccess
    Assert-True ($result.Status -eq 'Completed' -and -not $result.CancellationWasRequested) 'The progress burst did not complete normally.'
    Assert-True ($result.ProgressRecordsRead -eq $progressUpdates + 1) 'Success autoclose lost progress records, including the final completion record.'
    Assert-True ($metrics.Cleanup -eq $true) 'Success autoclose did not await worker cleanup.'
    Write-Output "Success autoclose drained all $($result.ProgressRecordsRead) progress records."

    # A polling failure must close via Fault, throw to the caller, and await worker cleanup.
    $module = Get-Module PsScriptRunnerUi
    $receiveOriginal = & $module { (Get-Command Receive-ScriptProgress).ScriptBlock }
    $metrics = [hashtable]::Synchronized(@{})
    $pollingError = $null
    try {
        & $module { function script:Receive-ScriptProgress { throw 'Deliberate polling failure.' } }
        try {
            $null = Invoke-UiScript -FilePath (Join-Path $PSScriptRoot 'Fixtures\Invoke-TestWorkload.ps1') `
                -Parameters @{ Mode = 'Cancel'; Metrics = $metrics } -Owner $owner
        }
        catch { $pollingError = $_ }
    }
    finally { & $module { param($Original) Set-Item -Path Function:script:Receive-ScriptProgress -Value $Original } $receiveOriginal }
    Assert-True ($null -ne $pollingError -and $pollingError.Exception.Message -match 'Deliberate polling failure') 'A UI polling fault must throw the original error.'
    Assert-True ($metrics.Cleanup -eq $true) 'A UI polling fault did not await worker cleanup.'
    Assert-True (@(Get-Runspace).Count -eq $runspacesBefore) 'A worker runspace remained after invocation cleanup.'
    $rows | Format-Table -AutoSize
    Write-Output 'UI polling-fault cleanup and direct WPF display checks passed.'
}
finally { $owner.Close() }
