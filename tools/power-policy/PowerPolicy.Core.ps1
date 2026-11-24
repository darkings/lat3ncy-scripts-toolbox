# Native callbacks contain no PowerShell scriptblocks (callbacks run on foreign threads).
. (Join-Path $PSScriptRoot 'PowerPolicy.Identity.ps1')

function Test-PowerPolicyFeatureEnabled {
    $repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if(-not(Test-Path -LiteralPath (Join-Path $repo '.toolbox-controls.json'))){return $true}
    $helper=Join-Path (Split-Path $PSScriptRoot -Parent) 'ToolboxControls.ps1'
    if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){return $false}
    if(-not(Get-Command Test-ToolboxModuleEnabled -ErrorAction SilentlyContinue)){. $helper}
    return (Test-ToolboxModuleEnabled -Module power -RepoRoot $repo)
}

function Initialize-PowerNative {
    if (-not ('ToolboxPower.Native' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'PowerNative.cs') -ErrorAction Stop
    }
}

$script:SettingDefinitions = [ordered]@{
    LIDACTION = @('4f971e89-eebd-4455-a8de-9e59040e7347', '5ca83367-6e45-459f-a27b-476b1d01c936')
    STANDBYIDLE = @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da')
    HIBERNATEIDLE = @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '9d7815a6-7ee4-497e-8888-515a05f02364')
    VIDEOIDLE = @('7516b95f-f776-4464-8c53-06167f40cc99', '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e')
    RTCWAKE = @('238c9fa8-0aad-41ed-83f4-97be242c8f20', 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d')
}
$script:StateDirectory = Split-Path -Parent $LogPath
$script:StopFile = Join-Path $script:StateDirectory 'power-policy.stop'
$script:StatusFile = Join-Path $script:StateDirectory 'power-policy-status.json'
# 只记录本工具真正 disable 过的唤醒设备，卸载时按它 powercfg /deviceenablewake 恢复。
$script:WakeDisabledStatePath = Join-Path $script:StateDirectory 'wake-disabled-devices.json'
$script:WakeSkipLogged = $false
# 由 PowerPolicy.ps1 从 config.toml [wake] 段填充；LibraryOnly/测试直接 dot-source
# 本文件时用下面的安全默认：不动任何设备的唤醒能力。
if (-not (Test-Path variable:WakeWhitelist)) { $WakeWhitelist = @() }
if (-not (Test-Path variable:WakeDisableDevices)) { $WakeDisableDevices = $false }
if (-not (Test-Path variable:WakeDisableTimers)) { $WakeDisableTimers = $false }

function Write-AtomicJson($Value, [string]$Path) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $tempPath = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        # Explicit BOM is stable across PowerShell 5.1 and 7 (whose utf8 default differs).
        [IO.File]::WriteAllText($tempPath, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tempPath, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($tempPath, $Path) }
    } finally { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force } }
}

