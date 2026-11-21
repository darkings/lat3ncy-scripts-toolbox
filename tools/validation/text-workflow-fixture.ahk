#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, StdOut
#Include ..\..\ahk\main.ahk
global panelEvidence := A_Args.Length >= 2 ? A_Args[2] : A_Temp "\lat3ncy-text-workflow.log"
OnError (e, mode) => (FileAppend("error=" e.Message "`n", panelEvidence), ExitApp(1))
class PanelProbeSpeaker {
    static Generation := 0
    static CurrentTask := 0
    static WarmupJob := 0
    static Speaks := 0
    static Stops := 0
    static SpeakText(text) {
        if (text != "你好，工作流。| Hello workflow.`n第二行 😀")
            throw Error("Result text differs")
        this.Generation += 1
        this.CurrentTask := {}
        this.Speaks += 1
        FileAppend "speak=" this.Speaks " chars=" StrLen(text) "`n", panelEvidence
        return this.Generation
    }
    static StopCurrent() {
        this.Generation += 1
        this.CurrentTask := 0
        this.Stops += 1
        FileAppend "stop=" this.Stops "`n", panelEvidence
    }
    static CancelCurrent() {
    }
}
class PanelProbeWorkflow extends TextWorkflow {
    static Speaker() => PanelProbeSpeaker
    static Translator() => PanelProbeSpeaker
}
PanelProbeWorkflow.AllowMessages(A_ScriptHwnd)
OnMessage(TextWorkflow.Message, ObjBindMethod(PanelProbeWorkflow, "OnMessage"))
PanelProbeExit(*) {
    PanelProbeWorkflow.Shutdown()
    TranslationPanel.SendExisting("PANEL|PIN|0")
    TranslationPanel.Close()
    return 0
}
OnExit PanelProbeExit
PanelProbeWorkflow.ContextId := 9001
FileAppend "owner=" A_ScriptHwnd " decimal=" Integer(A_ScriptHwnd) " critical=" A_IsCritical "`n", panelEvidence
TranslationPanel.OpenText("固定测试原文 | Hello workflow.`n此窗口仅验证按钮回传，不播放声音。", 250, 220)
TranslationPanel.SendExisting("PANEL|PIN|1")
PanelProbeWorkflow.Bind(9001)
TranslationPanel.SendExisting("PANEL|SPEAK|result")
Sleep 150
if PanelProbeSpeaker.Speaks
    throw Error("Empty translation can trigger speech")
TranslationPanel.SetResult("你好，工作流。| Hello workflow.`n第二行 😀")
PanelProbeWorkflow.Result(9001, "你好，工作流。| Hello workflow.`n第二行 😀")
TranslationPanel.SendExisting("PANEL|SPEAK|result")
Sleep 250
if (PanelProbeSpeaker.Speaks != 1 || !PanelProbeWorkflow.OwnsSpeech())
    throw Error("First action not delivered")
TranslationPanel.SendExisting("PANEL|SPEAK|result")
Sleep 250
if (PanelProbeSpeaker.Stops != 1 || PanelProbeWorkflow.OwnsSpeech())
    throw Error("Stop action not delivered")
TranslationPanel.Close()
Sleep 250
if PanelProbeWorkflow.ContextId
    throw Error("Close action not delivered")
FileAppend "protocol=passed`n", panelEvidence
if (A_Args.Length >= 3 && A_Args[3] = "--visible") {
    PanelProbeWorkflow.ContextId := 9001
    TranslationPanel.OpenText("固定原文，不播放声音", 250, 220)
    TranslationPanel.SetResult("你好，工作流。| Hello workflow.`n第二行 😀")
    PanelProbeWorkflow.Result(9001, "你好，工作流。| Hello workflow.`n第二行 😀")
    TranslationPanel.SendExisting("PANEL|PIN|1")
    SetTimer(() => ExitApp(0), -180000)
    Persistent true
} else
    ExitApp 0
