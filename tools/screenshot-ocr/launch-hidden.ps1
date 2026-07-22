$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'screenshot_ocr.py'
$launchFailures = @()

$pythonw = Get-Command pythonw.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pythonw) {
    try {
        Start-Process -FilePath $pythonw.Source -ArgumentList @("`"$scriptPath`"") -WindowStyle Hidden
        exit 0
    }
    catch {
        $launchFailures += "pythonw.exe: $($_.Exception.Message)"
    }
}

$pyw = Get-Command pyw.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pyw) {
    try {
        Start-Process -FilePath $pyw.Source -ArgumentList @('-3', "`"$scriptPath`"") -WindowStyle Hidden
        exit 0
    }
    catch {
        $launchFailures += "pyw.exe: $($_.Exception.Message)"
    }
}

if ($launchFailures.Count -gt 0) {
    $message = "Python was found but Screenshot OCR failed to start:`n" + ($launchFailures -join "`n")
}
else {
    $message = 'Python 3 was not found. Install Python with pythonw.exe or the Python Launcher (pyw.exe), and ensure it is available on PATH.'
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    $message,
    'Screenshot OCR could not start',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
) | Out-Null
exit 1
