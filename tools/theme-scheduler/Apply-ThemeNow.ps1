# Apply-ThemeNow.ps1
# 登录时按当前时间对齐深浅色：日出前/日落后切深色，日出到日落之间切浅色。
# 已经是目标模式则跳过，避免每次开机都弹 HUD。

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig
$now = Get-Date
$schedule = Get-ThemeScheduleTimes -Config $config
$desired = Get-DesiredThemeMode -Now $now -RiseTime $schedule.RiseTime -SetTime $schedule.SetTime
$state = Get-ThemePersonalizeState

Write-ThemeLog ('Apply-Now start: now={0} rise={1} set={2} source={3} desired={4} apps={5} system={6}' -f `
    $now.ToString('HH:mm:ss'), `
    $schedule.RiseTime.ToString('HH:mm:ss'), `
    $schedule.SetTime.ToString('HH:mm:ss'), `
    $schedule.Source, `
    $desired, `
    $state.AppsUseLightTheme, `
    $state.SystemUsesLightTheme)

$wantLight = if ($desired -eq 'light') { 1 } else { 0 }
$already = $false

if ($config.general.switch_type -eq 'theme')
{
  # 完整 .theme 包不好可靠对比当前文件，登录时直接套一次目标主题
  $already = $false
}
else
{
  # mode：只检查配置里真正会改的那几项，避免 switch_system=false 时误判
  $appsOk = (-not $config.mode_settings.switch_apps) -or ($state.AppsUseLightTheme -eq $wantLight)
  $sysOk = (-not $config.mode_settings.switch_system) -or ($state.SystemUsesLightTheme -eq $wantLight)
  $already = $appsOk -and $sysOk
}

if ($already)
{
  # 颜色已经对时仍补套鼠标，避免刚加上光标资源后要等到下一次日出日落才生效。
  Set-WindowsCursorScheme -Mode $desired -Config $config | Out-Null
  # Keep the lock screen aligned with the current desktop wallpaper on logon as well.
  Sync-LockScreenWallpaper -Config $config -ImagePath '' | Out-Null
  Write-ThemeLog ("Apply-Now skip: already {0}" -f $desired)
  exit 0
}

$targetScript = if ($desired -eq 'light')
{
  Join-Path $PSScriptRoot 'Set-Theme-Light.ps1'
}
else
{
  Join-Path $PSScriptRoot 'Set-Theme-Dark.ps1'
}

if (-not (Test-Path -LiteralPath $targetScript -PathType Leaf))
{
  Write-ThemeLog ("Apply-Now failed: missing {0}" -f $targetScript)
  exit 1
}

& $targetScript
Set-WindowsCursorScheme -Mode $desired -Config $config | Out-Null
Write-ThemeLog ("Apply-Now switched to {0}" -f $desired)
