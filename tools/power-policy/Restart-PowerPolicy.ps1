# Gracefully reload the existing task. No elevation or task re-registration.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\startup\ToolboxProcess.ps1')
$engine=Join-Path $PSScriptRoot 'PowerPolicy.ps1'
$task=Get-ScheduledTask -TaskName PowerPolicy -ErrorAction Stop
if($task.Actions.Count -ne 1 -or $task.Actions.Arguments -notmatch [regex]::Escape('"'+$engine+'"')){throw 'Task belongs to another checkout'}
$snapshot=Get-ToolboxPowerPolicySnapshot $engine
if($snapshot.Status -notin @('running','outdated') -or $snapshot.Evidence -ne 'heartbeat'){
    throw 'Reload requires a fresh, verified heartbeat; inspect the resident before retrying'
}
$stateDir=Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox'
$statusPath=Join-Path $stateDir 'power-policy-status.json'
$stopPath=Join-Path $stateDir 'power-policy.stop'
if(Test-Path -LiteralPath $stopPath){throw 'A stop request already exists; another operation may be active'}
$before=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$old=Get-Process -Id $before.pid -ErrorAction Stop
if($old.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne $before.startTicks -or
   $snapshot.ProcessIds -notcontains [int]$before.pid){$old.Dispose();throw 'Resident identity changed'}
$main=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'ahk\main.ahk'
$lease=[Threading.Mutex]::new($false,((Get-ToolboxInstanceName $main)+'-Deployment'))
$owned=$false;$ready=$false;$stopWritten=$false
try {
    try{$owned=$lease.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){throw 'Another deployment/reload is active'}
    [IO.File]::WriteAllText($stopPath,'{"stop":true}',[Text.UTF8Encoding]::new($true));$stopWritten=$true
    if(-not $old.WaitForExit(25000)){throw 'Resident did not stop gracefully within 25s'}
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $task=Get-ScheduledTask -TaskName PowerPolicy -ErrorAction Stop
        if([string]$task.State -ne 'Running'){break}
        Start-Sleep -Milliseconds 250
    } while([DateTime]::UtcNow -lt $deadline)
    if([string]$task.State -eq 'Running'){throw 'Task wrapper did not exit'}
    [IO.File]::Delete($stopPath);$stopWritten=$false
    Start-ScheduledTask -TaskName PowerPolicy -ErrorAction Stop
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    do {
        $after=Get-ToolboxPowerPolicySnapshot $engine
        if($after.Status -eq 'running' -and $after.Evidence -eq 'heartbeat' -and $after.ProcessIds -notcontains [int]$before.pid){
            $beat=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if($beat.pid -in $after.ProcessIds -and [DateTime]$beat.updatedUtc -gt [DateTime]$before.updatedUtc){$ready=$true;break}
        }
        Start-Sleep -Milliseconds 500
    } while([DateTime]::UtcNow -lt $deadline)
    if(-not $ready){throw 'No fresh, current-source heartbeat after reload'}
    foreach($name in @('LidRegistrationError','PowerRegistrationError','ResumeRegistrationError','DisplayRegistrationError')){
        if($null -eq $beat.native.$name -or $beat.native.$name -ne 0){throw "Native notification registration failed: $name"}
    }
    [pscustomobject]@{OldPid=$before.pid;Pid=$beat.pid;HostPath=$beat.hostPath;SourceFingerprint=$beat.sourceFingerprint;Caffeine=$beat.caffeine;RequestBalance=$beat.requestBalance;HeartbeatUtc=$beat.updatedUtc} | ConvertTo-Json
} finally {
    if($stopWritten -and [IO.File]::Exists($stopPath)){[IO.File]::Delete($stopPath)}
    if(-not $ready -and $old.HasExited){try{Start-ScheduledTask -TaskName PowerPolicy -ErrorAction Stop}catch{Write-Warning $_.Exception.Message}}
    $old.Dispose()
    if($owned){$lease.ReleaseMutex()};$lease.Dispose()
}
