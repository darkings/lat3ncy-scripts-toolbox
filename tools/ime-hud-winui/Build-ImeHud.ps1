# Build isolated test-out from sources, stamp it, and run the non-UI self-test.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BuildSupport.ps1')
$output=Join-Path $PSScriptRoot 'test-out'
Invoke-ImeHudBuild -ProjectDir $PSScriptRoot -OutDir $output
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path $output 'ImeHudWinUi.exe';$info.Arguments='--self-test'
$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$process=[Diagnostics.Process]::Start($info)
try {
    if(-not $process.WaitForExit(30000)){$process.Kill();throw 'WinUI self-test timed out'}
    if($process.ExitCode -ne 0){throw "WinUI self-test failed: $($process.ExitCode)"}
} finally {$process.Dispose()}
[Console]::Out.WriteLine('PASS: source-built WinUI self-test (no resident window)')
