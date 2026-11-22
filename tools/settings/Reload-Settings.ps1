[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RequestId)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReloadSupport.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$state = Join-Path $repo '.toolbox-state'
$requestPath = Join-Path $state 'reload-request.json'
$resultPath = Join-Path $state 'reload-result.json'
$mutex = [Threading.Mutex]::new($false,('Local\lat3ncy-settings-reload-'+$RequestId))
$owned=$false
try {
    try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    if (-not $owned) { exit 0 }
    $request = Read-SettingsReloadJson $requestPath
    $actions = @(Assert-SettingsReloadRequest $request $RequestId ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
    Assert-SettingsReloadOwner $request $repo
    if (Test-Path -LiteralPath $resultPath) {
        $prior = Read-SettingsReloadJson $resultPath
        if ($prior.id -eq $RequestId -and $prior.status -eq 'completed') { exit 0 }
    }
    $result = @{id=$RequestId;status='running';completed='';failed=''}
    Write-SettingsReloadResult $resultPath $result
    $completed=@();$failed=@()
    foreach ($action in $actions) {
        try {
            if (Test-Path -LiteralPath (Join-Path $repo '.toolbox-controls.json')) {
                $controls = Read-SettingsReloadJson (Join-Path $repo '.toolbox-controls.json')
                $flag = $controls.PSObject.Properties['module_'+$action+'_enabled']
                if ($null -ne $flag -and $flag.Value -ceq $false) { throw 'reload-disabled' }
            }
            $config = switch($action) { power {'tools\power-policy\config.toml'} theme {'tools\theme-scheduler\config.toml'} rgb {'tools\rgb\config.toml'} }
            $hash = (Get-FileHash -LiteralPath (Join-Path $repo $config) -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -cne $request.($action+'_revision')) { throw 'reload-config-changed' }
            switch ($action) {
                power { & (Join-Path $repo 'tools\power-policy\Restart-PowerPolicy.ps1') | Out-Null }
                theme {
                    $themeRoot = Join-Path $repo 'tools\theme-scheduler'
                    $scripts = @{'Theme-Light'='Set-Theme-Light.ps1';'Theme-Dark'='Set-Theme-Dark.ps1';'Theme-Schedule-Update'='Update-ThemeSchedule.ps1';'Theme-Apply-Now'='Apply-ThemeNow.ps1';'Theme-Apply-Cursors'='Apply-CursorsNow.ps1'}
                    foreach ($name in $scripts.Keys) {
                        # Settings only updates an installed, owned schedule.
                        $task = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop
                        Assert-SettingsTaskOwner $task (Join-Path $themeRoot $scripts[$name])
                    }
                    & (Join-Path $themeRoot 'Update-ThemeSchedule.ps1') -Strict | Out-Null
                }
                rgb {
                    $task = Get-ScheduledTask -TaskName 'RGB-Ambient' -TaskPath '\' -ErrorAction Stop
                    Assert-SettingsTaskOwner $task (Join-Path $repo 'tools\rgb\ambient.py')
                    if ([string]$task.State -eq 'Running') {
                        Stop-ScheduledTask -TaskName 'RGB-Ambient' -TaskPath '\' -ErrorAction Stop
                        $deadline=[DateTime]::UtcNow.AddSeconds(15)
                        do { Start-Sleep -Milliseconds 250; $task=Get-ScheduledTask -TaskName 'RGB-Ambient' -TaskPath '\' } while ([string]$task.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline)
                        if ([string]$task.State -eq 'Running') { throw 'reload-rgb-stop' }
                        Start-ScheduledTask -TaskName 'RGB-Ambient' -TaskPath '\' -ErrorAction Stop
                        Start-Sleep -Seconds 2
                        if ([string](Get-ScheduledTask -TaskName 'RGB-Ambient' -TaskPath '\').State -ne 'Running') { throw 'reload-rgb-start' }
                    }
                    # An idle task reads the saved config on its next normal start.
                }
            }
            $completed += $action
        } catch { $failed += $action }
    }
    $result.status='completed';$result.completed=($completed -join ',');$result.failed=($failed -join ',')
    Write-SettingsReloadResult $resultPath $result
} catch {
    # Never log parser/provider/config text. The native window keeps pending state.
    if ($null -ne (Get-Variable -Name actions -ErrorAction SilentlyContinue)) {
        try { Write-SettingsReloadResult $resultPath @{id=$RequestId;status='completed';completed='';failed=($actions -join ',')} } catch { }
    }
    exit 1
} finally { if($owned){$mutex.ReleaseMutex()};$mutex.Dispose() }
