$ErrorActionPreference = 'Stop'

function Get-ThemeConfig
{
  $configFile = Join-Path $PSScriptRoot 'config.toml'
  $config = @{
    general = @{
      switch_type = 'mode'
      show_notification = $true
    }
    schedule = @{
      trigger_mode = 'sun'
      latitude = ''
      longitude = ''
      fixed_light_time = '07:00'
      fixed_dark_time = '19:00'
    }
    mode_settings = @{
      switch_apps = $true
      switch_system = $true
    }
    wallpaper = @{
      enabled = $false
      light_wallpaper = ''
      dark_wallpaper = ''
    }
    theme_settings = @{
      light_theme_file = 'aero.theme'
      dark_theme_file = 'dark.theme'
    }
  }

  if (-not (Test-Path -LiteralPath $configFile -PathType Leaf))
  {
    return $config
  }

  $currentSection = ''
  foreach ($line in (Get-Content -LiteralPath $configFile -Encoding UTF8))
  {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#'))
    {
      continue
    }

    if ($trimmed -match '^\[([a-zA-Z0-9_\-]+)\]$')
    {
      $currentSection = $matches[1]
      if (-not $config.ContainsKey($currentSection))
      {
        $config[$currentSection] = @{}
      }
      continue
    }

    if ($trimmed -match '^([a-zA-Z0-9_\-]+)\s*=\s*(.+)$')
    {
      $key = $matches[1]
      $valStr = $matches[2].Trim()

      if ($valStr -match '^("[^"]*"|''[^'']*'')\s*#')
      {
        $valStr = $matches[1]
      }

      $val = $valStr
      if ($valStr -match '^"(.*)"$' -or $valStr -match '^''(.*)''$')
      {
        $val = $matches[1] -replace '\\\\', '\'
      }
      elseif ($valStr -eq 'true')
      {
        $val = $true
      }
      elseif ($valStr -eq 'false')
      {
        $val = $false
      }

      if ($currentSection)
      {
        $config[$currentSection][$key] = $val
      }
    }
  }

  return $config
}

function Resolve-ThemeFilePath
{
  param([string]$ThemeInput)

  if (-not $ThemeInput)
  {
    return $null
  }

  # 1. 绝对路径或相对路径存在
  if (Test-Path -LiteralPath $ThemeInput -PathType Leaf)
  {
    return (Resolve-Path -LiteralPath $ThemeInput).Path
  }

  $nameWithExt = if ($ThemeInput.EndsWith('.theme', [System.StringComparison]::OrdinalIgnoreCase))
  {
    $ThemeInput
  }
  else
  {
    $ThemeInput + '.theme'
  }

  # 2. 系统主题目录 C:\Windows\Resources\Themes\
  $sysTheme = Join-Path 'C:\Windows\Resources\Themes' $nameWithExt
  if (Test-Path -LiteralPath $sysTheme -PathType Leaf)
  {
    return $sysTheme
  }

  # 3. 用户个性化主题目录 %LOCALAPPDATA%\Microsoft\Windows\Themes\
  $userThemeDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'
  $userTheme = Join-Path $userThemeDir $nameWithExt
  if (Test-Path -LiteralPath $userTheme -PathType Leaf)
  {
    return $userTheme
  }

  return $null
}

function Apply-ThemeFile
{
  param([string]$ThemeInput)

  $resolvedPath = Resolve-ThemeFilePath -ThemeInput $ThemeInput
  if (-not $resolvedPath)
  {
    return $false
  }

  try
  {
    Start-Process -FilePath $resolvedPath -WindowStyle Hidden
    Start-Sleep -Milliseconds 1200
    Stop-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue
    return $true
  }
  catch
  {
    return $false
  }
}

function Set-DesktopWallpaper
{
  param([string]$ImagePath)

  if (-not $ImagePath -or -not (Test-Path -LiteralPath $ImagePath -PathType Leaf))
  {
    return $false
  }

  $code = "using System;`nusing System.Runtime.InteropServices;`npublic class WallpaperNative {`n  [DllImport(`"user32.dll`", CharSet = CharSet.Auto)]`n  public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);`n  public static void SetWallpaper(string path) {`n    SystemParametersInfo(20, 0, path, 3);`n  }`n}"

  if (-not ([System.Management.Automation.PSTypeName]'WallpaperNative').Type)
  {
    Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
  }
  try
  {
    [WallpaperNative]::SetWallpaper($ImagePath)
    return $true
  }
  catch
  {
    return $false
  }
}

function Invoke-ThemeNotify
{
  param(
    [string]$Type = 'info',
    [string]$Icon = '☀️',
    [string]$Text = ''
  )
  try
  {
    $notifyLib = Join-Path (Split-Path $PSScriptRoot -Parent) 'raycast-scripts\_lib\notify.ps1'
    if (Test-Path -LiteralPath $notifyLib -PathType Leaf)
    {
      . $notifyLib
      Show-ToolboxNotify -Type $Type -Icon $Icon -Text $Text | Out-Null
    }
  }
  catch
  {
  }
}
