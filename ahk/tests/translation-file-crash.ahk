#Requires AutoHotkey v2.0
#NoTrayIcon
#Include ..\..\shared\notify\translation-request-files.ahk
if (A_Args.Length != 3 || A_Args[1] != "--test")
    ExitApp 2
root := A_Args[2], repo := A_Args[3]
files := TranslationRequestFiles(root, repo)
FileAppend "fixed private source", files.inputFile
FileAppend "fixed private checkpoint", files.resumeFile
FileAppend "fixed result", files.outputFile
FileAppend "fixed trace", files.outputFile ".trace"
FileAppend "partial fixed checkpoint", files.resumeFile "." TranslationRequestFiles.Nonce() ".tmp"
FileAppend files.id, repo "\crash-ready.txt", "UTF-8-RAW"
; The parent terminates this host. No script exit cleanup is registered.
Persistent true
SetTimer(() => ExitApp(99), -30000)
