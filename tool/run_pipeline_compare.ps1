param(
    [string]$CsvPath,
    [string]$DngPath,
    [int]$Row = 0,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Select-File([string]$Title, [string]$Filter, [string]$InitialDirectory) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    if ($InitialDirectory -and (Test-Path $InitialDirectory)) {
        $dialog.InitialDirectory = $InitialDirectory
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    throw "No file selected for $Title"
}

if (-not $CsvPath) {
    $CsvPath = Select-File -Title "Select ROI CSV" -Filter "CSV files (*.csv)|*.csv|All files (*.*)|*.*" `
        -InitialDirectory (Join-Path $PSScriptRoot "..\storage\debug")
}
if (-not $DngPath) {
    $DngPath = Select-File -Title "Select matching DNG" -Filter "DNG files (*.dng)|*.dng|All files (*.*)|*.*" `
        -InitialDirectory ([System.IO.Path]::GetDirectoryName($CsvPath))
}

if (-not $OutputDir) {
    $csvDir = [System.IO.Path]::GetDirectoryName($CsvPath)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputDir = Join-Path $csvDir "pipeline_plots_$timestamp"
}

$python = Resolve-Path (Join-Path $PSScriptRoot "..\..\.venv\Scripts\python.exe")
$script = Join-Path $PSScriptRoot "pipeline_compare.py"

Write-Host "Running pipeline_compare.py..."
& $python $script --roi-csv $CsvPath --dng $DngPath --row $Row --output-dir $OutputDir

Write-Host "Plots saved to $OutputDir"
if (Test-Path $OutputDir) {
    Start-Process explorer.exe $OutputDir
}
