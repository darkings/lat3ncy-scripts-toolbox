# Change only this checkout's task action; preserve principal, triggers and settings.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$task=Get-ScheduledTask -TaskName PowerPolicy -ErrorAction Stop
$scriptPath=Join-Path $PSScriptRoot 'PowerPolicy.ps1'
if($task.Actions.Count -ne 1 -or $task.Actions.Arguments -notmatch [regex]::Escape('"'+$scriptPath+'"')){throw 'PowerPolicy task is not bound to this checkout'}
$hostExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher=Join-Path $PSScriptRoot 'Run-PowerPolicy.vbs'
if(-not(Test-Path -LiteralPath $hostExe -PathType Leaf)){throw 'Windows PowerShell host not found'}
$arguments='//B "{0}" "{1}" "{2}"' -f $launcher,$hostExe,$scriptPath
if($task.Actions.Arguments -ne $arguments -or $task.Actions.Execute -ine "$env:SystemRoot\System32\wscript.exe"){
    $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument $arguments
    Set-ScheduledTask -TaskName PowerPolicy -Action $action -ErrorAction Stop | Out-Null
}
$after=Get-ScheduledTask -TaskName PowerPolicy -ErrorAction Stop
if($after.Actions.Arguments -ne $arguments){throw 'Task action readback mismatch'}
[pscustomobject]@{TaskName='PowerPolicy';HostPath=$hostExe;Arguments=$arguments;RunLevel=[string]$after.Principal.RunLevel} | ConvertTo-Json
