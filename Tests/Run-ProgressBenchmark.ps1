[CmdletBinding()]
param(
    [ValidateRange(3, 60)]
    [int] $DurationSeconds = 5,

    [ValidateRange(1, 10)]
    [int] $Samples = 3,

    [string] $OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this benchmark in Windows PowerShell with -STA.'
}

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsScriptRunnerUi.psd1') -Force
Add-Type -AssemblyName PresentationFramework
$scriptPath = Join-Path $moduleRoot 'Demo\Scripts\Invoke-ProgressFloodDemo.ps1'
$rows = [System.Collections.Generic.List[object]]::new()

function Invoke-BenchmarkSample {
    param([string] $Mode, [int] $Seconds, [int] $Sample)

    $metrics = [hashtable]::Synchronized(@{})
    $wall = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Mode -eq 'CLI') {
        # Invoke on the real calling host, with progress enabled and no stream redirection.
        $null = & $scriptPath -DurationSeconds $Seconds -Metrics $metrics
    }
    else {
        $arguments = @{ DurationSeconds = $Seconds; Metrics = $metrics }
        $result = Invoke-UiScript -FilePath $scriptPath -Parameters $arguments -CloseOnSuccess
        if ($result.ProgressRecordsRead -ne $metrics['ProgressRecords']) { throw 'Progress records were lost.' }
        if ($result.Status -ne 'Completed' -or $result.CancellationWasRequested) {
            throw "GUI benchmark did not complete normally: $($result.Status)."
        }
    }
    $wall.Stop()
    if ($metrics['Updates'] -le 0 -or $metrics['WorkerSeconds'] -lt $Seconds) {
        throw "$Mode benchmark did not perform the requested sustained workload."
    }

    [pscustomobject]@{
        Mode = $Mode
        Sample = $Sample
        Updates = $metrics['Updates']
        ProgressRecords = $metrics['ProgressRecords']
        WorkerSeconds = $metrics['WorkerSeconds']
        WallSeconds = $wall.Elapsed.TotalSeconds
        OverheadSeconds = $wall.Elapsed.TotalSeconds - $metrics['WorkerSeconds']
        WorkerUpdatesPerSecond = $metrics['Updates'] / $metrics['WorkerSeconds']
        EndToEndUpdatesPerSecond = $metrics['Updates'] / $wall.Elapsed.TotalSeconds
    }
}

Write-Host 'Warming up CLI and the real WPF dialog (one second each)...'
$null = Invoke-BenchmarkSample -Mode CLI -Seconds 1 -Sample 0
$null = Invoke-BenchmarkSample -Mode GUI -Seconds 1 -Sample 0
for ($sample = 1; $sample -le $Samples; $sample++) {
    # Alternate order to reduce systematic warm-up/order bias.
    $modes = if (($sample % 2) -eq 1) { @('CLI', 'GUI') } else { @('GUI', 'CLI') }
    foreach ($mode in $modes) {
        Write-Host "Sample $sample/$Samples, ${mode}: flooding progress for at least $DurationSeconds seconds..."
        $rows.Add((Invoke-BenchmarkSample -Mode $mode -Seconds $DurationSeconds -Sample $sample))
    }
}

$summary = foreach ($mode in @('CLI', 'GUI')) {
    $modeRows = @($rows | Where-Object Mode -eq $mode)
    $updates = ($modeRows | Measure-Object Updates -Sum).Sum
    $workerSeconds = ($modeRows | Measure-Object WorkerSeconds -Sum).Sum
    $wallSeconds = ($modeRows | Measure-Object WallSeconds -Sum).Sum
    [pscustomobject]@{
        Mode = $mode
        Samples = $Samples
        MeanWorkerSeconds = $workerSeconds / $Samples
        MeanWallSeconds = $wallSeconds / $Samples
        WorkerUpdatesPerSecond = $updates / $workerSeconds
        EndToEndUpdatesPerSecond = $updates / $wallSeconds
    }
}
try { $processor = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Name }
catch { $processor = $env:PROCESSOR_IDENTIFIER }
$report = [pscustomobject]@{
    TimestampUtc = [datetime]::UtcNow.ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    OSVersion = [Environment]::OSVersion.VersionString
    Processor = $processor
    Implementation = 'SingleCallPollingDirectUpdates'
    HostName = $Host.Name
    ConsoleOutputRedirected = [Console]::IsOutputRedirected
    DurationSeconds = $DurationSeconds
    Samples = $Samples
    Method = 'Time-budget throughput; counts differ. Progress enabled. GUI wall time includes startup, complete progress/information drain and disposal. Module/WPF assembly import and one-second warm-ups excluded.'
    Runs = @($rows.ToArray())
    Summary = @($summary)
    GuiToCliWorkerThroughputRatio = $summary[1].WorkerUpdatesPerSecond / $summary[0].WorkerUpdatesPerSecond
    GuiToCliEndToEndThroughputRatio = $summary[1].EndToEndUpdatesPerSecond / $summary[0].EndToEndUpdatesPerSecond
}
if ($OutputPath) {
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}
$rows | Format-Table Mode, Sample, Updates,
    @{ n = 'Worker s'; e = { '{0:n3}' -f $_.WorkerSeconds } },
    @{ n = 'Wall s'; e = { '{0:n3}' -f $_.WallSeconds } },
    @{ n = 'Worker updates/s'; e = { '{0:n0}' -f $_.WorkerUpdatesPerSecond } },
    @{ n = 'End-to-end updates/s'; e = { '{0:n0}' -f $_.EndToEndUpdatesPerSecond } } -AutoSize
$summary | Format-Table -AutoSize
Write-Host ('GUI / CLI throughput: worker {0:n2}x; end-to-end {1:n2}x.' -f `
    $report.GuiToCliWorkerThroughputRatio, $report.GuiToCliEndToEndThroughputRatio)
if ($report.ConsoleOutputRedirected) {
    Write-Warning 'CLI output is redirected: these timings do not represent visible console rendering. Repeat in an interactive console.'
}
