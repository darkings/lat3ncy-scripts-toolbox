# Runtime operations are deliberately separate from the file transaction tests.
. (Join-Path $PSScriptRoot 'ToolboxProcess.ps1')

function Invoke-ToolboxReleaseProcess {
    param([string]$Exe,[string[]]$Arguments,[int]$TimeoutMs=30000)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Exe
    $info.Arguments=($Arguments | ForEach-Object {ConvertTo-ToolboxCommandLineArgument $_}) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    try {
        if(-not $process.WaitForExit($TimeoutMs)){$process.Kill();throw "Process timed out: $Exe"}
        if($process.ExitCode -ne 0){throw "Process exited $($process.ExitCode): $Exe $($stdout.Result) $($stderr.Result)"}
    } finally {$process.Dispose()}
}

function Get-ToolboxReleaseRuntime {
    param([string]$Repo)
    $main=Join-Path $Repo 'ahk\main.ahk';$exe=Join-Path $Repo 'tools\ime-hud-winui\out\ImeHudWinUi.exe'
    $ahk=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -like 'AutoHotkey*.exe' -and (Test-ToolboxMainScriptCommandLine $_.CommandLine $main)
    })
    $hud=@(Get-Process -Name ImeHudWinUi -ErrorAction SilentlyContinue | Where-Object {$_.Path -ieq $exe})
    if($ahk.Count -gt 1 -or $hud.Count -gt 1){throw 'Multiple production instances; refusing ambiguous deployment'}
    if(-not $ahk.Count -and (Get-ToolboxInstanceMarkerState $main) -ne 'absent'){
        throw 'AHK instance exists but its process identity is unreadable'
    }
    return [pscustomobject]@{Ahk=$ahk;Hud=$hud}
}

function Initialize-ToolboxHudProbe {
    if('ToolboxReleaseHudProbe' -as [type]){return}
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ToolboxReleaseHudProbe {
 [StructLayout(LayoutKind.Sequential)] public struct CopyData { public IntPtr Id; public int Size; public IntPtr Data; }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,IntPtr wp,ref CopyData data,uint flags,uint timeout,out IntPtr result);
 public static int Owner() {
  IntPtr hwnd=FindWindow("Lat3ncyImeHudWinUi","Lat3ncyImeHudWinUi");uint pid;
  if(hwnd==IntPtr.Zero)return 0;GetWindowThreadProcessId(hwnd,out pid);return (int)pid;
 }
 public static bool Ping(int expectedPid) {
  IntPtr hwnd=FindWindow("Lat3ncyImeHudWinUi","Lat3ncyImeHudWinUi");uint pid;
  if(hwnd==IntPtr.Zero)return false;
  GetWindowThreadProcessId(hwnd,out pid);if(pid!=expectedPid)return false;
  IntPtr buffer=Marshal.StringToHGlobalUni("PING");
  try {CopyData data=new CopyData{Id=new IntPtr(1),Size=10,Data=buffer};IntPtr result;
   return SendMessageTimeout(hwnd,0x4a,IntPtr.Zero,ref data,2,2500,out result)!=IntPtr.Zero&&result!=IntPtr.Zero;
  } finally {Marshal.FreeHGlobal(buffer);}
 }
}
'@
}

function Stop-ToolboxReleaseRuntime {
    param([string]$Repo)
    $runtime=Get-ToolboxReleaseRuntime $Repo
    Initialize-ToolboxHudProbe
    $owner=[ToolboxReleaseHudProbe]::Owner()
    if($owner -ne 0 -and $owner -notin @($runtime.Hud | ForEach-Object {$_.Id})){
        throw 'HUD window belongs to another checkout; refusing to stop it'
    }
    foreach($proc in $runtime.Ahk){
        $live=Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ProcessId)" -ErrorAction Stop
        if(-not $live -or $live.CreationDate -ne $proc.CreationDate -or
           -not(Test-ToolboxMainScriptCommandLine $live.CommandLine (Join-Path $Repo 'ahk\main.ahk'))){throw 'AHK identity changed'}
        $process=Get-Process -Id $proc.ProcessId -ErrorAction Stop
        try {Stop-Process -InputObject $process -Force -ErrorAction Stop
            if(-not $process.WaitForExit(5000)){throw 'AHK did not exit'}
        } finally {$process.Dispose()}
    }
    foreach($hud in $runtime.Hud){
        try {
            Invoke-ToolboxReleaseProcess $hud.Path @('--quit') 10000
            if(-not $hud.WaitForExit(5000)){$hud.Kill();if(-not $hud.WaitForExit(3000)){throw 'HUD did not exit'}}
        } finally {$hud.Dispose()}
    }
}

function Start-ToolboxReleaseRuntime {
    param([string]$Repo)
    $hostExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Invoke-ToolboxReleaseProcess $hostExe @('-NoProfile','-ExecutionPolicy','Bypass','-File',
        (Join-Path $Repo 'tools\startup\Start-Toolbox.ps1'),'-NoToast','-MaxAttempts','1','-StartupWaitSeconds','15')
}

function Test-ToolboxReleaseRuntime {
    param([string]$Repo,[int]$WaitSeconds=15)
    Initialize-ToolboxHudProbe
    $deadline=[DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $runtime=Get-ToolboxReleaseRuntime $Repo
        if($runtime.Ahk.Count -eq 1 -and $runtime.Hud.Count -eq 1 -and
           (Get-ToolboxInstanceMarkerState (Join-Path $Repo 'ahk\main.ahk')) -eq 'present' -and
           [ToolboxReleaseHudProbe]::Ping($runtime.Hud[0].Id)){
            $helperPath=Join-Path $Repo 'shared\notify\caret-uia.ps1'
            $helpers=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                $_.Name -eq 'powershell.exe' -and (Test-ToolboxScriptCommandLine $_.CommandLine $helperPath)
            })
            if($helpers.Count -eq 1 -and $helpers[0].CommandLine -match ('(?:^|\s)-OwnerPid '+$runtime.Ahk[0].ProcessId+'(?:\s|$)')){
                return [pscustomobject]@{AhkPid=$runtime.Ahk[0].ProcessId;HudPid=$runtime.Hud[0].Id;HudPing=$true;CaretPid=$helpers[0].ProcessId;VerifiedUtc=[DateTime]::UtcNow.ToString('o')}
            }
        }
        Start-Sleep -Milliseconds 300
    } while([DateTime]::UtcNow -lt $deadline)
    throw 'AHK marker / HUD PING / caret owner health check failed'
}
