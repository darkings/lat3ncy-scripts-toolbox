# Offline identity/heartbeat tests. No production state, task or process mutation.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ToolboxProcess.ps1')
function Assert($Value,$Label){if(-not $Value){throw "FAIL: $Label"}}
$power='C:\Example\repo\tools\power-policy\PowerPolicy.ps1'
$now=[datetime]::SpecifyKind([datetime]'2026-11-19T08:00:00',[DateTimeKind]::Utc)
$script:beat=[pscustomobject]@{identityVersion=1;scriptPath=$power;repoRoot='C:\Example\repo';pid=123;startTicks='134395338342388355';sourceFingerprint=('a'*64);updatedUtc=$now.ToString('o')}
$script:identity=[pscustomobject]@{Status='present';Name='pwsh';StartTicks=$script:beat.startTicks}
$script:fingerprint='a'*64
$script:queries=0
function Snapshot {
    Get-ToolboxPowerPolicySnapshot -PowerScript $power -NowUtc $now -HeartbeatProvider {$script:beat} -IdentityProvider {$script:identity} -FingerprintProvider {$script:fingerprint} -ProcessProvider {$script:queries++;throw 'CIM denied'}
}
$snapshot=Snapshot
Assert ($snapshot.Status -eq 'running' -and $snapshot.Evidence -eq 'heartbeat') 'fresh matching identity works without CIM'
Assert ($script:queries -eq 0) 'healthy heartbeat never queries inaccessible command lines'
Assert ($snapshot.ProcessIds[0] -eq 123) 'heartbeat keeps the verified pid'
foreach($date in @($now,$now.ToLocalTime(),([DateTimeOffset]::new($now)),
    (('{"date":"'+$now.ToString('o')+'"}') | ConvertFrom-Json).date)){
    $script:beat.updatedUtc=$date
    Assert ((Snapshot).Status -eq 'running') 'typed/JSON/local date preserves the UTC instant on PS 5.1 and PS 7'
}
$script:beat.updatedUtc=$now.ToString('o')
$script:fingerprint='b'*64
Assert ((Snapshot).Status -eq 'outdated') 'old source/config fingerprint is distinct from absent or healthy'
$script:fingerprint='a'*64
$script:beat.updatedUtc=$now.AddSeconds(-61).ToString('o')
Assert ((Snapshot).Status -eq 'query-failed') 'stale heartbeat with live identity never counts as healthy'
$script:beat.updatedUtc=$now.AddSeconds(30).ToString('o')
Assert ((Snapshot).Status -eq 'query-failed') 'future heartbeat is rejected'
$script:beat.updatedUtc=$now.ToString('o')
$script:identity.StartTicks='134395338342388356'
Assert ((Snapshot).Status -eq 'query-failed') 'reused PID cannot bypass the failed CIM query'
$script:identity.StartTicks=$script:beat.startTicks
$script:beat.scriptPath='C:\Other\repo\tools\power-policy\PowerPolicy.ps1'
Assert ((Snapshot).Status -eq 'query-failed') 'another checkout does not prove current instance healthy'
$script:beat.scriptPath=$power
$script:beat.repoRoot='C:\Other\repo'
Assert ((Snapshot).Status -eq 'query-failed') 'repository identity must agree with script path'
$script:beat.repoRoot='C:\Example\repo'
$script:identity.Status='unknown'
Assert ((Snapshot).Status -eq 'query-failed') 'unreadable creation time remains unknown'
$script:identity.Status='absent'
$snapshot=Get-ToolboxPowerPolicySnapshot -PowerScript $power -NowUtc $now -HeartbeatProvider {$script:beat} -IdentityProvider {$script:identity} -ProcessProvider {@()}
Assert ($snapshot.Status -eq 'not-running') 'dead PID plus empty process list permits recovery'
$snapshot=Get-ToolboxPowerPolicySnapshot -PowerScript $power -NowUtc $now -HeartbeatProvider {throw 'invalid JSON'} -ProcessProvider {@()}
Assert ($snapshot.Status -eq 'not-running') 'corrupt heartbeat does not hide authoritative absence'
$snapshot=Get-ToolboxPowerPolicySnapshot -PowerScript $power -HeartbeatProvider {throw 'invalid JSON'} -ProcessProvider {
    [pscustomobject]@{Name='pwsh.exe';ProcessId=123;CommandLine=('pwsh.exe -File "'+$power+'" -Run')}
}
Assert ($snapshot.Status -eq 'query-failed') 'corrupt heartbeat plus live command line is not a health proof'

$temp=Join-Path ([IO.Path]::GetTempPath()) ('power-fingerprint-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try {
    $entry=Join-Path $temp 'PowerPolicy.ps1'
    [IO.File]::WriteAllText($entry,'# fixture')
    $before=Get-ToolboxPowerFingerprint $entry
    [IO.File]::WriteAllText((Join-Path $temp 'config.toml'),'interval_seconds = 1')
    $after=Get-ToolboxPowerFingerprint $entry
    Assert ($before -ne $after) 'configuration change invalidates loaded fingerprint'
    $own=Get-ToolboxProcessStartIdentity -ProcessId $PID
    Assert ($own.Status -eq 'present' -and [long]$own.StartTicks -gt 0) 'real own process identity is readable'
    Assert ((Get-ToolboxProcessStartIdentity -ProcessId 2147483647).Status -eq 'absent') 'nonexistent process is distinct from unreadable'
} finally {
    Get-ChildItem -LiteralPath $temp -File | Remove-Item -Force
    Remove-Item -LiteralPath $temp
}
[Console]::Out.WriteLine('PASS: PowerPolicy heartbeat identity tests')
