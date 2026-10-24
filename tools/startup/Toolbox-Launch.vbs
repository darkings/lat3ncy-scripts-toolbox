' Toolbox-Launch.vbs - start the toolbox (Start-Toolbox.ps1) with no visible window.
' Used by the Startup shortcut. No arguments: all paths are derived from this file,
' so the shortcut never has to carry nested quotes.
Option Explicit

Dim fso, here, repo, ps, script, sh

Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)          ' ...\tools\startup
repo = fso.GetParentFolderName(fso.GetParentFolderName(here))    ' repo root
ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
script = fso.BuildPath(here, "Start-Toolbox.ps1")

Set sh = CreateObject("WScript.Shell")
sh.Run """" & ps & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
