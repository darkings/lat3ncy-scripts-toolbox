$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ThemeUtils.ps1')

$config = Get-ThemeConfig

if ($config.general.switch_type -eq 'theme' -and $config.theme_settings.dark_theme_file)
{
  Apply-ThemeFile -ThemeInput $config.theme_settings.dark_theme_file | Out-Null
}
else
{
  if ($config.mode_settings.switch_apps)
  {
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -Value 0
  }
  if ($config.mode_settings.switch_system)
  {
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -Value 0
  }
}

if ($config.wallpaper.enabled -and $config.wallpaper.dark_wallpaper)
{
  Set-DesktopWallpaper -ImagePath $config.wallpaper.dark_wallpaper | Out-Null
}

if ($config.general.show_notification)
{
  Invoke-ThemeNotify -Type 'state' -Icon '🌙' -Text '已切换为深色模式'
}
