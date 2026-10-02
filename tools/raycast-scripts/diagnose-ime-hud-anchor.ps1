#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Diagnose IME HUD Anchor
# @raycast.mode fullOutput
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Check whether the running IME HUD client is the new anchor-source build
# @raycast.icon 

<#
Diagnose "CN/EN hint does not follow the caret".

Press CapsLock once, then run this script. It answers three questions:

  1. Is the resident ImeHudWinUi.exe the new build or a stale one?
     A stale process never understands the 8th STATE field.
  2. Is ahk/main.ahk running the new client or the old one?
  3. What anchor source did the last toggle actually use (real caret or degraded)?

Read-only. Pass -Restart to also stop the stale HUD and reload AHK.

NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less files
as ANSI, so non-ASCII here breaks parsing (this file has no BOM on purpose:
it must parse under both 5.1 and 7.x).
#>

param(
  [switch]$Restart
)

$ErrorActionPreference = 'Continue'

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hudExe = Join-Path $repo 'tools\ime-hud-winui\out\ImeHudWinUi.exe'
$hudLog = Join-Path $env:TEMP 'ImeHudWinUi.log'
$clientLog = Join-Path $env:TEMP 'ImeHudClient.log'
$restartAhk = Join-Path $PSScriptRoot 'restart-autohotkey.ps1'
$exeTime = (Get-Item -LiteralPath $hudExe -ErrorAction SilentlyContinue).LastWriteTime

function Get-HudProcesses {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ieq 'ImeHudWinUi.exe' })
}

function Get-AhkProcesses {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -like 'AutoHotkey*.exe' -and $_.CommandLine -and
        $_.CommandLine -match 'lat3ncy-scripts-toolbox[\\/]ahk[\\/]'
      })
}

Write-Host '=== 1) HUD process ==='
$hud = Get-HudProcesses
$staleCount = 0
if ($hud.Count -eq 0) {
  Write-Host 'ImeHudWinUi.exe: not running (next CapsLock cold-starts the new exe, that is fine)'
} else {
  foreach ($p in $hud) {
    $stale = [bool]($exeTime -and $p.CreationDate -and ($p.CreationDate -lt $exeTime))
    if ($stale) { $staleCount++ }
    Write-Host ("ImeHudWinUi.exe pid={0} started={1} exeWritten={2} STALE={3}" -f `
      $p.ProcessId, $p.CreationDate, $exeTime, $stale)
  }
  if ($staleCount -gt 0) {
    Write-Host '>> STALE HUD: the exe on disk is newer than the running process.'
    Write-Host '   Run: Stop-Process -Name ImeHudWinUi -Force'
  }
}

Write-Host ''
Write-Host '=== 2) AHK client ==='
$ahk = Get-AhkProcesses
if ($ahk.Count -eq 0) {
  Write-Host 'main.ahk: not detected (may also happen when the query scope is restricted)'
} else {
  foreach ($p in $ahk) {
    Write-Host ("main.ahk pid={0} started={1}" -f $p.ProcessId, $p.CreationDate)
  }
}
if (Test-Path -LiteralPath $clientLog) {
  Write-Host ("client log: {0}" -f $clientLog)
  Get-Content -LiteralPath $clientLog -Tail 8 | ForEach-Object { Write-Host "  $_" }
} else {
  Write-Host 'client log: missing -> AHK is still the OLD client (old code never writes this log)'
  Write-Host '>> reload AHK: powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\raycast-scripts\restart-autohotkey.ps1'
}

Write-Host ''
Write-Host '=== 3) HUD anchor log (current HUD session) ==='
if (-not (Test-Path -LiteralPath $hudLog)) {
  Write-Host ('HUD log missing: {0}' -f $hudLog)
} else {
  $all = @(Get-Content -LiteralPath $hudLog)
  #  HUD  "start pid=" 
  # 
  $sessionStart = 0
  for ($i = $all.Count - 1; $i -ge 0; $i--) {
    if ($all[$i] -match '^start pid=') { $sessionStart = $i; break }
  }
  $session = if ($all.Count -gt 0) { @($all[$sessionStart..($all.Count - 1)]) } else { @() }
  Write-Host ("session start line={0} session lines={1}" -f $sessionStart, $session.Count)
  if ($session.Count -gt 0) { Write-Host ("  {0}" -f $session[0]) }

  $interesting = $session | Select-String -Pattern 'build hud=|hud-message|place |anchor-degraded|move source=|copydata=' |
    Select-Object -Last 12
  foreach ($l in $interesting) { Write-Host ("  {0}" -f $l.Line) }

  $hasBuild = [bool](($session | Select-String -Pattern 'build hud=anchor-source-1' | Measure-Object).Count -gt 0)
  $hasAnchor = [bool](($session | Select-String -Pattern 'hud-message ' | Measure-Object).Count -gt 0)
  $lastPlace = $session | Select-String -Pattern 'place ' | Select-Object -Last 1
  $lastDegraded = $session | Select-String -Pattern 'anchor-degraded' | Select-Object -Last 1
  $lastMove = $session | Select-String -Pattern 'move source=' | Select-Object -Last 1

  Write-Host ''
  Write-Host '=== 4) verdict ==='
  Write-Host ("new HUD build marker (build hud=anchor-source-1): {0}" -f $hasBuild)
  Write-Host ("new protocol log (hud-message ... anchor=):        {0}" -f $hasAnchor)
  if ($lastPlace) { Write-Host ("last placement : {0}" -f $lastPlace.Line) }
  if ($lastDegraded) { Write-Host ("degrade warning: {0}" -f $lastDegraded.Line) }
  if ($lastMove) { Write-Host ("follow move    : {0}" -f $lastMove.Line) }
  else { Write-Host 'follow move    : none (no "move source=" line)' }

  if (-not $hasBuild -or -not $hasAnchor) {
    Write-Host ''
    if ($hud.Count -gt 0) {
      Write-Host '>> A stale HUD process is running. Stop it, then reload AHK:'
    } else {
      Write-Host '>> No resident HUD saw a new-protocol message yet. Reload AHK first, then'
      Write-Host '   press CapsLock once so the new client cold-starts the new HUD:'
    }
    Write-Host '   Stop-Process -Name ImeHudWinUi -Force -ErrorAction SilentlyContinue'
    Write-Host '   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\raycast-scripts\restart-autohotkey.ps1'
    Write-Host '   Then press CapsLock once and run this script again.'
  } elseif ($lastPlace -and ($lastPlace.Line -match 'real=0')) {
    Write-Host ''
    Write-Host '>> New code IS active, but this window reports a DEGRADED anchor: no insertion point'
    Write-Host '   was found, so the chip falls back to the window bottom.'
    Write-Host '   If this is Chromium (Chrome/Edge): add --force-renderer-accessibility to the'
    Write-Host '   browser shortcut, restart the browser, press CapsLock and check whether'
    Write-Host '   anchor= becomes text-caret.'
  } elseif ($lastMove) {
    Write-Host ''
    Write-Host '>> Real caret + follow are both active.'
  }
}

if ($Restart) {
  Write-Host ''
  Write-Host '=== -Restart: delegate to restart-autohotkey.ps1 ==='
  #  ImeHudWinUi.exe  main.ahk  restart-autohotkey.ps1 
  # 
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restartAhk
  Write-Host 'Restart done. Press CapsLock once, then run this script again without -Restart.'
}
