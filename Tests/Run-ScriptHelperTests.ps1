[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsScriptRunnerUi.Script.psd1') -Force
$module = Get-Module PsScriptRunnerUi.Script

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Set-ConfirmationAnswers {
    param([string[]] $Answers)
    & $module {
        param($Values)
        $script:ConfirmationAnswers = [System.Collections.Generic.Queue[string]]::new()
        foreach ($value in $Values) { $script:ConfirmationAnswers.Enqueue($value) }
        $script:ConfirmationWarnings = 0
        function script:Read-Host { $script:ConfirmationAnswers.Dequeue() }
        function script:Write-Warning { $script:ConfirmationWarnings++ }
    } $Answers
}

Set-ConfirmationAnswers @('')
Assert-True (-not (Request-UserConfirmation 'Default no')) 'An empty answer must select the No default.'
Set-ConfirmationAnswers @('')
Assert-True (Request-UserConfirmation 'Default yes' -Default Yes) 'An empty answer must select the Yes default.'
Set-ConfirmationAnswers @('invalid', 'YES')
Assert-True (Request-UserConfirmation 'Retry') 'Yes was not recognized after an invalid answer.'
$warningCount = & $module { $script:ConfirmationWarnings }
Assert-True ($warningCount -eq 1) 'An invalid CLI answer must emit one warning and retry.'
Set-ConfirmationAnswers @('n')
Assert-True (-not (Request-UserConfirmation 'Explicit no')) 'N was not recognized.'

# Exercise the worker/UI response protocol without opening a real window.
$initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$initialState.ImportPSModule([string[]] @((Join-Path $moduleRoot 'PsScriptRunnerUi.Script.psd1')))
$runspace = [runspacefactory]::CreateRunspace($initialState)
$cancellation = [System.Threading.CancellationTokenSource]::new()
$context = [hashtable]::Synchronized(@{
    Cancellation = $cancellation
    EventQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
})
$pipeline = $null
$cancelPipeline = $null
try {
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('__UiScriptContext', $context)
    $pipeline = [powershell]::Create()
    $pipeline.Runspace = $runspace
    [void] $pipeline.AddScript("Request-UserConfirmation -Message 'GUI protocol' -Title 'Confirm' -Default No")
    $async = $pipeline.BeginInvoke()
    $request = $null
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not $context.EventQueue.TryDequeue([ref] $request) -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 10
    }
    Assert-True ($null -ne $request -and $request.EventType -eq 'Confirmation' -and $request.Default -eq 'No') 'The GUI confirmation request was not queued correctly.'
    $request.Response.Result = $true
    $request.Response.Completed = $true
    $output = $pipeline.EndInvoke($async)
    Assert-True ($output.Count -eq 1 -and [bool] $output[0]) 'The GUI confirmation response was not returned to the script.'

    $cancelPipeline = [powershell]::Create()
    $cancelPipeline.Runspace = $runspace
    [void] $cancelPipeline.AddScript("Request-UserConfirmation -Message 'Cancellation protocol'")
    $cancelAsync = $cancelPipeline.BeginInvoke()
    $cancelRequest = $null
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not $context.EventQueue.TryDequeue([ref] $cancelRequest) -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 10
    }
    Assert-True ($null -ne $cancelRequest) 'The cancellation confirmation request was not queued.'
    $cancellation.Cancel()
    $cancelError = $null
    try { [void] $cancelPipeline.EndInvoke($cancelAsync) }
    catch { $cancelError = $_ }
    Assert-True ($null -ne $cancelError -and $cancelRequest.Response.Abandoned) 'Cancellation must abandon a waiting confirmation and terminate its invocation.'
}
finally {
    if ($null -ne $cancelPipeline) { $cancelPipeline.Dispose() }
    if ($null -ne $pipeline) { $pipeline.Dispose() }
    $runspace.Dispose()
    $cancellation.Dispose()
}

Write-Output 'Script helper CLI behavior, GUI response protocol, and cancellation passed.'