function Test-CaffeineActive {
    if (Test-Path -LiteralPath $COFFEE_STOP) { return $false }
    if (-not (Test-Path -LiteralPath $COFFEE_STATE)) { return $false }
    try {
        $state = Get-Content -LiteralPath $COFFEE_STATE -Raw | ConvertFrom-Json
        if (-not $state.pid -or -not $state.startTicks) { return $false }
        $process = Get-Process -Id ([int]$state.pid) -ErrorAction Stop
        # FILETIME startTicks, not wall-clock milliseconds: reject PID reuse.
        $delta = [math]::Abs([decimal]$process.StartTime.ToUniversalTime().ToFileTimeUtc() - [decimal]$state.startTicks)
        if ($delta -gt 10000) { return $false } # <= 1 ms tolerance for extension serialization.
        if ($null -ne $state.durationSeconds -and [double]$state.durationSeconds -gt 0) {
            $expiry = [DateTimeOffset]::FromUnixTimeSeconds([long]$state.startTime).AddSeconds([double]$state.durationSeconds)
            if ([DateTimeOffset]::UtcNow -ge $expiry) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-DesiredPowerPolicy([bool]$Caffeine, [int]$Lid = -1) {
    # No lid event is needed to select policy. Unknown lid state never disables keep-awake.
    return [ordered]@{
        LIDACTION = @($(if ($Caffeine) { 0 } else { 1 }), $(if ($Caffeine) { 0 } else { 1 }))
        STANDBYIDLE = @($AcStandbySeconds, $(if ($Caffeine) { 0 } else { $DcStandbySeconds }))
        HIBERNATEIDLE = @($AcHibernateSeconds, $(if ($Caffeine) { 0 } else { $DcHibernateSeconds }))
        # Natural display-idle timeout is distinct from an explicit screen-off/sleep request.
        # Only while a confirmed closed lid + Caffeine: restore baseline on opening.
        VIDEOIDLE = $(if ($Caffeine -and $Lid -eq 0) { @(1,1) } else { @($AcVideoIdleSeconds, $DcVideoIdleSeconds) })
    }
}

function Get-PowerValues([Guid]$Scheme) {
    $values = [ordered]@{}
    foreach ($name in $script:SettingDefinitions.Keys) {
        $ids = $script:SettingDefinitions[$name]
        $values[$name] = @([ToolboxPower.Native]::Read($Scheme, $ids[0], $ids[1], $true),
                          [ToolboxPower.Native]::Read($Scheme, $ids[0], $ids[1], $false))
    }
    return $values
}

function Save-OriginalPowerPolicy([Guid]$Scheme, $Values) {
    $backupPath = Join-Path $script:StateDirectory "power-policy-backup-$Scheme.json"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Write-AtomicJson @{ scheme = "$Scheme"; savedUtc = [DateTime]::UtcNow.ToString('o'); values = $Values } $backupPath
        Write-Log "[备份] $backupPath"
    } else {
        # Migrate old backups before touching newly managed settings. Preserve all
        # original fields; a missing baseline can only be captured as it is now.
        $backup = Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $backup.values -or [Guid]$backup.scheme -ne $Scheme) { throw "无效电源备份：$backupPath" }
        $updated = $false
        foreach ($name in $Values.Keys) {
            if (-not $backup.values.PSObject.Properties[$name]) {
                $backup.values | Add-Member -MemberType NoteProperty -Name $name -Value $Values[$name]
                $updated = $true
            }
        }
        if ($updated) { Write-AtomicJson $backup $backupPath }
    }
}

function Set-DesiredPowerPolicy($Desired) {
    $scheme = [ToolboxPower.Native]::ActiveScheme()
    $current = Get-PowerValues $scheme
    $changes = @()
    foreach ($name in $Desired.Keys) {
        for ($index = 0; $index -lt 2; $index++) {
            if ($current[$name][$index] -ne $Desired[$name][$index]) {
                $changes += [pscustomobject]@{ Name=$name; Index=$index; Old=$current[$name][$index]; New=$Desired[$name][$index] }
            }
        }
    }
    if ($changes.Count -eq 0) { return }
    if ($DryRun) { Write-Log "[DryRun] 将变更：$($changes | ConvertTo-Json -Compress)"; return }
    Save-OriginalPowerPolicy $scheme $current
    try {
        foreach ($change in $changes) {
            $ids = $script:SettingDefinitions[$change.Name]
            [ToolboxPower.Native]::Write($scheme, $ids[0], $ids[1], ($change.Index -eq 0), $change.New)
        }
        # Batch changes: one activation, no recurring PolicyChange storms when values match.
        if ([ToolboxPower.Native]::ActiveScheme() -ne $scheme) { throw '电源计划在写入期间切换，取消激活' }
        [ToolboxPower.Native]::Activate($scheme)
        $actual = Get-PowerValues $scheme
        foreach ($change in $changes) {
            if ($actual[$change.Name][$change.Index] -ne $change.New) { throw "回读不一致：$($change.Name)" }
        }
        Write-Log "[策略] $($Desired | ConvertTo-Json -Compress)"
    } catch {
        # Roll back every attempted setting, including a partially completed write batch.
        foreach ($change in $changes) {
            $ids = $script:SettingDefinitions[$change.Name]
            try { [ToolboxPower.Native]::Write($scheme, $ids[0], $ids[1], ($change.Index -eq 0), $change.Old) } catch {}
        }
        if ([ToolboxPower.Native]::ActiveScheme() -eq $scheme) { [ToolboxPower.Native]::Activate($scheme) }
        throw
    }
}

function Restore-OriginalPowerPolicies {
    foreach ($file in Get-ChildItem -LiteralPath $script:StateDirectory -Filter 'power-policy-backup-*.json' -ErrorAction SilentlyContinue) {
        $backup = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $scheme = [Guid]$backup.scheme
        foreach ($name in $script:SettingDefinitions.Keys) {
            # A legacy backup may predate RTCWAKE. Never invent a zero baseline.
            if (-not $backup.values.PSObject.Properties[$name]) { continue }
            $ids = $script:SettingDefinitions[$name]
            [ToolboxPower.Native]::Write($scheme, $ids[0], $ids[1], $true, $backup.values.$name[0])
            [ToolboxPower.Native]::Write($scheme, $ids[0], $ids[1], $false, $backup.values.$name[1])
        }
        if ([ToolboxPower.Native]::ActiveScheme() -eq $scheme) { [ToolboxPower.Native]::Activate($scheme) }
        Write-Log "[恢复] 已恢复安装前电源计划 $scheme"
    }
}

function Assert-LenovoDisabled {
    $service = Get-Service -Name LenovoSmartStandby -ErrorAction SilentlyContinue
    if ($service -and ($service.Status -ne 'Stopped' -or $service.StartType -ne 'Disabled')) {
        throw 'LenovoSmartStandby 必须保持 Stopped/Disabled；本工具不会启用它'
    }
}

# Write-ahead journal: these devices were wake-armed before our disable attempt.
function Save-DisabledWakeDevices([string[]]$Names) {
    if (-not $Names -or $Names.Count -eq 0) { return }
    $merged = @()
    if (Test-Path -LiteralPath $script:WakeDisabledStatePath) {
        $data = Get-Content -LiteralPath $script:WakeDisabledStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $data.PSObject.Properties['devices']) { throw '无效唤醒恢复存档；未禁用设备' }
        $merged = @($data.devices)
    }
    $merged = @(@($merged) + $Names | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    Write-AtomicJson @{ devices = $merged; updatedUtc = [DateTime]::UtcNow.ToString('o') } $script:WakeDisabledStatePath
}

# 卸载时恢复：没有存档就什么都不做（兼容没跑过新版禁用的机器）。
function Restore-DisabledWakeDevices {
    if (-not (Test-Path -LiteralPath $script:WakeDisabledStatePath)) { return }
    $names = @()
    try {
        $data = Get-Content -LiteralPath $script:WakeDisabledStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $data.PSObject.Properties['devices']) { throw '无效唤醒恢复存档；保留原文件' }
        $names = @($data.devices | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    } catch {
        Write-Log "[唤醒] 存档读取失败：$($_.Exception.Message)"
        throw
    }
    $remaining = @()
    foreach ($name in $names) {
        & powercfg /deviceenablewake $name 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "[唤醒] 恢复失败：$name"; $remaining += $name }
        else { Write-Log "[唤醒] 已恢复唤醒能力：$name" }
    }
    if ($remaining.Count -gt 0) {
        Write-AtomicJson @{ devices = $remaining; updatedUtc = [DateTime]::UtcNow.ToString('o') } $script:WakeDisabledStatePath
        throw "部分设备唤醒恢复失败，已保留存档供重试：$($remaining -join ', ')"
    }
    Remove-Item -LiteralPath $script:WakeDisabledStatePath -Force -ErrorAction Stop
}

