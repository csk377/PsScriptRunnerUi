[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'Format-Code.ps1') -Check
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop

# Parse module, demo, and test sources.
$files = @(Get-ChildItem -LiteralPath $moduleRoot -File)
foreach ($directory in @('Demo', 'Tests')) {
    $files += Get-ChildItem -LiteralPath (Join-Path $moduleRoot $directory) -Recurse -File
}
$files = $files | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }

$parseErrors = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($errorItem in $errors) {
        $parseErrors.Add(('{0}:{1}: {2}' -f $file.FullName, $errorItem.Extent.StartLineNumber, $errorItem.Message))
    }
}

if ($parseErrors.Count -gt 0) {
    throw ($parseErrors -join [Environment]::NewLine)
}

$excludedAnalyzerRules = @(
    'PSAvoidUsingWriteHost'                       # Host output is an intentional feature and test surface.
    'PSReviewUnusedParameter'                     # Does not recognize parameters captured by WPF event closures.
    'PSUseShouldProcessForStateChangingFunctions' # Private test helpers do not change external state.
    'PSUseSingularNouns'                          # Applies to a private test helper, not the exported API.
)
$analysisResults = @($files | ForEach-Object {
        Invoke-ScriptAnalyzer -Path $_.FullName -Severity Warning, Error -ExcludeRule $excludedAnalyzerRules
    })
if ($analysisResults.Count -gt 0) {
    $details = $analysisResults |
        Select-Object ScriptName, Line, Severity, RuleName, Message |
        Format-Table -Wrap -AutoSize |
        Out-String
    throw "PSScriptAnalyzer reported warning or error diagnostics:`r`n$details"
}

$manifest = Test-ModuleManifest -Path (Join-Path $moduleRoot 'PsScriptRunnerUi.psd1')
$scriptManifest = Test-ModuleManifest -Path (Join-Path $moduleRoot 'PsScriptRunnerUi.Script.psd1')
$expectedScriptFunctions = @('Assert-ScriptNotCancelled', 'Request-UserConfirmation', 'Test-ScriptCancellationRequested')
if (@(Compare-Object $expectedScriptFunctions @($scriptManifest.ExportedFunctions.Keys)).Count -ne 0) {
    throw 'The script-helper module exports do not match the expected functions.'
}

[pscustomobject]@{
    PowerShellVersion   = $PSVersionTable.PSVersion.ToString()
    FilesParsed         = $files.Count
    ModuleName          = $manifest.Name
    ModuleVersion       = $manifest.Version.ToString()
    ScriptModuleName    = $scriptManifest.Name
    ScriptModuleVersion = $scriptManifest.Version.ToString()
    ParseErrors         = $parseErrors.Count
    AnalyzerDiagnostics = $analysisResults.Count
} | Format-List
