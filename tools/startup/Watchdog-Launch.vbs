' Watchdog-Launch.vbs - run Ensure-ToolboxRunning.ps1 with no visible window.
' Used by the Lat3ncyToolbox-Watchdog scheduled task. No arguments, no nested quotes.
Option Explicit

Dim fso, here, ps, script, sh

Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)          ' ...\tools\startup
ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
script = fso.BuildPath(here, "Ensure-ToolboxRunning.ps1")

Set sh = CreateObject("WScript.Shell")
sh.Run """" & ps & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, True
