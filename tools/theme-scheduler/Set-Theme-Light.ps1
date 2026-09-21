$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig

if ($config.general.switch_type -eq 'theme' -and $config.theme_settings.light_theme_file)
{
  Apply-ThemeFile -ThemeInput $config.theme_settings.light_theme_file | Out-Null
}
else
{
  # mode：写 Apps/System 注册表，再按 switch_system 决定是否重启 Explorer 刷新托盘
  Set-WindowsColorMode -Mode 'light' -Config $config
}

if ($config.wallpaper.enabled -and $config.wallpaper.light_wallpaper)
{
  Set-DesktopWallpaper -ImagePath $config.wallpaper.light_wallpaper | Out-Null
}

# 颜色切完再换指针；缺文件或关闭 cursor.enabled 时静默跳过。
Set-WindowsCursorScheme -Mode 'light' -Config $config | Out-Null

if ($config.general.show_notification)
{
  Invoke-ThemeNotify -Type 'info' -Icon '☀️' -Text '已切换为浅色模式'
}
