# Offline recovery tests: Native and powercfg below are fakes, never system APIs.
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('toolbox-recovery-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'PowerPolicy.ps1') -LibraryOnly -LogPath (Join-Path $testRoot 'test.log')
function Write-Log($Message) {}
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL: $Label" } }
$script:FeatureEnabled=$true
function Test-PowerPolicyFeatureEnabled { return $script:FeatureEnabled }
Add-Type @'
using System;
using System.IO;
using System.Collections.Generic;
namespace ToolboxPower {
 public static class Native {
  public static Dictionary<string,uint[]> Values = new Dictionary<string,uint[]>();
  public static string BackupPath;
  public static int ReleaseCalls, HoldCalls, RequestBalance;
  public static object GetSnapshot(){return new {ResetVersion=0,Lid=0,LidCallbacks=0,PowerCallbacks=0,DisplayCallbacks=0};}
  public static string[] DrainEvents(){return new string[0];}
  public static string PowerSource(){return "AC";}
  public static bool Hold(bool reset){HoldCalls++;RequestBalance=1;return true;}
  public static void Release(){ReleaseCalls++;RequestBalance=0;}
  public static Guid ActiveScheme(){return Guid.Parse("11111111-1111-1111-1111-111111111111");}
  public static uint Read(Guid s,Guid g,Guid k,bool ac){return Values[k.ToString()][ac?0:1];}
  public static void Write(Guid s,Guid g,Guid k,bool ac,uint value){
   if(!File.Exists(BackupPath)) throw new Exception("write before backup");
   Values[k.ToString()][ac?0:1]=value;
  }
  public static void Activate(Guid scheme){}
 }
}
'@

$script:Calls = @()
$script:FailDevice = ''
function powercfg {
    param($Action, $Device)
    $global:LASTEXITCODE = 0
    $script:Calls += "$Action|$Device"
    if ($Action -eq '/devicequery') { return 'ReviewDevice' }
    if ($Action -eq '/devicedisablewake') {
        $journal = Get-Content -LiteralPath $script:WakeDisabledStatePath -Raw | ConvertFrom-Json
        Assert ($journal.devices -contains $Device) 'journal must precede device disable'
    }
    if ($Action -eq '/deviceenablewake' -and $Device -eq $script:FailDevice) { $global:LASTEXITCODE = 1 }
}

try {
    $encodingPath=Join-Path $testRoot 'encoding.json'
    $unicodeName=([string][char]0x8BBE)+([string][char]0x5907)
    Write-AtomicJson @{name=$unicodeName} $encodingPath
    $bytes=[IO.File]::ReadAllBytes($encodingPath)
    Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'JSON encoding is BOM-stable on both hosts'
    Assert (((Get-Content -LiteralPath $encodingPath -Raw -Encoding UTF8 | ConvertFrom-Json).name) -eq $unicodeName) 'Unicode device names round-trip'
    $scheme=[ToolboxPower.Native]::ActiveScheme()
    $backupPath=Join-Path $testRoot "power-policy-backup-$scheme.json"
    [ToolboxPower.Native]::BackupPath=$backupPath
    foreach($name in $script:SettingDefinitions.Keys){
        $key=$script:SettingDefinitions[$name][1]
        [ToolboxPower.Native]::Values[$key]=[uint32[]]@(11,22)
    }
    $rtc=$script:SettingDefinitions['RTCWAKE'][1]
    [ToolboxPower.Native]::Values[$rtc]=[uint32[]]@(2,1)
    # Existing backups must not lose their earlier LIDACTION baseline on migration.
    Write-AtomicJson @{scheme="$scheme";values=@{LIDACTION=@(7,8)}} $backupPath
    $WakeDisableDevices=$false; $WakeDisableTimers=$true; $DryRun=$false
    Invoke-WakeBlock
    $backup=Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    Assert (($backup.values.RTCWAKE -join ',') -eq '2,1') 'wake timer baseline captured before disable'
    Assert (($backup.values.LIDACTION -join ',') -eq '7,8') 'old baseline preserved'
    Assert (([ToolboxPower.Native]::Values[$rtc] -join ',') -eq '0,0') 'timer policy applied'
    Restore-OriginalPowerPolicies
    Assert (([ToolboxPower.Native]::Values[$rtc] -join ',') -eq '2,1') 'timer baseline restored'
    $WakeDisableTimers=$false
    Invoke-WakeBlock
    Assert (([ToolboxPower.Native]::Values[$rtc] -join ',') -eq '2,1') 'timer config opt-out respected'
    $WakeDisableTimers=$true; $DryRun=$true
    Invoke-WakeBlock
    Assert (([ToolboxPower.Native]::Values[$rtc] -join ',') -eq '2,1') 'timer DryRun is read-only'
    $DryRun=$false

    $script:FeatureEnabled=$false; $script:Calls=@()
    $WakeDisableDevices=$true
    Invoke-WakeBlock
    Assert ($script:Calls.Count -eq 0) 'disabled feature skips device reads and writes'
    Assert (([ToolboxPower.Native]::Values[$rtc] -join ',') -eq '2,1') 'disabled feature skips timer writes'
    $script:ResidentIdentity=@{}; $script:LastStatusSignature=''
    $script:LastStatusUtc=[DateTime]::MinValue; $script:LastTickUtc=$null
    $script:MaxLoopGapSeconds=0; $script:LargeLoopGapCount=0
    function Test-CaffeineActive { throw 'disabled module must not read Caffeine input' }
    [ToolboxPower.Native]::RequestBalance=1
    Invoke-PowerPolicyTick
    Assert ([ToolboxPower.Native]::ReleaseCalls -eq 1) 'disabled tick releases the existing hold'
    Assert ([ToolboxPower.Native]::HoldCalls -eq 0) 'disabled tick never requests a new hold'
    $beat=Get-Content -LiteralPath $script:StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert (-not $beat.moduleEnabled -and -not $beat.caffeine -and $beat.requestBalance -eq 0) 'disabled tick still publishes a paused heartbeat'
    Assert (([ToolboxPower.Native]::Values[$rtc] -join ',') -eq '2,1') 'disabled tick preserves system policies'
    $script:FeatureEnabled=$true

    $WakeDisableDevices=$true; $WakeDisableTimers=$false; $WakeWhitelist=@()
    Invoke-WakeBlock
    Assert ($script:Calls -contains '/devicedisablewake|ReviewDevice') 'device disabled after journaling'
    Save-DisabledWakeDevices @('OtherDevice')
    $script:FailDevice='ReviewDevice'
    $threw=$false
    try { Restore-DisabledWakeDevices } catch { $threw=$true }
    Assert $threw 'partial restore reports failure'
    $remaining=Get-Content -LiteralPath $script:WakeDisabledStatePath -Raw | ConvertFrom-Json
    Assert (($remaining.devices -join ',') -eq 'ReviewDevice') 'failed device retained, successful device removed'
    $script:FailDevice=''
    Restore-DisabledWakeDevices
    Assert (-not (Test-Path -LiteralPath $script:WakeDisabledStatePath)) 'successful retry removes journal'

    $blocked=Join-Path $testRoot 'blocked'
    Set-Content -LiteralPath $blocked -Value 'not a directory'
    $script:WakeDisabledStatePath=Join-Path $blocked 'journal.json'
    $script:Calls=@(); $threw=$false
    try { Invoke-WakeBlock } catch { $threw=$true }
    Assert $threw 'journal I/O failure aborts disable'
    Assert (-not ($script:Calls -contains '/devicedisablewake|ReviewDevice')) 'no device write without recovery log'

    $script:WakeDisabledStatePath=Join-Path $testRoot 'corrupt.json'
    Set-Content -LiteralPath $script:WakeDisabledStatePath -Value '{'
    $script:Calls=@(); $threw=$false
    try { Invoke-WakeBlock } catch { $threw=$true }
    Assert $threw 'corrupt recovery log is never overwritten'
    Assert (-not ($script:Calls -contains '/devicedisablewake|ReviewDevice')) 'corrupt log prevents device mutation'
    Set-Content -LiteralPath $script:WakeDisabledStatePath -Value '{}'
    $threw=$false
    try { Restore-DisabledWakeDevices } catch { $threw=$true }
    Assert $threw 'missing devices field reports invalid recovery log'
    Assert (Test-Path -LiteralPath $script:WakeDisabledStatePath) 'invalid recovery log retained'
    [Console]::Out.WriteLine('PASS: offline power recovery tests')
} finally {
    # The test creates only files in its own unique directory, never system state.
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
