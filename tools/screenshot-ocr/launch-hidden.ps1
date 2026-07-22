$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'screenshot_ocr.py'

$pythonw = Get-Command pythonw.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pythonw) {
    Start-Process -FilePath $pythonw.Source -ArgumentList @("`"$scriptPath`"") -WindowStyle Hidden
    exit 0
}

$pyw = Get-Command pyw.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pyw) {
    Start-Process -FilePath $pyw.Source -ArgumentList @('-3', "`"$scriptPath`"") -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    'Python 3 was not found. Install Python with pythonw.exe or the Python Launcher (pyw.exe), and ensure it is available on PATH.',
    'Screenshot OCR could not start',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
) | Out-Null
exit 1
