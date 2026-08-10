#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Restart AutoHotkey
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description 结束工具箱 main.ahk 进程并重新加载
# @raycast.icon 🔄

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mainScript = Join-Path $repositoryRoot 'ahk\main.ahk'

if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    throw "AutoHotkey entry script not found: $mainScript"
}

$resolvedMainScript = (Resolve-Path -LiteralPath $mainScript).Path
$escapedMainScript = [Regex]::Escape($resolvedMainScript)
$toolboxPathPattern = 'lat3ncy-scripts-toolbox[\\/]ahk[\\/]main\.ahk'

function Get-ToolboxAutoHotkeyProcess {
    @(Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -like 'AutoHotkey*.exe' -and
            $_.CommandLine -and
            ($_.CommandLine -match $escapedMainScript -or $_.CommandLine -match $toolboxPathPattern)
        })
}

$toolboxProcesses = Get-ToolboxAutoHotkeyProcess

foreach ($process in $toolboxProcesses) {
    Stop-Process -Id $process.ProcessId -Force
}

if ($toolboxProcesses) {
    Start-Sleep -Milliseconds 200
}

$autoHotkey = (Get-Command AutoHotkey.exe -ErrorAction Stop).Source
$workingDirectory = Split-Path $resolvedMainScript -Parent
$mainScriptArgument = '"{0}"' -f $resolvedMainScript

Start-Process `
    -FilePath $autoHotkey `
    -ArgumentList $mainScriptArgument `
    -WorkingDirectory $workingDirectory

Start-Sleep -Milliseconds 800
$reloadedProcesses = Get-ToolboxAutoHotkeyProcess

if (-not $reloadedProcesses) {
    throw 'AutoHotkey main.ahk process was not detected after launch'
}

$processIds = ($reloadedProcesses.ProcessId | Sort-Object -Unique) -join ', '
Write-Output "AutoHotkey reloaded successfully (PID: $processIds)"
