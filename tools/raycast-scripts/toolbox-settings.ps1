#!/usr/bin/env pwsh
# @raycast.schemaVersion 1
# @raycast.title Toolbox Settings
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Settings for translation, speech, OCR, audio, theme, power and ambient light
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$renderer=Join-Path $repo 'tools\ime-hud-winui\out\ImeHudWinUi.exe'
if(-not (Test-Path -LiteralPath $renderer -PathType Leaf)) {
    throw 'Deploy the toolbox before opening settings.'
}
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=$renderer
$start.Arguments='--settings'
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$process=[Diagnostics.Process]::Start($start)
# Forwarding instances exit themselves; the first instance remains resident.
# Neither case needs a shell launch or a blocking Raycast wait.
$process.Dispose()
