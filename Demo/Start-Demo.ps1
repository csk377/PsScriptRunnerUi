[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'The demo must run in an STA PowerShell process. Use Windows PowerShell 5.1 or start PowerShell with -STA.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

$modulePath = Join-Path $PSScriptRoot '..\PsScriptRunnerUi.psd1'
Import-Module $modulePath -Force

$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8
$window = [System.Windows.Markup.XamlReader]::Parse($xaml)

$scenarioBox = $window.FindName('ScenarioBox')
$closeOnSuccessBox = $window.FindName('CloseOnSuccessBox')
$captureHostBox = $window.FindName('CaptureHostBox')
$outputLevelBox = $window.FindName('OutputLevelBox')
$showOutputBox = $window.FindName('ShowOutputBox')
$runButton = $window.FindName('RunButton')
$resultText = $window.FindName('ResultText')
$demoScript = Join-Path $PSScriptRoot 'Scripts\Invoke-NestedProgressDemo.ps1'

$runButton.add_Click({
    $scenario = $scenarioBox.SelectedItem.Tag.ToString()
    $headingText = "Demo: $($scenarioBox.SelectedItem.Content)"
    $parameters = @{
        ItemCount = 4
        StepsPerItem = 12
        DelayMilliseconds = 40
        FailAtItem = if ($scenario -eq 'Failure') { 2 } else { 0 }
        EmitErrors = $scenario -eq 'CompletedWithErrors'
        AskForConfirmation = $scenario -eq 'Confirmation'
    }

    if ($scenario -eq 'Cancellation') {
        $parameters.ItemCount = 8
        $parameters.StepsPerItem = 20
        $parameters.DelayMilliseconds = 125
    }

    $selectedScript = $demoScript
    if ($scenario -eq 'ProgressFlood') {
        $selectedScript = Join-Path $PSScriptRoot 'Scripts\Invoke-ProgressFloodDemo.ps1'
        $parameters = @{ DurationSeconds = 5 }
    }

    $runButton.IsEnabled = $false
    $resultText.Text = 'Running...'
    try {
        $result = Invoke-UiScript `
            -FilePath $selectedScript `
            -HeadingText $headingText `
            -Parameters $parameters `
            -CaptureHostOutput:([bool] $captureHostBox.IsChecked) `
            -OutputLevel $outputLevelBox.SelectedItem.Content.ToString() `
            -ShowOutput:([bool] $showOutputBox.IsChecked) `
            -Owner $window `
            -CloseOnSuccess:([bool] $closeOnSuccessBox.IsChecked)

        if ($null -eq $result) {
            $resultText.Text = 'The dialog closed without a result.'
        }
        else {
            $resultText.Text = 'Status: {0}; duration: {1:n1}s; cancellation requested: {2}; errors: {3}' -f `
                $result.Status,
                $result.Duration.TotalSeconds,
                $result.CancellationWasRequested,
                $result.ErrorCount
        }
    }
    catch {
        $resultText.Text = "Runner error: $($_.Exception.Message)"
    }
    finally {
        $runButton.IsEnabled = $true
    }
})

[void] $window.ShowDialog()
