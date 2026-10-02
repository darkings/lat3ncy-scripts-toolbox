#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Force Dark Titlebar (engine windows)
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Force or clear the immersive dark titlebar on Tencent Androws engine windows

<#
Tencent Androws (应用宝引擎) windows are Qt windows (class Qt5152QWindowIcon).
Their title bar is painted by DWM and follows the SYSTEM app theme by default,
unless the app pins it with DWMWA_USE_IMMERSIVE_DARK_MODE. Qt pins it in some
builds, which is why the title bar can ignore light/dark switching.

This applies the DWM attribute to the engine's existing top-level windows:

    Force-DarkTitlebar.ps1           -> force dark titlebar
    Force-DarkTitlebar.ps1 -Light    -> force light titlebar
    Force-DarkTitlebar.ps1 -Reset    -> clear the pin (follow system again)

It only touches the listed process names; run it again after restarting the
engine. Read-back verifies the attribute actually stuck.

ASCII only on purpose (PowerShell 5.1 parses BOM-less files as ANSI).
#>

param(
  [switch]$Light,
  [switch]$Reset,
  [string[]]$ProcessNames = @('Androws', 'AndrowsStore', 'AndrowsAssistant', 'AndrowsLauncher')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { 'Force Dark Titlebar' }
  Show-SystemToast -Title "x $cmdName failed" -Message $_.Exception.Message | Out-Null
  exit 1
}

if (-not ('L3Titlebar' -as [type])) {
  Add-Type -Namespace L3 -Name Titlebar -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
public delegate bool EnumProc(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
'@
}

# DWMWA_USE_IMMERSIVE_DARK_MODE: 20 on Win10 2004+/Win11, 19 on older builds.
$ATTR = 20

function Set-TitlebarDark {
  param([IntPtr]$Handle, [int]$Value)
  $v = $Value
  $hr = [L3.Titlebar]::DwmSetWindowAttribute($Handle, $ATTR, [ref]$v, 4)
  if ($hr -ne 0) {
    $hr = [L3.Titlebar]::DwmSetWindowAttribute($Handle, 19, [ref]$v, 4)
  }
  $read = -1
  [void][L3.Titlebar]::DwmGetWindowAttribute($Handle, $ATTR, [ref]$read, 4)
  return @{ SetHr = $hr; ReadBack = $read }
}

$wanted = if ($Reset) { $null } elseif ($Light) { 0 } else { 1 }

$targetPids = @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
if ($targetPids.Count -eq 0) {
  throw ('engine is not running: ' + ($ProcessNames -join ', '))
}

$touched = 0
$counter = @{ N = 0 }   # hashtable 是引用类型，回调里才能累加（$script: 在回调里不可靠）
$results = New-Object System.Collections.Generic.List[string]
$cb = [L3.Titlebar+EnumProc]{
  param($h, $p)
  if (-not [L3.Titlebar]::IsWindow($h) -or -not [L3.Titlebar]::IsWindowVisible($h)) { return $true }
  $ownerPid = 0
  [void][L3.Titlebar]::GetWindowThreadProcessId($h, [ref]$ownerPid)
  if ($targetPids -notcontains ([int]$ownerPid)) { return $true }

  $cls = New-Object System.Text.StringBuilder 256
  [void][L3.Titlebar]::GetClassNameW($h, $cls, 256)
  $title = New-Object System.Text.StringBuilder 512
  [void][L3.Titlebar]::GetWindowTextW($h, $title, 512)

  if ($Reset) {
    # No documented "clear" value; putting the system's current value back is
    # the practical equivalent (the app pinned it, we restore the default).
    $systemDark = 0
    try {
      $systemDark = 1 - (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme).AppsUseLightTheme
    } catch { $systemDark = 1 }
    $outcome = Set-TitlebarDark -Handle $h -Value $systemDark
  } else {
    $outcome = Set-TitlebarDark -Handle $h -Value $wanted
  }

  $counter.N++
  $touched = $counter.N
  $results.Add(("pid={0} class={1} title='{2}' hr={3} readback={4}" -f `
    $ownerPid, $cls.ToString(), $title.ToString(), $outcome.SetHr, $outcome.ReadBack))
  return $true
}
[void][L3.Titlebar]::EnumWindows($cb, [IntPtr]::Zero)
$touched = $counter.N

if ($touched -eq 0) {
  throw 'no visible engine window found (open the store window first)'
}

$mode = if ($Reset) { 'system' } elseif ($Light) { 'light' } else { 'dark' }
$message = ("titlebar={0} on {1} window(s): {2}" -f $mode, $touched, (($results | Select-Object -First 3) -join ' | '))
Show-SystemToast -Title 'OK engine titlebar updated' -Message $message | Out-Null
