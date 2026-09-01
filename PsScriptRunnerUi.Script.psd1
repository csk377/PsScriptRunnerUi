@{
    RootModule        = 'PsScriptRunnerUi.Script.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'dc30fa6a-dd64-4298-b8ca-552c3ed360cb'
    Author            = 'PsScriptRunnerUi contributors'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'Provides helpers used by scripts executed through PsScriptRunnerUi.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Test-ScriptCancellationRequested',
        'Assert-ScriptNotCancelled',
        'Request-UserConfirmation'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
