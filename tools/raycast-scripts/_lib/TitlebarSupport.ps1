# Fixed titlebar operation shared by Raycast and the settings worker. ASCII/PS 5.1.
function Get-ToolboxTitlebarPlan {
    param([Parameter(Mandatory=$true)][string]$Repo)
    $python=Get-Command python.exe -ErrorAction Stop
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$python.Source;$info.Arguments='-I -S "'+(Join-Path $Repo 'tools\toolbox_titlebar.py')+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.WorkingDirectory=(Join-Path $Repo 'tools')
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(15000)){throw 'titlebar-config'}
        if($process.ExitCode -ne 0 -or -not $output.Wait(1000) -or $output.Result.Length -gt 8192){throw 'titlebar-config'}
        $plan=$output.Result | ConvertFrom-Json -ErrorAction Stop
        if($plan.status -cne 'ok' -or $plan.version -ne 1){throw 'titlebar-config'}
        return $plan
    }finally{if(-not $process.HasExited){$process.Kill()};$process.Dispose()}
}
function Initialize-ToolboxTitlebarNative {
    if('ToolboxTitlebarNative' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ToolboxTitlebarNative {
 [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h,int a,ref int v,int n);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int a,out int v,int n);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr p);
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@
}
function Get-ToolboxTitlebarWindows {
    Initialize-ToolboxTitlebarNative
    $windows=[Collections.Generic.List[IntPtr]]::new()
    $callback=[ToolboxTitlebarNative+EnumProc]{param($handle,$unused) if([ToolboxTitlebarNative]::IsWindowVisible($handle)){$windows.Add($handle)};return $true}
    if(-not [ToolboxTitlebarNative]::EnumWindows($callback,[IntPtr]::Zero)){throw 'titlebar-enumeration'}
    return $windows.ToArray()
}
function Get-ToolboxTitlebarWindowOwner {
    param([IntPtr]$Handle)
    [uint32]$owner=0;[void][ToolboxTitlebarNative]::GetWindowThreadProcessId($Handle,[ref]$owner);return [int]$owner
}
function Set-ToolboxTitlebarAttribute {
    param([IntPtr]$Handle,[int]$Attribute,[int]$Value)
    return [ToolboxTitlebarNative]::DwmSetWindowAttribute($Handle,$Attribute,[ref]$Value,4)
}
function Read-ToolboxTitlebarAttribute {
    param([IntPtr]$Handle,[int]$Attribute)
    $value=-1;$hr=[ToolboxTitlebarNative]::DwmGetWindowAttribute($Handle,$Attribute,[ref]$value,4)
    return @{Hr=$hr;Value=$value}
}
function Invoke-ToolboxTitlebarPlan {
    param([Parameter(Mandatory=$true)]$Plan,
          [scriptblock]$ProcessProvider,[scriptblock]$WindowProvider,[scriptblock]$OwnerProvider,
          [scriptblock]$IdentityProvider,[scriptblock]$Setter,[scriptblock]$Reader,[scriptblock]$SystemThemeProvider)
    if($Plan.enabled -isnot [bool] -or $Plan.mode -cnotin @('dark','light','system')){throw 'titlebar-config'}
    $names=@($Plan.process_names)
    if($names.Count -gt 32 -or @($names | Where-Object {$_ -isnot [string] -or $_ -cnotmatch '^\w[\w .-]{0,63}$' -or $_ -cne $_.Trim()}).Count -or @($names | ForEach-Object {$_.ToLowerInvariant()} | Select-Object -Unique).Count -ne $names.Count){throw 'titlebar-config'}
    if(-not $Plan.enabled){return @{status='disabled';matched=0;applied=0;failed=0}}
    if(-not $names.Count){return @{status='no_windows';matched=0;applied=0;failed=0}}
    $value=if($Plan.mode -ceq 'dark'){1}else{0}
    if($Plan.mode -ceq 'system'){
        if(-not $SystemThemeProvider){$SystemThemeProvider={(Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme}}
        $light=& $SystemThemeProvider
        if($light -isnot [int] -or $light -notin @(0,1)){throw 'titlebar-system'}
        $value=1-$light
    }
    if(-not $ProcessProvider){$ProcessProvider={param($Names) @(Get-Process -Name $Names -ErrorAction SilentlyContinue)}}
    if(-not $WindowProvider){$WindowProvider={Get-ToolboxTitlebarWindows}}
    if(-not $OwnerProvider){$OwnerProvider={param($Handle) Get-ToolboxTitlebarWindowOwner $Handle}}
    if(-not $IdentityProvider){$IdentityProvider={param($Id) Get-Process -Id $Id -ErrorAction Stop}}
    if(-not $Setter){$Setter={param($Handle,$Attribute,$Value) Set-ToolboxTitlebarAttribute $Handle $Attribute $Value}}
    if(-not $Reader){$Reader={param($Handle,$Attribute) Read-ToolboxTitlebarAttribute $Handle $Attribute}}
    $processes=@();$current=$null;$matched=0;$applied=0;$failed=0
    try {
        $processes=@(& $ProcessProvider $names)
        $targets=@{}
        foreach($process in $processes){
            if($names -inotcontains $process.ProcessName){continue}
            $targets[[int]$process.Id]=$process.StartTime.ToUniversalTime().ToFileTimeUtc()
        }
        if(-not $targets.Count){return @{status='no_windows';matched=0;applied=0;failed=0}}
        foreach($handle in @(& $WindowProvider)){
            $owner=& $OwnerProvider $handle
            if(-not $targets.ContainsKey([int]$owner)){continue}
            $matched++
            try {
                $current=& $IdentityProvider $owner
                if(-not $current -or $current.HasExited -or $names -inotcontains $current.ProcessName -or
                    $current.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $targets[[int]$owner] -or (& $OwnerProvider $handle) -ne $owner){throw 'titlebar-identity'}
                $attribute=20;$hr=& $Setter $handle $attribute $value
                if($hr -ne 0){$attribute=19;$hr=& $Setter $handle $attribute $value}
                if($hr -ne 0){throw 'titlebar-set'}
                $read=& $Reader $handle $attribute
                if($read.Hr -ne 0 -or $read.Value -ne $value -or (& $OwnerProvider $handle) -ne $owner){throw 'titlebar-readback'}
                $applied++
            }catch{$failed++}
            finally{if($current -is [Diagnostics.Process]){$current.Dispose()};$current=$null}
        }
        $status=if($failed){'partial'}elseif($applied){'applied'}else{'no_windows'}
        return @{status=$status;matched=$matched;applied=$applied;failed=$failed}
    }finally{
        if($current -is [Diagnostics.Process]){$current.Dispose()}
        foreach($process in $processes){if($process -is [Diagnostics.Process]){$process.Dispose()}}
    }
}
function Invoke-ToolboxTitlebar {
    param([Parameter(Mandatory=$true)][string]$Repo,[string]$ExpectedRevision='', [string]$Mode='', [string[]]$ProcessNames)
    $plan=Get-ToolboxTitlebarPlan $Repo
    if($ExpectedRevision -and $plan.revision -cne $ExpectedRevision){throw 'titlebar-config-changed'}
    if($Mode){$plan.mode=$Mode}
    if($PSBoundParameters.ContainsKey('ProcessNames')){$plan.process_names=@($ProcessNames | ForEach-Object {$_ -replace '(?i)\.exe$',''})}
    return Invoke-ToolboxTitlebarPlan $plan
}
