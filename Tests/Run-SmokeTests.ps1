[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or [System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Use Windows PowerShell 5.1 with -STA.'
}
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsScriptRunnerUi.psd1') -Force
Add-Type -AssemblyName PresentationFramework
& (Join-Path $PSScriptRoot 'Run-ProgressStateTests.ps1')

function Assert-True {
    param([bool] $Condition, [string] $Message)
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
    param([string] $Mode, [string] $Expected, [string] $CancelAction, [string] $ExpectedMessage)

    $metrics = [hashtable]::Synchronized(@{})
    $probe = @{ Sent = $false; TerminalValues = $false; TerminalDetails = 'No completed dialog was observed.' }
    $probe.CancelDisabled = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $observer = [System.Windows.Threading.DispatcherTimer]::new()
    $observer.Interval = [timespan]::FromMilliseconds(20)
    $observer.add_Tick({
        foreach ($dialog in @($owner.OwnedWindows)) {
            if ($CancelAction -and -not $probe.Sent -and $clock.ElapsedMilliseconds -ge 150) {
                $probe.Sent = $true
                if ($CancelAction -eq 'Close') { $dialog.Close() }
                else { $dialog.FindName('CancelButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) }
                $probe.CancelDisabled = -not $dialog.FindName('CancelButton').IsEnabled
            }
            if ($dialog.FindName('CloseButton').Visibility -eq 'Visible') {
                $probe.TerminalValues = $dialog.FindName('CancelButton').Visibility -eq 'Collapsed' -and
                    $dialog.FindName('CloseButton').IsEnabled -and
                    $dialog.FindName('OverallActivity').Text -eq $Expected -and
                    (-not $ExpectedMessage -or $dialog.FindName('OverallStatus').Text -ceq $ExpectedMessage)
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
            -CloseOnSuccess:($Expected -ne 'Completed')
        Assert-True ($result.Status -eq $Expected) "$Mode expected $Expected, received $($result.Status)."
        Assert-True ($metrics.Cleanup -eq $true) "$Mode did not finish cleanup."
        Assert-True $probe.TerminalValues "$Mode did not render its terminal display values correctly. $($probe.TerminalDetails)"
        if ($CancelAction) {
            Assert-True $result.CancellationWasRequested "$Mode lost its cancellation request."
            Assert-True $probe.CancelDisabled "$Mode kept Cancel enabled after a cancellation request."
        }
        if ($Expected -eq 'Failed') { Assert-True ($null -ne $result.ErrorRecord) "$Mode lost its error record." }
        if ($Mode -eq 'IgnoreCancel') { Assert-True $metrics.SawRequest 'The worker did not see the close request.' }
        if ($Mode -eq 'Location') { Assert-True ($metrics.Location -eq $PSScriptRoot) 'WorkingDirectory was not applied.' }
        $rows.Add([pscustomobject]@{ Scenario = $Mode; Status = $result.Status; ProgressRecords = $result.ProgressRecordsRead })
    }
    finally { $observer.Stop() }
}

try {
    Invoke-Scenario Success Completed
    Invoke-Scenario Throw Failed -ExpectedMessage 'terminating failure'
    Invoke-Scenario NestedThrow Failed -ExpectedMessage 'Operation could not complete.'
    Invoke-Scenario Error Failed -ExpectedMessage 'nonterminating failure'
    Invoke-Scenario ErrorDetails Failed -ExpectedMessage 'Friendly failure message.'
    Invoke-Scenario ForeignCancellation Failed -ExpectedMessage 'not requested'
    Invoke-Scenario Cancel Cancelled -CancelAction Button
    Invoke-Scenario Cancel Cancelled -CancelAction Close
    Invoke-Scenario IgnoreCancel Completed -CancelAction Close
    Invoke-Scenario ErrorThenCancel Failed -CancelAction Button -ExpectedMessage 'error before cancellation'
    Invoke-Scenario Location Completed
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
