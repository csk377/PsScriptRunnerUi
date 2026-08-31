param([string] $Mode = 'Success', [hashtable] $Metrics = @{}, [int] $ProgressUpdates = 1000)

$ErrorActionPreference = 'Stop'
try {
    switch ($Mode) {
        { $_ -in @('AllStreams', 'SuppressDiagnostics', 'OutputFlood') } {
            if ($Mode -eq 'SuppressDiagnostics') {
                $InformationPreference = 'Ignore'
                $VerbosePreference = 'SilentlyContinue'
                $DebugPreference = 'SilentlyContinue'
            }
            Write-Error 'error-stream' -ErrorAction Continue
            Write-Warning 'warning-stream'
            Write-Information 'information-stream'
            Write-Host 'host-stream'
            Write-Verbose 'verbose-stream'
            Write-Debug 'debug-stream'
            [pscustomobject]@{ ResultName = 'success-stream' }
            if ($Mode -eq 'OutputFlood') { 'x' * 70000 }
            Start-Sleep -Milliseconds 400
        }
        'Success' { 'discarded success output' }
        'Throw' { throw 'terminating failure' }
        'NestedThrow' { throw [System.InvalidOperationException]::new('Operation could not complete.', [System.Exception]::new('Underlying detail.')) }
        'Error' { Write-Error 'nonterminating failure' -ErrorAction Continue }
        { $_ -in @('MultipleErrors', 'ErrorsThenThrow', 'ErrorsIgnoreCancel') } {
            Write-Error 'first item failed' -ErrorId 'FirstItem' -Category InvalidData -TargetObject 'item-1' -ErrorAction Continue
            Start-Sleep -Milliseconds 400
            Write-Error 'second item failed' -ErrorId 'SecondItem' -Category InvalidOperation -TargetObject 'item-2' -ErrorAction Continue
            if ($Mode -eq 'ErrorsThenThrow') { throw 'terminal failure after item errors' }
            $Metrics.ReachedEnd = $true
        }
        'ErrorActionStop' { Write-Error 'escalated failure' -ErrorAction Stop }
        'CaughtError' {
            try { Write-Error 'handled failure' -ErrorAction Stop }
            catch { $Metrics.Handled = $true }
        }
        'ErrorDetails' {
            $failure = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Internal detail.'),
                'TestFailure', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
            $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('Friendly failure message.')
            Write-Error -ErrorRecord $failure -ErrorAction Continue
        }
        'ForeignCancellation' { throw [System.OperationCanceledException]::new('not requested') }
        'Location' { $Metrics.Location = (Get-Location).ProviderPath }
        'ProgressBurst' {
            for ($update = 1; $update -le $ProgressUpdates; $update++) {
                Write-Progress -Id 1 -Activity 'Parent' -Status "Update $update" -PercentComplete ($update % 101)
            }
        }
        'IgnoreCancel' {
            Start-Sleep -Milliseconds 400
            $Metrics.SawRequest = Test-ScriptCancellationRequested
        }
        { $_ -in @('Cancel', 'ErrorThenCancel', 'OutputCancel') } {
            if ($Mode -eq 'OutputCancel') { Write-Information 'before-cancellation' }
            if ($Mode -eq 'ErrorThenCancel') { Write-Error 'error before cancellation' -ErrorAction Continue }
            $deadline = [datetime]::UtcNow.AddSeconds(3)
            while ([datetime]::UtcNow -lt $deadline) {
                Assert-ScriptNotCancelled
                Start-Sleep -Milliseconds 10
            }
            throw 'The test did not request cancellation in time.'
        }
    }
}
finally {
    if ($Mode -in @('AllStreams', 'SuppressDiagnostics', 'OutputFlood', 'OutputCancel')) {
        Write-Information 'final-information'
        'final-success'
    }
    if ($Mode -eq 'MultipleErrors') {
        Write-Error 'cleanup error' -ErrorId 'CleanupError' -TargetObject 'cleanup' -ErrorAction Continue
    }
    Write-Progress -Id 1 -Activity 'Parent' -Completed
    $Metrics.Cleanup = $true
}
