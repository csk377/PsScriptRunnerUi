# PsScriptRunnerUi

PsScriptRunnerUi runs Windows PowerShell 5.1 scripts in a background MTA runspace with a WPF progress dialog. It requires Windows and an STA UI thread. `Invoke-UiScript` manages the worker, dialog, cancellation, and cleanup.

```powershell
Import-Module '.\PsScriptRunnerUi.psd1'
$result = Invoke-UiScript -FilePath $scriptPath -Parameters @{ TargetPath = $targetPath } `
    -HeadingText 'Process target files' -Owner $mainWindow -CaptureHostOutput -CloseOnSuccess
```

Each call runs one script and returns its result after the dialog closes. Disable your Run button before calling and re-enable it in `finally`.

`-HeadingText` describes the intended operation and stays unchanged throughout the run. It defaults to `Run script`. Progress and the final status appear below it.

## Run the demo

From the repository directory:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File '.\Demo\Start-Demo.ps1'
```

The demo simulates success, confirmation, nonterminating errors, failure, cancellation, and a progress flood. Declining confirmation prevents launch.

Collect user input before launch and pass it as script parameters. Workers cannot use `Read-Host`, credential prompts, or other interactive host requests. They start in the caller's filesystem location unless you pass `-WorkingDirectory`, but do not inherit caller functions, variables, or application modules.

## How polling works

A WPF timer drains progress every 75 ms. The dialog uses the latest record per activity to show the most recently updated root and direct child. It does not show deeper trees. Completed activities leave the display, but completing a parent leaves its children. Reusing the parent's ID can attach those children to the new activity.

`ProgressRecordsRead` counts every drained record, including updates skipped for display. Before allowing the dialog to close, the module calls `EndInvoke`, drains remaining progress, error, and information records, and displays the result. Idle polls drain errors and information without redrawing progress.

`-CaptureHostOutput` forwards information messages to the launching host as plain text, without colors or `-NoNewline`. Otherwise, the module discards them. It does not preserve ordering across streams. The worker discards success output and keeps errors for the result. Warning, verbose, and debug records accumulate without display.

## Cancellation and results

Cancel or window close requests cancellation without confirmation. The dialog waits for the script and its cleanup. Check for cancellation where your script can safely stop:

```powershell
try {
    foreach ($item in $items) {
        Assert-ScriptNotCancelled
        Invoke-ItemOperation -Item $item
    }
}
finally {
    # Release resources and restore any temporary state.
}
```

Workers import the module automatically. CLI scripts must import it to use the helpers. Outside a worker, `Assert-ScriptNotCancelled` does nothing and `Test-ScriptCancellationRequested` returns false.

The result contains `Status`, `Duration`, `CancellationWasRequested`, `ErrorRecord`, `ErrorRecords`, `ErrorCount`, and `ProgressRecordsRead`:

- Normal completion with nonterminating errors produces `CompletedWithErrors`.
- An unhandled terminating error produces `Failed`.
- An `OperationCanceledException` caught by the worker after a cancellation request produces `Cancelled` if no other errors occurred. Without a request, it produces `Failed`.
- A normal return with no errors produces `Completed`, even after a cancellation request.

`ErrorRecords` retains all observed errors as full PowerShell error records; `ErrorCount` gives the total. `ErrorRecord` is the terminating error, otherwise the first error, or null. Inspect the details after the call returns:

```powershell
$result.ErrorRecords | Format-List *
```

Handled, suppressed, or redirected errors may not reach the runner. Cancellation after earlier errors remains `Failed`.

Scripts must check native exit codes and convert failures into errors. `-CloseOnSuccess` closes only `Completed` results, never `CompletedWithErrors`. Otherwise, click Close.

The result panel shows a selectable message: green for success, yellow for cancellation or completion with errors, and red for failure. `CompletedWithErrors` shows the error count. Normal completion after a cancellation request mentions the request. Failure messages prefer explicit error details over the exception message and omit the `EndInvoke` wrapper.

## Limitations

- Cancellation is cooperative, with no timeout, forced stop, or native-process termination. Scripts that ignore it can block the dialog or cleanup after a UI failure indefinitely.
- Polls drain whole batches. Large batches or heavy host output can delay input, and undrained output buffers can grow. There is no guaranteed response-time or memory limit.
- All errors are retained, so memory use grows with error volume.
- Test shutdown, external window changes, focus, ownership, and production workloads in your host application.

## Verification and benchmark

Run from the repository directory in an interactive Windows session. Smoke tests open and close WPF dialogs:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\Tests\Run-StaticChecks.ps1'
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File '.\Tests\Run-SmokeTests.ps1'
```

Tests cover progress state, cancellation, errors, cleanup, host output, working directories, and repeated calls. They also verify that automatic close waits for all progress records. To check progress state without WPF or timing dependencies:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\Tests\Run-ProgressStateTests.ps1'
```

The optional benchmark compares CLI and GUI progress throughput. Use an interactive console for visible CLI progress. Omit `-OutputPath` to skip saving a report:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File '.\Tests\Run-ProgressBenchmark.ps1' -OutputPath (Join-Path $env:TEMP 'PsScriptRunnerUi.benchmark.json')
```

Each mode gets a one-second warm-up and three five-second samples, with CLI/GUI order alternating. Change the workload with `-DurationSeconds` and `-Samples`. Counts measure emitted updates, not rendered frames. The GUI must drain every record.

Wall time includes startup, stream draining, and disposal, but excludes module/WPF imports, warm-up, and reporting. Reports include implementation and environment metadata. Results depend on the host and workload, and do not establish input latency or peak memory limits.
