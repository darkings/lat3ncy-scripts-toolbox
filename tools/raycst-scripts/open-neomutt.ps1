#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title NeoMutt
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description 使用 PowerShell 7+ 打开默认 WSL 发行版并运行 NeoMutt
# @raycast.icon ✉️

$ErrorActionPreference = 'Stop'

$powerShell = (Get-Command pwsh.exe -ErrorAction Stop).Source
$powerShellArguments = @(
    '-NoLogo'
    '-NoExit'
    '-Command'
    '"wsl.exe --cd ~ --exec neomutt"'
)

Start-Process -FilePath $powerShell -ArgumentList $powerShellArguments
