@{
    RootModule        = 'PsScriptRunnerUi.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '1483d242-34ce-48c9-a33b-1a90218d6451'
    Author            = 'PsScriptRunnerUi contributors'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'Runs one PowerShell script asynchronously behind a responsive WPF progress dialog.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-UiScript',
        'Test-ScriptCancellationRequested',
        'Assert-ScriptNotCancelled'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('WPF', 'Runspace', 'Progress')
        }
    }
}
