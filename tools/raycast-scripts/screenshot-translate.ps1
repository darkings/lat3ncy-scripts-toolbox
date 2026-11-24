#!/usr/bin/env pwsh
# @raycast.schemaVersion 1
# @raycast.title Screenshot Translate
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Capture a region, translate it, then optionally read the translation
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '_lib\settings.ps1')
if(-not(Test-ToolboxRaycastCommandEnabled -Command 'screenshot-translate')){exit 0}
. (Join-Path $PSScriptRoot '..\startup\ToolboxProcess.ps1')
. (Join-Path $PSScriptRoot '_lib\notify.ps1')
try {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ToolboxTextCommand {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll",EntryPoint="PostMessageW")] public static extern bool Post(IntPtr hwnd,uint message,IntPtr request,IntPtr action);
}
'@
    $repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $title='Lat3ncyToolboxText-'+(Get-ToolboxInstanceHash $repo)
    $window=[ToolboxTextCommand]::FindWindow('AutoHotkeyGUI',$title)
    if($window -eq [IntPtr]::Zero -or -not [ToolboxTextCommand]::Post($window,(0x8000+76),[IntPtr]::Zero,[IntPtr]::Zero)) {
        throw 'Reload or start this toolbox before using Screenshot Translate'
    }
} catch {
    Show-SystemToast -Title 'Screenshot Translate unavailable' -Message 'Start or reload this toolbox, then try again.' | Out-Null
}
