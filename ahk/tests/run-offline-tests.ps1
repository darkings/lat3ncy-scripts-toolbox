# CI-safe Windows subset. No AHK resident, HUD window, task, model or device access.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$scripts=@(Get-ChildItem -LiteralPath @((Join-Path $repo 'ahk'),(Join-Path $repo 'shared'),(Join-Path $repo 'tools')) -Filter '*.ps1' -Recurse -File |
    Where-Object {$_.FullName -notmatch '\\(bin|obj|out|test-out|dist|\.venv[^\\]*|__pycache__)\\'})
foreach($file in $scripts){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "AST errors: $($file.FullName): $($errors.Message -join '; ')"}
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    if(@($bytes | Where-Object {$_ -gt 127}).Count -and
       -not($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)){
        throw "Non-ASCII PowerShell requires UTF-8 BOM: $($file.FullName)"
    }
}
[Console]::Out.WriteLine("PASS: Windows PowerShell AST/BOM ($($scripts.Count) files)")
foreach($relative in @(
    'tools\startup\tests\ToolboxProcess.Tests.ps1',
    'tools\startup\tests\PowerPolicyHeartbeat.Tests.ps1',
    'tools\startup\tests\Deployment.Tests.ps1',
    'tools\startup\tests\DeploymentLease.Tests.ps1',
    'tools\build\tests\ManagedBuild.Tests.ps1',
    'tools\power-policy\tests\Recovery.Tests.ps1'
)){
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo $relative)
    if($LASTEXITCODE -ne 0){throw "Offline PowerShell test failed: $relative"}
}
$python=(Get-Command python.exe -ErrorAction Stop).Source
& $python -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
if($LASTEXITCODE -ne 0){throw 'Python 3.11+ required'}
foreach($relative in @('tools\translate','tools\tts','tools\raycast-scripts\ocr','tools\rgb','tools\validation')){
    & $python -S -m unittest discover -s (Join-Path $repo $relative) -p 'test_*.py' -v
    if($LASTEXITCODE -ne 0){throw "Offline Python tests failed: $relative"}
}
[Console]::Out.WriteLine('PASS: offline Windows suite (AHK/WinUI/device integration excluded; use run-tests.ps1 and the manual matrix)')
