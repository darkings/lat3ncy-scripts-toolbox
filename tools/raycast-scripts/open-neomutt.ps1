#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title NeoMutt
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Open the default WSL distro with PowerShell 7+ and run NeoMutt
# @raycast.icon ✉️

$ErrorActionPreference = 'Stop'

trap {
  . (Join-Path $PSScriptRoot '_lib\notify.ps1')
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Raycast 脚本" }
  Show-SystemToast -Title "× $cmdName 执行失败" -Message $_.Exception.Message | Out-Null
  exit 1
}

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) {
    Start-Process -FilePath $wt.Source -ArgumentList 'wsl.exe --cd ~ neomutt'
} else {
    $powerShell = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $powerShellArguments = @(
        '-NoLogo'
        '-NoProfile'
        '-NoExit'
        '-Command'
        'wsl.exe --cd ~ --exec neomutt'
    )
    Start-Process -FilePath $powerShell -ArgumentList $powerShellArguments
}
