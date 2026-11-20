' Hidden launcher which preserves the exit code for Task Scheduler recovery.
Option Explicit
Dim sh, rc, cmd
If WScript.Arguments.Count <> 2 Then WScript.Quit 1
Set sh = CreateObject("WScript.Shell")
cmd = Chr(34) & WScript.Arguments(0) & Chr(34) & _
      " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
      Chr(34) & WScript.Arguments(1) & Chr(34) & " -Run"
On Error Resume Next
rc = sh.Run(cmd, 0, True)
If Err.Number <> 0 Then WScript.Quit 2
WScript.Quit rc
