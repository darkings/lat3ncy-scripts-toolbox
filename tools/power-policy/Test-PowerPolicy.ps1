#Requires -Version 5.1
$ErrorActionPreference='Stop'
$testDirectory=Join-Path $env:TEMP ("power-policy-tests-" + [Guid]::NewGuid())
$null=New-Item -ItemType Directory -Path $testDirectory
. (Join-Path $PSScriptRoot 'PowerPolicy.ps1') -LibraryOnly -LogPath (Join-Path $testDirectory 'test.log')
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS $Message" }
try {
    foreach ($file in @('PowerPolicy.ps1','PowerPolicy.Core.ps1','Install-PowerPolicy.ps1','Uninstall-PowerPolicy.ps1')) {
        $tokens=$null; $parseErrors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$parseErrors)
        Assert ($parseErrors.Count -eq 0) "parse $file : $parseErrors"
    }
    $on=Get-DesiredPowerPolicy $true; $off=Get-DesiredPowerPolicy $false
    Assert (($on.LIDACTION -join ',') -eq '0,0') 'Caffeine on cancels explicit lid sleep on AC and DC'
    Assert (($on.STANDBYIDLE -join ',') -eq '0,0') 'Caffeine on cancels idle sleep on AC and DC'
    Assert (($on.HIBERNATEIDLE -join ',') -eq '0,0') 'Caffeine on cancels fixed hibernate timeout'
    Assert (($off.LIDACTION -join ',') -eq '1,1') 'Caffeine off restores native lid sleep'
    Assert (($off.STANDBYIDLE -join ',') -eq '0,1800') 'Caffeine off restores battery 30 minute idle sleep'
    Assert (($off.HIBERNATEIDLE -join ',') -eq '0,3600') 'Caffeine off restores battery 60 minute hibernate'
    Assert (($on.VIDEOIDLE -join ',') -eq '600,600' -and ($off.VIDEOIDLE -join ',') -eq '600,600') 'display timeout stays 10 minutes'
    $closed=Get-DesiredPowerPolicy $true 0
    $opened=Get-DesiredPowerPolicy $true 1
    Assert (($closed.VIDEOIDLE -join ',') -eq '1,1') 'confirmed closed lid uses natural 1 second display idle timeout'
    Assert (($closed.STANDBYIDLE -join ',') -eq '0,0') 'closed lid never re-enables sleep timeout with Caffeine on'
    Assert (($opened.VIDEOIDLE -join ',') -eq '600,600') 'opening lid restores 10 minute display idle timeout'
    Assert (((Get-DesiredPowerPolicy $false 0).VIDEOIDLE -join ',') -eq '600,600') 'Caffeine off never applies temporary display timeout'
    $COFFEE_STATE=Join-Path $testDirectory 'coffee.json'; $COFFEE_STOP=Join-Path $testDirectory 'stop.flag'
    Assert (-not (Test-CaffeineActive)) 'missing Coffee state is inactive'
    $process=Get-Process -Id $PID
    $state=@{pid=$PID;startTicks=$process.StartTime.ToUniversalTime().ToFileTimeUtc();startTime=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();durationSeconds=$null}
    Write-AtomicJson $state $COFFEE_STATE
    Assert (Test-CaffeineActive) 'live Coffee state with matching creation time is active'
    $state.startTicks=1; Write-AtomicJson $state $COFFEE_STATE
    Assert (-not (Test-CaffeineActive)) 'reused PID / stale creation time is inactive'
    $state.startTicks=$process.StartTime.ToUniversalTime().ToFileTimeUtc(); $state.startTime=1; $state.durationSeconds=10
    Write-AtomicJson $state $COFFEE_STATE
    Assert (-not (Test-CaffeineActive)) 'expired timed session is inactive'
    $state.durationSeconds=$null; Write-AtomicJson $state $COFFEE_STATE
    Set-Content -LiteralPath $COFFEE_STOP -Value 'stop'
    Assert (-not (Test-CaffeineActive)) 'Coffee stop flag wins over a live PID'
    Remove-Item -LiteralPath $COFFEE_STOP
    Set-Content -LiteralPath $COFFEE_STATE -Value '{'
    Assert (-not (Test-CaffeineActive)) 'partially written state is inactive'
    Initialize-PowerNative
    $scheme=[ToolboxPower.Native]::ActiveScheme()
    $before=Get-PowerValues $scheme | ConvertTo-Json -Compress
    $DryRun=$true
    Set-DesiredPowerPolicy $on
    $after=Get-PowerValues $scheme | ConvertTo-Json -Compress
    Assert ($before -eq $after) 'DryRun leaves actual power settings unchanged'
    Assert (-not (Test-Path -LiteralPath (Join-Path $testDirectory "power-policy-backup-$scheme.json"))) 'DryRun does not save or alter recovery baseline'
    try {
        1..100 | ForEach-Object { [void][ToolboxPower.Native]::Hold($false) }
        Assert ([ToolboxPower.Native]::RequestBalance -eq 1) '100 holds retain one native request'
        [ToolboxPower.Native]::Release()
        Assert ([ToolboxPower.Native]::RequestBalance -eq 0) 'one release balances repeated holds'
        [void][ToolboxPower.Native]::Hold($false)
        [void][ToolboxPower.Native]::Hold($true)
        Assert ([ToolboxPower.Native]::RequestBalance -eq 1) 'resume/power reset recreates one handle'
    } finally { [ToolboxPower.Native]::Release() }
    try {
        [ToolboxPower.Native]::StartNotifications()
        Start-Sleep -Milliseconds 500
        $snapshot=[ToolboxPower.Native]::GetSnapshot()
        Assert ($snapshot.LidRegistrationError -eq 0 -and $snapshot.PowerRegistrationError -eq 0 -and $snapshot.ResumeRegistrationError -eq 0 -and $snapshot.DisplayRegistrationError -eq 0) 'native registrations succeed (actual lid events require manual test)'
        Write-Host ($snapshot | ConvertTo-Json -Compress)
    } finally { [ToolboxPower.Native]::StopNotifications() }
    Write-Host 'All checks passed. No display-off or suspend command was sent.'
} finally {
    # Only this unique test directory is removed; no recursive deletion.
    Get-ChildItem -LiteralPath $testDirectory -File | Remove-Item -Force
    Remove-Item -LiteralPath $testDirectory
}
