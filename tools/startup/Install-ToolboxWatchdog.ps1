# Install-ToolboxWatchdog.ps1
# Register/update the Lat3ncyToolbox-Watchdog task: runs at logon and every 5 minutes,
# starts ahk/main.ahk when it is not running. The task launches a no-argument VBS
# (Watchdog-Launch.vbs) so no console window is allocated and no nested quoting is needed.
# Idempotent. Requires an elevated shell (task registration is denied otherwise).
#
# ASCII only on purpose (PowerShell 5.1 parses BOM-less files as ANSI).

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$watchdogVbs = Join-Path $PSScriptRoot 'Watchdog-Launch.vbs'
$ensureScript = Join-Path $PSScriptRoot 'Ensure-ToolboxRunning.ps1'
$taskName = 'Lat3ncyToolbox-Watchdog'

foreach ($p in @($watchdogVbs, $ensureScript)) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
    throw "Missing file: $p"
  }
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B "{0}"' -f $watchdogVbs)

# Trigger: once at logon, then every 5 minutes for a long horizon.
$logon = New-ScheduledTaskTrigger -AtLogOn
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) `
  -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
  -Hidden `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
  -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logon, $repeat) `
  -Settings $settings -Principal $principal `
  -Description 'Lat3ncy Toolbox - start main.ahk when it is not running' -Force | Out-Null

Write-Host "Registered: $taskName"
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName,State | Format-Table -AutoSize
Write-Host ("Log: " + (Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\startup.log'))
