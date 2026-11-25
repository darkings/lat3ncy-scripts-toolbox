param([string]$Path,[ValidateSet('Screenshot','Record')][string]$Mode)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CaptureRuntime.ps1')
if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'recent_file_missing'}
Copy-CaptureFileToClipboard -Path $Path -Mode $Mode
