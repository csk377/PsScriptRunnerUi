[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $PSScriptRoot
$settingsPath = Join-Path $moduleRoot 'PSScriptAnalyzerSettings.psd1'

try {
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
}
catch {
    throw 'PSScriptAnalyzer 1.25.0 is required. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser -RequiredVersion 1.25.0'
}

$files = @(Get-ChildItem -LiteralPath $moduleRoot -File)
foreach ($directory in @('Demo', 'Tests')) {
    $files += Get-ChildItem -LiteralPath (Join-Path $moduleRoot $directory) -Recurse -File
}
$files = @($files | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } | Sort-Object FullName)

$encoding = New-Object System.Text.UTF8Encoding($true)
$unformatted = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $source = [System.IO.File]::ReadAllText($file.FullName)
    $formatterInput = $source -replace "`r`n|`n|`r", "`r`n"
    $formatted = Invoke-Formatter -ScriptDefinition $formatterInput -Settings $settingsPath
    $formatted = ($formatted -replace "`r`n|`n|`r", "`r`n").TrimEnd([char[]] "`r`n") + "`r`n"

    if ($source -ceq $formatted) { continue }

    if ($Check) {
        $unformatted.Add($file.FullName)
    }
    else {
        [System.IO.File]::WriteAllText($file.FullName, $formatted, $encoding)
        Write-Host ('Formatted {0}' -f $file.FullName)
    }
}

if ($unformatted.Count -gt 0) {
    throw ("PowerShell formatting differs in:`r`n{0}`r`nRun Tests\Format-Code.ps1 to fix it." -f
        ($unformatted -join "`r`n"))
}

if ($Check) {
    Write-Host ('PowerShell formatting is current ({0} files).' -f $files.Count)
}
