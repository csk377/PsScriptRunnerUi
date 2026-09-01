Set-StrictMode -Version 2.0

function Get-UiRunnerContext {
    $context = Get-Variable -Name '__UiScriptContext' -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $context) { return $null }
    return $context.Value
}

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

function Request-UserConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Title = 'Confirm',
        [ValidateSet('Yes', 'No')] [string] $Default = 'No'
    )

    $context = Get-UiRunnerContext
    if ($null -eq $context) {
        $promptSuffix = if ($Default -eq 'Yes') { '[Y/n]' } else { '[y/N]' }
        while ($true) {
            $answer = Read-Host "$Message $promptSuffix"
            if ([string]::IsNullOrWhiteSpace($answer)) { return $Default -eq 'Yes' }
            if ($answer.Trim() -match '^(?i:y|yes)$') { return $true }
            if ($answer.Trim() -match '^(?i:n|no)$') { return $false }
            Write-Warning 'Please answer Y or N.'
        }
    }

    if (-not $context.ContainsKey('EventQueue')) {
        throw [System.InvalidOperationException]::new('The active UI runner does not support confirmation requests.')
    }
    if ($context.Cancellation.IsCancellationRequested) {
        throw [System.OperationCanceledException]::new('Cancellation was requested before confirmation could be displayed.')
    }
    $response = [hashtable]::Synchronized(@{
        Completed = $false
        Result = $false
        Error = $null
        Abandoned = $false
    })
    $context.EventQueue.Enqueue([pscustomobject]@{
        EventType = 'Confirmation'
        Title = $Title
        Message = $Message
        Default = $Default
        Response = $response
    })

    while (-not $response.Completed) {
        if ($context.Cancellation.IsCancellationRequested) {
            [System.Threading.Monitor]::Enter($response.SyncRoot)
            try {
                if (-not $response.Completed) { $response.Abandoned = $true }
            }
            finally { [System.Threading.Monitor]::Exit($response.SyncRoot) }
            throw [System.OperationCanceledException]::new('Cancellation was requested while waiting for confirmation.')
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -ne $response.Error) { throw $response.Error }
    return [bool] $response.Result
}

Export-ModuleMember -Function Test-ScriptCancellationRequested, Assert-ScriptNotCancelled, Request-UserConfirmation
