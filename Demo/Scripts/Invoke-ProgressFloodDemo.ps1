[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int] $DurationSeconds = 5,

    # The runner discards success output; a shared hashtable also exposes metrics to GUI callers.
    [hashtable] $Metrics = @{}
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

if (-not (Get-Command Assert-ScriptNotCancelled -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\PsScriptRunnerUi.psd1') -ErrorAction Stop
}

# Intentionally bad example: every trivial iteration emits progress, even when the
# displayed percentage has not changed. No sleep, delay, or progress throttling.
$updates = 0L
$clock = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
        if (($updates % 256) -eq 0) {
            Assert-ScriptNotCancelled
        }
        Write-Progress -Id 1 -Activity 'Poorly written progress flood' `
            -Status "Unnecessary update $updates" `
            -PercentComplete ([int] [math]::Min(99, $clock.Elapsed.TotalSeconds * 100 / $DurationSeconds))
        $updates++
    }
}
finally {
    Write-Progress -Id 1 -Activity 'Poorly written progress flood' -Completed
    $clock.Stop()
    $Metrics['Updates'] = $updates
    $Metrics['ProgressRecords'] = $updates + 1
    $Metrics['WorkerSeconds'] = $clock.Elapsed.TotalSeconds
}

[pscustomobject] $Metrics
