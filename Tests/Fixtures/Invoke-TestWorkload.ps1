param([string] $Mode = 'Success', [hashtable] $Metrics = @{}, [int] $ProgressUpdates = 1000)

$ErrorActionPreference = 'Stop'
try {
    switch ($Mode) {
        'Success' { 'discarded success output' }
        'Throw' { throw 'terminating failure' }
        'NestedThrow' { throw [System.InvalidOperationException]::new('Operation could not complete.', [System.Exception]::new('Underlying detail.')) }
        'Error' { Write-Error 'nonterminating failure' -ErrorAction Continue }
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
        { $_ -in @('Cancel', 'ErrorThenCancel') } {
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
    Write-Progress -Id 1 -Activity 'Parent' -Completed
    $Metrics.Cleanup = $true
}