function Invoke-WakeBlock {
    if (-not (Test-PowerPolicyFeatureEnabled)) { return }
    # 只有 config [wake] disable_devices = true（默认）才动设备唤醒能力。
    # 旧实现的缺陷不是“禁用”本身，而是：白名单恒为空（没法豁免任何设备）、
    # 禁用后不留档（卸载不恢复）、且 powercfg /devicedisablewake 是持久设置。
    # 现在：白名单由 config 或内置 HID 豁免提供，禁用前存档，卸载按档 deviceenablewake。
    if (-not $WakeDisableDevices) {
        if (-not $script:WakeSkipLogged) {
            Write-Log '[唤醒] 跳过设备禁用（config.toml [wake] disable_devices = false）'
            $script:WakeSkipLogged = $true
        }
    } else {
        $devices = @(& powercfg /devicequery wake_armed 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "无法查询唤醒设备：$devices" }
        foreach ($device in $devices) {
            $name = "$device".Trim()
            if (-not $name -or $name -in @('无','無','None')) { continue }
            $allowed = $false
            foreach ($pattern in $WakeWhitelist) { if ($name -like $pattern) { $allowed = $true } }
            if ($allowed -or $DryRun) { continue }
            # If durable journaling fails, do not modify the device. Retain the
            # entry even on powercfg failure: the original state was wake-armed.
            Save-DisabledWakeDevices @($name)
            & powercfg /devicedisablewake $name 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Log "[唤醒] 禁用失败：$name" }
        }
    }
    if ($WakeDisableTimers) {
        # Use the same pre-write backup, rollback and readback as other settings.
        Set-DesiredPowerPolicy ([ordered]@{ RTCWAKE = @(0,0) })
    }
}

