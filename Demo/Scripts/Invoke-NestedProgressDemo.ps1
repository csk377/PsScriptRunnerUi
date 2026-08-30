[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int] $ItemCount = 4,

    [ValidateRange(1, 1000)]
    [int] $StepsPerItem = 12,

    [ValidateRange(0, 10000)]
    [int] $DelayMilliseconds = 75,

    [ValidateRange(0, 100)]
    [int] $FailAtItem = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Assert-ScriptNotCancelled -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\PsScriptRunnerUi.psd1') -ErrorAction Stop
}

Write-Host "Starting simulated work across $ItemCount work items."

try {
    for ($itemIndex = 1; $itemIndex -le $ItemCount; $itemIndex++) {
        Assert-ScriptNotCancelled

        $overallPercent = [math]::Floor((($itemIndex - 1) / $ItemCount) * 100)
        Write-Progress `
            -Id 1 `
            -Activity 'Processing work items' `
            -Status "Work item $itemIndex of $ItemCount" `
            -PercentComplete $overallPercent

        for ($step = 1; $step -le $StepsPerItem; $step++) {
            Assert-ScriptNotCancelled

            $stepPercent = [math]::Floor(($step / $StepsPerItem) * 100)
            Write-Progress `
                -Id 2 `
                -ParentId 1 `
                -Activity "Work item $itemIndex" `
                -Status "Atomic step $step of $StepsPerItem" `
                -CurrentOperation 'Simulating an atomic unit of work' `
                -PercentComplete $stepPercent

            # Cancellation is deliberately not checked during this simulated atomic step.
            Start-Sleep -Milliseconds $DelayMilliseconds
        }

        Write-Progress -Id 2 -ParentId 1 -Activity "Work item $itemIndex" -Completed
        Write-Host "Work item $itemIndex completed."

        if ($FailAtItem -eq $itemIndex) {
            throw "Deliberate failure after work item $itemIndex."
        }
    }

    Write-Progress -Id 1 -Activity 'Processing work items' -Status 'Complete' -PercentComplete 100
}
finally {
    Write-Progress -Id 2 -ParentId 1 -Activity 'Current work item' -Completed
    Write-Progress -Id 1 -Activity 'Processing work items' -Completed
    Write-Host 'Cleanup completed; operation state is safe.'
}
