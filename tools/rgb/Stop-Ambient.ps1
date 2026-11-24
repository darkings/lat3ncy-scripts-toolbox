#Requires -Version 5.1
# Stop only verified processes and the task owned by this checkout. No device calls.
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root 'RgbRuntime.ps1')
$lease=Enter-RgbOperation
$quitFlag=$null
$quitId=''
try {
    $quitFlag=Get-RgbQuitFlag $root
    $snapshot=Get-RgbProcessSnapshot -RgbRoot $root
    Assert-RgbSnapshot $snapshot Stop
    $task=Get-RgbOwnedTask -RgbRoot $root
    if(@($snapshot.Processes | Where-Object {$_.Role -in @('ambient','once','observer')}).Count){
        $quitId=Write-RgbQuitRequest $quitFlag $snapshot
        $deadline=[DateTime]::UtcNow.AddSeconds(2.5)
        do {
            $remaining=0
            foreach($process in $snapshot.Processes | Where-Object {$_.Role -in @('ambient','once','observer')}){
                $identity=Get-ToolboxProcessStartIdentity -ProcessId $process.ProcessId
                if($identity.Status -eq 'unknown'){throw 'rgb-process-unavailable'}
                if($identity.Status -eq 'present' -and [string]$identity.StartTicks -ceq $process.StartTicks){$remaining++}
            }
            if(-not $remaining){break}
            Start-Sleep -Milliseconds 100
        } while([DateTime]::UtcNow -lt $deadline)
    }
    # Recheck the fixed task after the graceful interval, before ending it.
    if($task){
        $task=Get-RgbOwnedTask -RgbRoot $root
        if($task -and [string]$task.State -eq 'Running'){
            Stop-ScheduledTask -TaskName 'RGB-Ambient' -TaskPath '\' -ErrorAction Stop
        }
    }
    $snapshot=Get-RgbProcessSnapshot -RgbRoot $root
    Assert-RgbSnapshot $snapshot Stop
    foreach($process in $snapshot.Processes){Stop-RgbVerifiedProcess $process}
    Write-Host '[ambient] verified checkout processes stopped' -ForegroundColor Green
} finally {
    try {Clear-RgbQuitRequest $quitFlag $quitId}finally{Exit-RgbOperation $lease}
}
