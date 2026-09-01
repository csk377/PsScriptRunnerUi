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

Export-ModuleMember -Function Test-ScriptCancellationRequested, Assert-ScriptNotCancelled
