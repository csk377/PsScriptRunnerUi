[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PsScriptRunnerUi.psd1') -Force

& (Get-Module PsScriptRunnerUi) {
    function Assert-True {
        param([bool] $Condition, [string] $Message)
        if (-not $Condition) { throw $Message }
    }

    $levels = @('None', 'Error', 'Warn', 'Info', 'Verbose', 'Debug')
    foreach ($level in $levels) {
        foreach ($show in @($false, $true)) {
            $pipeline = [powershell]::Create()
            $state = @{
                ErrorRecords = [System.Collections.Generic.List[System.Management.Automation.ErrorRecord]]::new()
                Output = New-ScriptOutputState $level $show
            }
            try {
                $errorRecord = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('internal error'),
                    'TestError', [System.Management.Automation.ErrorCategory]::InvalidData, 'target')
                $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('friendly error')
                $pipeline.Streams.Error.Add($errorRecord)
                $pipeline.Streams.Warning.Add([System.Management.Automation.WarningRecord]::new('warning message'))
                $pipeline.Streams.Information.Add([System.Management.Automation.InformationRecord]::new('information message', 'test'))
                $pipeline.Streams.Verbose.Add([System.Management.Automation.VerboseRecord]::new('verbose message'))
                $pipeline.Streams.Debug.Add([System.Management.Automation.DebugRecord]::new('debug message'))
                $state.Output.Buffer.Add([pscustomobject]@{ ResultName = 'returned value' })

                Receive-ScriptOutputStreams $pipeline $state $false
                $text = $state.Output.Text.ToString()
                $rank = [array]::IndexOf($levels, $level)
                $expectations = @{
                    '[Error] friendly error' = $rank -ge 1
                    '[Warn] warning message' = $rank -ge 2
                    '[Info] information message' = $rank -ge 3
                    '[Verbose] verbose message' = $rank -ge 4
                    '[Debug] debug message' = $rank -ge 5
                    'returned value' = $show
                }
                foreach ($token in $expectations.Keys) {
                    Assert-True ($text.Contains($token) -eq $expectations[$token]) "$level / ShowOutput=$show incorrectly filtered $token."
                }
                foreach ($name in @('Error', 'Warning', 'Information', 'Verbose', 'Debug')) {
                    Assert-True ($pipeline.Streams.$name.Count -eq 0) "$name was not drained at $level."
                }
                Assert-True ($state.Output.Buffer.Count -eq 0) "Success output was not drained at $level."
                Assert-True ($state.ErrorRecords.Count -eq 1 -and [object]::ReferenceEquals($state.ErrorRecords[0], $errorRecord)) 'Filtering changed the retained errors.'
                $state.Output.Changed = $false
                Receive-ScriptOutputStreams $pipeline $state $false
                Assert-True (-not $state.Output.Changed -and $state.Output.Text.ToString() -ceq $text) 'An empty poll changed the log.'
            }
            finally { $pipeline.Dispose(); $state.Output.Buffer.Dispose() }
        }
    }

    $outputState = New-ScriptOutputState 'Debug' $true
    try {
        Add-ScriptOutput $outputState 'Output' ('old-' + ('x' * 70000))
        Add-ScriptOutput $outputState 'Output' 'newest message'
        Assert-True ($outputState.Truncated -and $outputState.Text.Length -le 65536 -and
            $outputState.Text.ToString().EndsWith("newest message$([Environment]::NewLine)")) 'Output history must be bounded and retain its tail.'
    }
    finally { $outputState.Buffer.Dispose() }
}

Write-Output 'All output levels, success-output filtering, stream draining, and history bounds passed.'
