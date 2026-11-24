# Read-only hardware admission. Never opens devices, stops processes or alters flags.
param([Parameter(Mandatory=$true)][string]$RgbRoot,
      [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$OwnerPid)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RgbRuntime.ps1')
$status=Test-RgbHardwareAdmission -RgbRoot $RgbRoot -OwnerPid $OwnerPid
if($status -notin @('ok','unknown','foreign','busy')){$status='unknown'}
@{status=$status}|ConvertTo-Json -Compress
