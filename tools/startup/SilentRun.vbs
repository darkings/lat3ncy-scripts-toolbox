' SilentRun.vbs - run a command line with no visible window.
' Usage: wscript.exe //B SilentRun.vbs "<full command line>" [nowait]
'   Second argument "nowait" skips waiting for the child to exit.
'   Default waits, so Task Scheduler keeps the task alive until it finishes.
' Kept in the repo so the startup shortcut does not depend on files outside it.
Option Explicit

Dim args, cmd, waitFlag, sh, rc

Set args = WScript.Arguments

If args.Count = 0 Then
    WScript.Quit 1
End If

cmd = args(0)

waitFlag = True
If args.Count >= 2 Then
    If LCase(args(1)) = "nowait" Then waitFlag = False
End If

On Error Resume Next
Set sh = CreateObject("WScript.Shell")
' 0 = hidden window
rc = sh.Run(cmd, 0, waitFlag)
If Err.Number <> 0 Then
    WScript.Quit 2
End If
WScript.Quit 0
