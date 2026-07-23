Option Explicit

Dim shell, fileSystem, scriptDirectory, ocrScript, command, launchError

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
ocrScript = fileSystem.BuildPath(scriptDirectory, "screenshot_ocr.py")

If Not fileSystem.FileExists(ocrScript) Then
    MsgBox "Screenshot OCR script was not found:" & vbCrLf & ocrScript, vbCritical, "Screenshot OCR"
    WScript.Quit 1
End If

If WScript.Arguments.Named.Exists("validate") Then
    WScript.Echo "script=" & ocrScript
    WScript.Quit 0
End If

On Error Resume Next

command = "pythonw.exe " & Chr(34) & ocrScript & Chr(34)
shell.Run command, 0, False
launchError = Err.Number

If launchError <> 0 Then
    Err.Clear
    command = "pyw.exe " & Chr(34) & ocrScript & Chr(34)
    shell.Run command, 0, False
    launchError = Err.Number
End If

On Error GoTo 0

If launchError <> 0 Then
    MsgBox "Unable to start Screenshot OCR. Ensure pythonw.exe or pyw.exe is available on PATH.", vbCritical, "Screenshot OCR"
    WScript.Quit 1
End If
