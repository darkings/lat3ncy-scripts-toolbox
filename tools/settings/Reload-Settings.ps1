[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RequestId)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReloadSupport.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'tools\ToolboxControls.ps1')
$state = Join-Path $repo '.toolbox-state'
$requestPath = Join-Path $state 'reload-request.json'
$resultPath = Join-Path $state 'reload-result.json'
$sha=[Security.Cryptography.SHA256]::Create()
try{$scope=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($repo).ToLowerInvariant()))).Replace('-','')}finally{$sha.Dispose()}
$mutex = [Threading.Mutex]::new($false,('Local\lat3ncy-settings-reload-'+$scope))
$owned=$false
try {
    try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    $request = Read-SettingsReloadJson $requestPath
    $actions = @(Assert-SettingsReloadRequest $request $RequestId ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
    Assert-SettingsReloadOwner $request $repo
    if(-not $owned){Write-SettingsReloadResult $resultPath @{id=$RequestId;status='completed';completed='';failed=($actions -join ',');errors=@{busy='busy'}};exit 1}
    if (Test-Path -LiteralPath $resultPath) {
        $prior = Read-SettingsReloadJson $resultPath
        if ($prior.id -eq $RequestId -and $prior.status -eq 'completed') { exit 0 }
    }
    $hostProcess=Get-Process -Id $PID
    try{$hostTicks=$hostProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()}finally{$hostProcess.Dispose()}
    $result = @{id=$RequestId;status='running';completed='';failed='';worker_pid=$PID;worker_ticks=$hostTicks}
    Write-SettingsReloadResult $resultPath $result
    $completed=@();$failed=@();$errors=@{}
    foreach ($action in $actions) {
        $failureReason='operation_failed'
        try {
            $failureReason='capture_busy'
            if((Get-SettingsRecordingState $repo) -ne 'idle'){throw 'reload-capture-busy'}
            $failureReason='disabled'
            if(-not(Test-ToolboxModuleEnabled -Module $action -RepoRoot $repo)){throw 'reload-disabled'}
            $config = switch($action) { power {'tools\power-policy\config.toml'} theme {'tools\theme-scheduler\config.toml'} rgb {'tools\rgb\config.toml'} }
            $failureReason='config_changed'
            $hash = (Get-FileHash -LiteralPath (Join-Path $repo $config) -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -cne $request.($action+'_revision')) { throw 'reload-config-changed' }
            $failureReason='operation_failed'
            switch ($action) {
                power { & (Join-Path $repo 'tools\power-policy\Restart-PowerPolicy.ps1') | Out-Null }
                theme {
                    $failureReason='ownership'
                    $themeRoot = Join-Path $repo 'tools\theme-scheduler'
                    $scripts = @{'Theme-Light'='Set-Theme-Light.ps1';'Theme-Dark'='Set-Theme-Dark.ps1';'Theme-Schedule-Update'='Update-ThemeSchedule.ps1';'Theme-Apply-Now'='Apply-ThemeNow.ps1';'Theme-Apply-Cursors'='Apply-CursorsNow.ps1'}
                    foreach ($name in $scripts.Keys) {
                        # Settings only updates an installed, owned schedule.
                        $task = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop
                        Assert-SettingsTaskOwner $task (Join-Path $themeRoot $scripts[$name])
                    }
                    $failureReason='operation_failed'
                    & (Join-Path $themeRoot 'Update-ThemeSchedule.ps1') -Strict | Out-Null
                }
                rgb {
                    . (Join-Path $repo 'tools\rgb\RgbRuntime.ps1')
                    $failureReason='busy'
                    $rgbLease=Enter-RgbOperation
                    try {
                    $failureReason='ownership'
                    Restart-RgbOwnedTask (Join-Path $repo 'tools\rgb')
                    # An idle task reads the saved config on its next normal start.
                    } finally {Exit-RgbOperation $rgbLease}
                }
            }
            $completed += $action
        } catch { $failed += $action;$errors[$action]=$failureReason }
    }
    $result.status='completed';$result.completed=($completed -join ',');$result.failed=($failed -join ',')
    $result.errors=$errors
    Write-SettingsReloadResult $resultPath $result
} catch {
    # Never log parser/provider/config text. The native window keeps pending state.
    if ($null -ne (Get-Variable -Name actions -ErrorAction SilentlyContinue)) {
        try { Write-SettingsReloadResult $resultPath @{id=$RequestId;status='completed';completed='';failed=($actions -join ',')} } catch { }
    }
    exit 1
} finally { if($owned){$mutex.ReleaseMutex()};$mutex.Dispose() }