function Invoke-PowerPolicyTick {
    $tickUtc=[DateTime]::UtcNow
    if ($null -ne $script:LastTickUtc) {
        $gap=($tickUtc-$script:LastTickUtc).TotalSeconds
        if ($gap -gt $script:MaxLoopGapSeconds) { $script:MaxLoopGapSeconds=$gap }
        if ($gap -gt [math]::Max(5, $IntervalSeconds+3)) {
            $script:LargeLoopGapCount++
            Write-Log "[运行间隔] $([math]::Round($gap,3)) 秒；需结合 SleepStudy 判断是否睡眠"
        }
    }
    $script:LastTickUtc=$tickUtc
    $moduleEnabled = Test-PowerPolicyFeatureEnabled
    $caffeine = $moduleEnabled -and (Test-CaffeineActive)
    if ($DryRun) { if($moduleEnabled){Set-DesiredPowerPolicy (Get-DesiredPowerPolicy $caffeine)}; return }
    $snapshot = [ToolboxPower.Native]::GetSnapshot()
    foreach ($event in [ToolboxPower.Native]::DrainEvents()) { Write-Log "[原生通知] $event" }
    $source = [ToolboxPower.Native]::PowerSource()
    $reset = $snapshot.ResetVersion -ne $script:LastReset -or $source -ne $script:LastSource
    if ($caffeine) { [void][ToolboxPower.Native]::Hold($reset) }
    else { [ToolboxPower.Native]::Release() }
    # Never send SC_MONITORPOWER: it suspended this machine despite the SYSTEM hold.
    if($moduleEnabled){Set-DesiredPowerPolicy (Get-DesiredPowerPolicy $caffeine $snapshot.Lid)}
    $signature = "$moduleEnabled|$caffeine|$source|$($snapshot.Lid)|$($snapshot.LidCallbacks)|$($snapshot.PowerCallbacks)|$($snapshot.DisplayCallbacks)"
    if ($signature -ne $script:LastStatusSignature -or ([DateTime]::UtcNow - $script:LastStatusUtc).TotalSeconds -ge 20) {
        $status = [ordered]@{ version=2; pid=$PID; updatedUtc=[DateTime]::UtcNow.ToString('o');
            caffeine=$caffeine; moduleEnabled=$moduleEnabled; powerSource=$source; native=$snapshot; requestBalance=[ToolboxPower.Native]::RequestBalance;
            displayMethod='video-idle'; maxLoopGapSeconds=[math]::Round($script:MaxLoopGapSeconds,3);
            largeLoopGapCount=$script:LargeLoopGapCount; scheme="$([ToolboxPower.Native]::ActiveScheme())" }
        foreach($key in $script:ResidentIdentity.Keys){$status[$key]=$script:ResidentIdentity[$key]}
        Write-AtomicJson $status $script:StatusFile
        if ($signature -ne $script:LastStatusSignature) { Write-Log "[状态] Caffeine=$caffeine power=$source lid=$($snapshot.Lid) lidCallbacks=$($snapshot.LidCallbacks) powerCallbacks=$($snapshot.PowerCallbacks)" }
        $script:LastStatusSignature=$signature; $script:LastStatusUtc=[DateTime]::UtcNow
    }
    $script:LastReset=$snapshot.ResetVersion; $script:LastSource=$source
}

