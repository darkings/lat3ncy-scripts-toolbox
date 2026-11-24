# Read-only RGB ownership and serialized control operations. ASCII for PS 5.1.
. (Join-Path $PSScriptRoot '..\startup\ToolboxProcess.ps1')

function Get-RgbValue($Object,[string]$Name) {
    if($null -eq $Object){return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}
function ConvertTo-RgbPath([string]$Path) {
    if(-not $Path -or -not [IO.Path]::IsPathRooted($Path)){throw 'rgb-relative-path'}
    return [IO.Path]::GetFullPath($Path).Replace('/','\').TrimEnd('\').ToLowerInvariant()
}
function Get-RgbArguments([string]$CommandLine) {
    if(-not $CommandLine -or $CommandLine.Length -gt 32768){throw 'rgb-command-unavailable'}
    if(-not ('Lat3ncyRgbArguments' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Lat3ncyRgbArguments {
 [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CommandLineToArgvW(string value,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
 public static string[] Split(string value) {
  int count; IntPtr data=CommandLineToArgvW(value,out count);
  if(data==IntPtr.Zero) throw new InvalidOperationException("rgb-command-unavailable");
  try {
   if(count<1 || count>256) throw new InvalidOperationException("rgb-command-unavailable");
   var result=new string[count];
   for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(data,i*IntPtr.Size));
   return result;
  } finally {LocalFree(data);}
 }
}
'@
    }
    return [Lat3ncyRgbArguments]::Split($CommandLine)
}
function Get-RgbPythonScript([string[]]$Arguments) {
    for($i=1;$i -lt $Arguments.Count;$i++){
        $value=$Arguments[$i]
        if($value -ceq '-c' -or $value -ceq '-m'){return $null}
        if($value -ceq '--'){
            if($i+1 -ge $Arguments.Count){return $null};return $Arguments[$i+1]
        }
        if($value -in @('-W','-X','--check-hash-based-pycs')){$i++;continue}
        if($value -in @('-u','-I','-S','-B','-E','-s','-O','-OO','-q','-P','-b','-bb','-v')){continue}
        if($value.StartsWith('-')){throw 'rgb-python-options'}
        return $value
    }
    return $null
}
function Assert-RgbFileHostArguments([string[]]$Arguments,[int]$FileIndex) {
    for($i=1;$i -lt $FileIndex;$i++){
        if($Arguments[$i] -in @('-NoProfile','-NonInteractive','-NoLogo')){continue}
        if($Arguments[$i] -in @('-ExecutionPolicy','-WindowStyle')){
            $option=$Arguments[$i];$i++
            if($i -ge $FileIndex){throw 'rgb-host-options'}
            if($option -ieq '-WindowStyle' -and $Arguments[$i] -ine 'Hidden'){throw 'rgb-host-options'}
            if($option -ieq '-ExecutionPolicy' -and $Arguments[$i] -notin @('Bypass','RemoteSigned')){throw 'rgb-host-options'}
            continue
        }
        throw 'rgb-host-options'
    }
}
function Get-RgbProcessSnapshot {
    param([Parameter(Mandatory=$true)][string]$RgbRoot,[scriptblock]$ProcessProvider,[scriptblock]$IdentityProvider)
    if(-not $ProcessProvider){$ProcessProvider={@(Get-CimInstance Win32_Process -ErrorAction Stop)}}
    if(-not $IdentityProvider){$IdentityProvider={param($Id) Get-ToolboxProcessStartIdentity -ProcessId $Id}}
    $owned=[Collections.Generic.List[object]]::new();$foreign=$false;$unknown=$false
    $root=ConvertTo-RgbPath $RgbRoot;$scriptPath=ConvertTo-RgbPath (Join-Path $RgbRoot 'ambient.py')
    $startPath=ConvertTo-RgbPath (Join-Path $RgbRoot 'Start-Ambient.ps1')
    $dist=$root+'\dist\'
    try {$all=@(& $ProcessProvider)}catch{return [pscustomobject]@{Status='unknown';Processes=@()}}
    # Python first, so child helper ownership can be tied to a verified parent.
    $ordered=@($all | Where-Object {(Get-RgbValue $_ 'Name') -in @('python.exe','pythonw.exe')})+
        @($all | Where-Object {(Get-RgbValue $_ 'Name') -notin @('python.exe','pythonw.exe')})
    foreach($process in $ordered){
        $name=[string](Get-RgbValue $process 'Name');$role='';$mine=$false
        try {
            if($name -in @('python.exe','pythonw.exe')){
                $arguments=@(Get-RgbArguments ([string](Get-RgbValue $process 'CommandLine')))
                $script=Get-RgbPythonScript $arguments
                if(-not $script -or [IO.Path]::GetFileName($script) -ine 'ambient.py'){continue}
                $mine=(ConvertTo-RgbPath $script) -ceq $scriptPath
                $observer=$arguments -ccontains '--dry-run' -or @($arguments | Where-Object {$_ -ceq '--bench' -or $_.StartsWith('--bench=')}).Count -gt 0
                if($observer -and -not $mine){continue}
                $role=if($observer){'observer'}elseif($arguments -ccontains '--lights-off' -or $arguments -ccontains '--list-devices'){'once'}else{'ambient'}
            }elseif($name -ieq 'hi75.exe'){
                $path=ConvertTo-RgbPath ([string](Get-RgbValue $process 'ExecutablePath'))
                $mine=$path.StartsWith($dist,[StringComparison]::Ordinal) -and [IO.Path]::GetFileName($path) -ieq 'hi75.exe'
                if(-not $mine){
                    $parentId=Get-RgbValue $process 'ParentProcessId'
                    $parent=@($owned | Where-Object {$_.Role -in @('ambient','once') -and $_.ProcessId -eq $parentId})
                    if($parent.Count -eq 1){
                        $identity=& $IdentityProvider $parentId
                        $mine=$identity.Status -eq 'present' -and [string]$identity.StartTicks -ceq $parent[0].StartTicks -and
                            ([datetime](Get-RgbValue $process 'CreationDate')).ToUniversalTime().ToFileTimeUtc() -ge [long]$parent[0].StartTicks
                    }
                }
                $role='hi75'
            }elseif($name -in @('powershell.exe','pwsh.exe')){
                # An unreadable arbitrary PowerShell host is never a kill target.
                $line=[string](Get-RgbValue $process 'CommandLine');if(-not $line){continue}
                $arguments=@(Get-RgbArguments $line);$index=[Array]::IndexOf($arguments,'-File')
                if($index -lt 0){$index=[Array]::IndexOf($arguments,'-file')}
                if(@($arguments | Where-Object {$_ -in @('-Command','-c','-EncodedCommand','-enc','-e')}).Count){continue}
                if($index -lt 0 -or $index+1 -ge $arguments.Count -or [IO.Path]::GetFileName($arguments[$index+1]) -ine 'Start-Ambient.ps1'){continue}
                Assert-RgbFileHostArguments $arguments $index
                $mine=(ConvertTo-RgbPath $arguments[$index+1]) -ceq $startPath;$role='waiter'
            }else{continue}
            if(-not $mine){$foreign=$true;continue}
            $id=[int](Get-RgbValue $process 'ProcessId');if($id -eq $PID){continue}
            $identity=& $IdentityProvider $id
            if($identity.Status -eq 'absent'){continue}
            $creation=Get-RgbValue $process 'CreationDate'
            if(-not $creation -or $identity.Status -ne 'present' -or $identity.Name -ine [IO.Path]::GetFileNameWithoutExtension($name) -or
                [long]::Parse([string]$identity.StartTicks) -le 0 -or
                [Math]::Floor([decimal]$identity.StartTicks/10) -ne [Math]::Floor([decimal]([datetime]$creation).ToUniversalTime().ToFileTimeUtc()/10)){
                throw 'rgb-process-identity'
            }
            $owned.Add([pscustomobject]@{ProcessId=$id;Name=$name;Role=$role;StartTicks=[string]$identity.StartTicks;ParentProcessId=(Get-RgbValue $process 'ParentProcessId')})
        }catch{$unknown=$true}
    }
    $status=if($unknown){'unknown'}elseif($foreign){'foreign'}elseif($owned.Count){'running'}else{'absent'}
    return [pscustomobject]@{Status=$status;Processes=@($owned.ToArray())}
}
function Assert-RgbSnapshot {
    param($Snapshot,[ValidateSet('Start','Stop','Toggle','Install')][string]$Operation)
    if($Snapshot.Status -eq 'unknown'){throw 'rgb-metadata-unavailable'}
    if($Snapshot.Status -eq 'foreign'){throw 'rgb-foreign-owner'}
    if($Operation -in @('Start','Toggle','Install') -and @($Snapshot.Processes | Where-Object {$_.Role -ne 'observer'}).Count -gt 0 -and
        @($Snapshot.Processes | Where-Object {$_.Role -eq 'ambient'}).Count -eq 0){throw 'rgb-helper-busy'}
}
function Enter-RgbOperation {
    param([string]$Name='Global\Lat3ncyRgbControl-v1')
    $mutex=[Threading.Mutex]::new($false,$Name);$owned=$false
    try {
        try {$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'rgb-operation-busy'}
        return $mutex
    }catch{$mutex.Dispose();throw}
}
function Exit-RgbOperation($Lease) {if($Lease){try{$Lease.ReleaseMutex()}finally{$Lease.Dispose()}}}
function Get-RgbQuitFlag([string]$RgbRoot) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-RgbPath $RgbRoot)))}finally{$sha.Dispose()}
    $scope=-join ($hash | ForEach-Object {$_.ToString('x2')})
    $base=$env:LOCALAPPDATA;if(-not $base){$base=[Environment]::GetFolderPath('LocalApplicationData')}
    return Join-Path (Join-Path $base 'lat3ncy-toolbox') ('rgb-quit-'+$scope.Substring(0,24)+'.flag')
}
function Write-RgbQuitRequest([string]$Path,$Snapshot) {
    $targets=@($Snapshot.Processes | Where-Object {$_.Role -in @('ambient','once','observer')} |
        ForEach-Object {@{pid=[int]$_.ProcessId;start_ticks=[string]$_.StartTicks}})
    if($targets.Count -lt 1 -or $targets.Count -gt 64){throw 'rgb-quit-targets'}
    $id=[guid]::NewGuid().ToString('N')
    $text=@{version=1;id=$id;expires_utc=[DateTimeOffset]::UtcNow.AddSeconds(15).ToUnixTimeSeconds();targets=$targets}|ConvertTo-Json -Compress -Depth 4
    $temporary=$Path+'.'+$id+'.tmp'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    try {
        [IO.File]::WriteAllText($temporary,$text,[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
        return $id
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Clear-RgbQuitRequest([string]$Path,[string]$Id) {
    if(-not $Id -or -not [IO.File]::Exists($Path)){return}
    try {
        if((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 16384){return}
        $data=[IO.File]::ReadAllText($Path)|ConvertFrom-Json -ErrorAction Stop
        if($data.id -ceq $Id){[IO.File]::Delete($Path)}
    }catch{throw 'rgb-quit-cleanup-unavailable'}
}
function Get-RgbOwnedTask {
    param([string]$RgbRoot,[scriptblock]$TaskProvider)
    if(-not $TaskProvider){$TaskProvider={@(Get-ScheduledTask -ErrorAction Stop | Where-Object {$_.TaskName -eq 'RGB-Ambient' -and $_.TaskPath -eq '\'})}}
    try{$tasks=@(& $TaskProvider | Where-Object {$null -ne $_})}catch{throw 'rgb-task-unavailable'}
    if($tasks.Count -eq 0){return $null}
    if($tasks.Count -ne 1){throw 'rgb-task-owner'}
    $task=$tasks[0]
    if($task.TaskName -ne 'RGB-Ambient' -or $task.TaskPath -ne '\' -or @($task.Actions).Count -ne 1){throw 'rgb-task-owner'}
    $action=$task.Actions[0];$exe=[IO.Path]::GetFileName($action.Execute)
    $arguments=@(Get-RgbArguments ('"'+$action.Execute+'" '+$action.Arguments))
    if($exe -imatch '^pythonw?\.exe$'){
        if($arguments.Count -ne 3 -or $arguments[1] -cne '-u' -or
            (ConvertTo-RgbPath $arguments[2]) -cne (ConvertTo-RgbPath (Join-Path $RgbRoot 'ambient.py')) -or
            (ConvertTo-RgbPath $action.WorkingDirectory) -cne (ConvertTo-RgbPath $RgbRoot)){throw 'rgb-task-owner'}
    }elseif($exe -in @('powershell.exe','pwsh.exe')){
        $index=[Array]::IndexOf($arguments,'-File')
        if($index -lt 0 -or $index+1 -ge $arguments.Count -or
            (ConvertTo-RgbPath $arguments[$index+1]) -cne (ConvertTo-RgbPath (Join-Path $RgbRoot 'Start-Ambient.ps1'))){throw 'rgb-task-owner'}
        Assert-RgbFileHostArguments $arguments $index
        for($i=$index+2;$i -lt $arguments.Count;$i++){if($arguments[$i] -ine '-Wait'){throw 'rgb-task-owner'}}
        if(@($arguments | Where-Object {$_ -in @('-Command','-c','-EncodedCommand','-e')}).Count){throw 'rgb-task-owner'}
    }else{throw 'rgb-task-owner'}
    return $task
}
function Test-RgbHardwareAdmission {
    param([string]$RgbRoot,[int]$OwnerPid,[scriptblock]$SnapshotProvider)
    try {
        $snapshot=if($SnapshotProvider){& $SnapshotProvider}else{Get-RgbProcessSnapshot $RgbRoot}
        if($snapshot.Status -notin @('running','absent')){return [string]$snapshot.Status}
        $owner=@($snapshot.Processes | Where-Object {$_.ProcessId -eq $OwnerPid -and $_.Role -in @('ambient','once')})
        if($owner.Count -ne 1){return 'unknown'}
        foreach($process in $snapshot.Processes){
            if($process.ProcessId -eq $OwnerPid){continue}
            if($process.Role -eq 'observer'){continue}
            if($process.Role -eq 'waiter' -and $process.ProcessId -eq $owner[0].ParentProcessId -and
                [long]$process.StartTicks -lt [long]$owner[0].StartTicks){continue}
            return 'busy'
        }
        return 'ok'
    }catch{return 'unknown'}
}
function Stop-RgbVerifiedProcess {
    param($Expected,[scriptblock]$ProcessProvider,[scriptblock]$Stopper)
    if(-not $ProcessProvider){$ProcessProvider={param($Id)
        try {Get-Process -Id $Id -ErrorAction Stop}
        catch {if($_.CategoryInfo.Category -ne 'ObjectNotFound'){throw 'rgb-process-unavailable'}}
    }}
    if(-not $Stopper){$Stopper={param($Process) Stop-Process -InputObject $Process -Force -ErrorAction Stop}}
    $live=$null
    try {
        $live=& $ProcessProvider $Expected.ProcessId
        if(-not $live){return}
        if($live -is [Diagnostics.Process]){[void]$live.Handle}
        if($live.HasExited){return}
        if($live.ProcessName -ine [IO.Path]::GetFileNameWithoutExtension($Expected.Name) -or
            $live.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -cne $Expected.StartTicks){throw 'rgb-process-changed'}
        & $Stopper $live
    }finally{if($live -is [Diagnostics.Process]){$live.Dispose()}}
}

# Caller holds the control lease. Stop uses the same thread's reentrant lease.
function Restart-RgbOwnedTask([string]$RgbRoot) {
    Assert-RgbSnapshot (Get-RgbProcessSnapshot $RgbRoot) Stop
    $task=Get-RgbOwnedTask $RgbRoot
    if(-not $task){throw 'rgb-task-missing'}
    if([string]$task.State -ne 'Running'){return}
    & (Join-Path $RgbRoot 'Stop-Ambient.ps1') | Out-Null
    if($LASTEXITCODE -ne 0){throw 'rgb-stop-failed'}
    $task=Get-RgbOwnedTask $RgbRoot
    if(-not $task -or [string]$task.State -eq 'Running'){throw 'rgb-task-not-stopped'}
    Assert-RgbSnapshot (Get-RgbProcessSnapshot $RgbRoot) Start
    Start-ScheduledTask -TaskName 'RGB-Ambient' -TaskPath '\' -ErrorAction Stop
    Start-Sleep -Seconds 2
    $task=Get-RgbOwnedTask $RgbRoot
    if(-not $task -or [string]$task.State -ne 'Running'){throw 'rgb-task-not-running'}
}