function Start-LidPolicyLoop {
    $mutex = [Threading.Mutex]::new($false, 'Global\PowerPolicyResident')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { Write-Log '[互斥] 已有常驻实例，退出'; return }
        # The task already runs elevated. Migrate only its own verified action;
        # never launch an elevator or change principal/permissions from the loop.
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        if(([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
            try { & (Join-Path $PSScriptRoot 'Repair-TaskHost.ps1') | Out-Null }
            catch { Write-Log ("[任务入口检查] "+$_.Exception.Message) }
        }
        # Capture once; source edits must not relabel an old running instance.
        $script:ResidentIdentity=Get-ToolboxPowerIdentity -PowerScript (Join-Path $PSScriptRoot 'PowerPolicy.ps1')
        Assert-LenovoDisabled
        [ToolboxPower.Native]::StartNotifications()
        $snapshot=[ToolboxPower.Native]::GetSnapshot()
        Write-Log "PowerPolicy v2 常驻启动 pid=$PID；原生注册 lid=$($snapshot.LidRegistrationError) power=$($snapshot.PowerRegistrationError) resume=$($snapshot.ResumeRegistrationError)"
        $script:LastReset=-1; $script:LastSource=-1
        $script:LastStatusSignature=''; $script:LastStatusUtc=[DateTime]::MinValue
        $script:LastTickUtc=$null; $script:MaxLoopGapSeconds=0; $script:LargeLoopGapCount=0
        $lastWakeBlock=[DateTime]::MinValue
        while (-not (Test-Path -LiteralPath $script:StopFile)) {
            Invoke-PowerPolicyTick
            if ((Test-PowerPolicyFeatureEnabled) -and ([DateTime]::UtcNow-$lastWakeBlock).TotalMinutes -ge 5) {
                Assert-LenovoDisabled
                try { Invoke-WakeBlock } catch { Write-Log "[唤醒检查] $($_.Exception.Message)" }
                $lastWakeBlock=[DateTime]::UtcNow
            }
            Start-Sleep -Seconds $IntervalSeconds
        }
    } finally {
        if ($acquired) {
            [ToolboxPower.Native]::Release()
            [ToolboxPower.Native]::StopNotifications()
            try { if(Test-PowerPolicyFeatureEnabled){Set-DesiredPowerPolicy (Get-DesiredPowerPolicy $false)} } catch { Write-Log "[恢复失败] $($_.Exception.Message)" }
            Write-Log '[退出] 请求已释放，恢复 Caffeine 关闭策略'
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
    }
}

function Stop-PowerPolicyResident {
    param([switch]$AllowLegacyTermination)
    Write-AtomicJson @{ stop=$true } $script:StopFile
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    $mutex=[Threading.Mutex]::new($false,'Global\PowerPolicyResident')
    try {
        do {
            $acquired=$false
            try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
            if ($acquired) { $mutex.ReleaseMutex(); return }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($AllowLegacyTermination) {
            # The pre-v2 launcher can leave its child alive after Stop-ScheduledTask.
            # Only terminate residents with this exact script path and the -Run token.
            $engine=Join-Path $PSScriptRoot 'PowerPolicy.ps1'
            $residents=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                $_.ProcessId -ne $PID -and $_.Name -in @('pwsh.exe','powershell.exe') -and
                $_.CommandLine -match [regex]::Escape($engine) -and
                $_.CommandLine -match '(?i)(?:^|\s)-Run(?:\s|$)'
            })
            foreach ($resident in $residents) {
                Write-Log "[迁移] 终止未响应停止信号的旧常驻 PID=$($resident.ProcessId)"
                Stop-Process -Id $resident.ProcessId -Force -ErrorAction Stop
            }
            Start-Sleep -Milliseconds 500
            $acquired=$false
            try { $acquired=$mutex.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $acquired=$true }
            if ($acquired) { $mutex.ReleaseMutex(); return }
        }
        throw '常驻进程未正常退出；未继续卸载或覆盖运行'
    } finally { $mutex.Dispose() }
}

function Install-PowerPolicyTasks {
    Assert-LenovoDisabled
    # Elevated installation must be complete before asking the user to close the lid.
    Save-OriginalPowerPolicy ([ToolboxPower.Native]::ActiveScheme()) (Get-PowerValues ([ToolboxPower.Native]::ActiveScheme()))
    $engine=Join-Path $PSScriptRoot 'PowerPolicy.ps1'
    # This resident supports 5.1; use the OS-owned host, not an app's versioned runtime.
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'System Windows PowerShell host is missing'}
    $vbs=Join-Path $PSScriptRoot 'Run-PowerPolicy.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { throw 'Run-PowerPolicy.vbs 缺失；安装已停止' }
    # Pass executable and script as separate WScript arguments; nested command-line
    # quotes break when pwsh.exe lives in Program Files / WindowsApps.
    $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "//B `"$vbs`" `"$exe`" `"$engine`""
    $principal=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $settings.Hidden=$true
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    foreach ($name in @("${TaskName}-OnLidEvent","${TaskName}-HibernateAt",'LidPolicy','LidPolicy-OnLidClose')) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -ErrorAction Stop
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        }
    }
    # Old resident does not understand the graceful stop file: task stop kills its native handles.
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Stop-PowerPolicyResident -AllowLegacyTermination
    if (Test-Path -LiteralPath $script:StopFile) { Remove-Item -LiteralPath $script:StopFile -Force }
    $startedUtc=[DateTime]::UtcNow
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $ready=$false
    for ($attempt=0; $attempt -lt 15; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-Path -LiteralPath $script:StatusFile) {
            try {
                $status=Get-Content -LiteralPath $script:StatusFile -Raw | ConvertFrom-Json
                if ($status.version -eq 2 -and [DateTime]$status.updatedUtc -gt $startedUtc -and
                    (Get-Process -Id $status.pid -ErrorAction SilentlyContinue)) { $ready=$true; break }
            } catch {}
        }
    }
    if (-not $ready) { throw '任务已注册但未收到新版常驻心跳，请检查任务退出码和日志' }
    Write-Log '[安装] 已更新静默常驻任务；每秒读取状态；保留现有 Watchdog 崩溃恢复'
}
