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
      switch_system = $false
    }
    wallpaper = @{
      enabled = $false
      directory = ''
      pick = 'daily'
      light_wallpaper = ''
      dark_wallpaper = ''
      sync_lock_screen = $false
    }
    theme_settings = @{
      light_theme_file = 'light.theme'
      dark_theme_file = 'dark.theme'
    }
    cursor = @{
      enabled = $true
      light_dir = ''
      dark_dir = ''
      light_scheme = 'Cursor Concept 3 Light'
      dark_scheme = 'Cursor Concept 3 Dark'
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
      elseif ($valStr -match '^(true|false|-?\d+)\s*#')
      {
        $valStr = $matches[1]
      }
      elseif ($valStr.Contains('#') -and -not $valStr.StartsWith('"') -and -not $valStr.StartsWith("'"))
      {
        # 兜底：未加引号的值后带注释 e.g. true # comment
        $valStr = ($valStr -split '#')[0].Trim()
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
      elseif ($valStr -match '^-?\d+$')
      {
        $val = [int]$valStr
      }

      if ($currentSection)
      {
        $config[$currentSection][$key] = $val
      }
    }
  }

  return $config
}

function Get-ThemeCoordinates
{
  param($Config)

  # 优先用 config.toml 里的经纬度，避免开机时网络还没好就去查 IP
  if ($Config.schedule.latitude -and $Config.schedule.longitude)
  {
    return [pscustomobject]@{
      Lat = [double]$Config.schedule.latitude
      Lon = [double]$Config.schedule.longitude
      Source = 'config'
    }
  }

  try
  {
    $req = [System.Net.HttpWebRequest]::Create('https://ipinfo.io/json')
    $req.Proxy = $null
    $req.Timeout = 10000
    $req.UserAgent = 'curl/8.0'
    $req.Accept = 'application/json'
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $json = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    $r = $json | ConvertFrom-Json
    $loc = ($r.loc -split ',')
    if ($loc.Count -eq 2)
    {
      return [pscustomobject]@{ Lat = [double]$loc[0]; Lon = [double]$loc[1]; Source = 'ip' }
    }
  }
  catch
  {
  }

  return $null
}

function Get-ThemeSunTimes
{
  param([double]$Lat, [double]$Lon, [datetime]$Date = (Get-Date))

  # NOAA 日出日落：民用曙暮光 -0.833°。极昼/极夜时 cosHa 越界，返回 $null
  $latRad = $Lat * [Math]::PI / 180
  $n  = $Date.DayOfYear
  $hour = $Date.Hour + $Date.Minute / 60
  $gamma = 2 * [Math]::PI / 365 * ($n - 1 + ($hour - 12) / 24)

  $eqtime = 229.18 * (0.000075 + 0.001868 * [Math]::Cos($gamma) - 0.032077 * [Math]::Sin($gamma) `
      - 0.014615 * [Math]::Cos(2 * $gamma) - 0.040849 * [Math]::Sin(2 * $gamma))
  $decl = 0.006918 - 0.399912 * [Math]::Cos($gamma) + 0.070257 * [Math]::Sin($gamma) `
    - 0.006758 * [Math]::Cos(2 * $gamma) + 0.000907 * [Math]::Sin(2 * $gamma) `
    - 0.002697 * [Math]::Cos(3 * $gamma) + 0.00148 * [Math]::Sin(3 * $gamma)

  $cosHa = ([Math]::Cos(90.833 * [Math]::PI / 180) / ([Math]::Cos($latRad) * [Math]::Cos($decl)) `
      - [Math]::Tan($latRad) * [Math]::Tan($decl))
  if ($cosHa -gt 1 -or $cosHa -lt -1)
  {
    return $null
  }

  $ha = [Math]::Acos($cosHa)
  $utcRise = 720 - 4 * ($Lon + $ha * 180 / [Math]::PI) - $eqtime
  $utcSet  = 720 - 4 * ($Lon - $ha * 180 / [Math]::PI) - $eqtime

  $offset = [TimeZoneInfo]::Local.GetUtcOffset($Date).TotalMinutes
  $rise = (Get-Date -Date $Date).Date.AddMinutes($utcRise + $offset)
  $set  = (Get-Date -Date $Date).Date.AddMinutes($utcSet  + $offset)
  return [pscustomobject]@{ Sunrise = $rise; Sunset = $set }
}

function Get-ExistingThemeTaskTime
{
  param([string]$TaskName)

  # 登录时网络可能还没好。sun 模式算不出来时，复用已经校准过的 Daily 触发时间
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $task)
  {
    return $null
  }

  $daily = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' }) | Select-Object -First 1
  if (-not $daily -or -not $daily.StartBoundary)
  {
    return $null
  }

  try
  {
    return [datetime]::Parse($daily.StartBoundary)
  }
  catch
  {
    return $null
  }
}

function Get-ThemeScheduleTimes
{
  param($Config = $null)

  if (-not $Config)
  {
    $Config = Get-ThemeConfig
  }

  $fallbackLight = if ($Config.schedule.fixed_light_time) { $Config.schedule.fixed_light_time } else { '07:00' }
  $fallbackDark  = if ($Config.schedule.fixed_dark_time) { $Config.schedule.fixed_dark_time } else { '19:00' }

  if ($Config.schedule.trigger_mode -eq 'fixed')
  {
    return [pscustomobject]@{
      RiseTime = [datetime]::Parse($fallbackLight)
      SetTime = [datetime]::Parse($fallbackDark)
      TriggerMode = 'fixed'
      Source = 'fixed'
    }
  }

  $coords = Get-ThemeCoordinates -Config $Config
  if ($coords)
  {
    $sun = Get-ThemeSunTimes -Lat $coords.Lat -Lon $coords.Lon
    if ($null -ne $sun)
    {
      return [pscustomobject]@{
        RiseTime = $sun.Sunrise
        SetTime = $sun.Sunset
        TriggerMode = 'sun'
        Source = $coords.Source
      }
    }
  }

  # 1) 复用已注册的 Theme-Light / Theme-Dark 时间  2) 再退到 config 里的固定备用时间
  $existingRise = Get-ExistingThemeTaskTime -TaskName 'Theme-Light'
  $existingSet = Get-ExistingThemeTaskTime -TaskName 'Theme-Dark'
  if ($existingRise -and $existingSet)
  {
    return [pscustomobject]@{
      RiseTime = $existingRise
      SetTime = $existingSet
      TriggerMode = 'sun'
      Source = 'existing-task'
    }
  }

  return [pscustomobject]@{
    RiseTime = [datetime]::Parse($fallbackLight)
    SetTime = [datetime]::Parse($fallbackDark)
    TriggerMode = 'sun'
    Source = 'fallback'
  }
}

function Get-DesiredThemeMode
{
  param(
    [datetime]$Now = (Get-Date),
    [datetime]$RiseTime,
    [datetime]$SetTime
  )

  # 日出前、日落及之后 -> 深色；日出到日落之间 -> 浅色
  if ($Now -lt $RiseTime -or $Now -ge $SetTime)
  {
    return 'dark'
  }
  return 'light'
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
  if (-not $env:LOCALAPPDATA) { return $null }
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

function Get-ThemeRepoRoot
{
  # ThemeUtils.ps1 在 tools/theme-scheduler，仓库根是再上两级。
  return Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

function Resolve-ThemeCursorDirectory
{
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('light', 'dark')]
    [string]$Mode,
    $Config
  )

  $repoRoot = Get-ThemeRepoRoot
  $configured = ''
  if ($Config.cursor)
  {
    $configured = if ($Mode -eq 'light') { [string]$Config.cursor.light_dir } else { [string]$Config.cursor.dark_dir }
  }

  # 显式配置的目录优先，不做尺寸推导。
  if ($configured)
  {
    $dir = $configured
    if (-not [IO.Path]::IsPathRooted($dir))
    {
      $dir = Join-Path $repoRoot $dir
    }
    return $dir
  }

  # 按配色解析目录：resources\cursors\<配色>。
  # 配色由 config 的 light_color / dark_color 指定，默认 light / dark。
  # 资源包内含 32/48/64/96/128 五个原生尺寸，覆盖 100%-200% DPI，
  # 系统按 DPI 请求任意尺寸都能命中原生资源，不会被缩放导致模糊或视觉过大。
  $color = $Mode
  if ($Config.cursor)
  {
    $key = if ($Mode -eq 'light') { 'light_color' } else { 'dark_color' }
    if ($Config.cursor.ContainsKey($key) -and $Config.cursor.$key)
    {
      $color = [string]$Config.cursor.$key
    }
  }
  $colorDir = Join-Path $repoRoot ('resources\cursors\' + $color)
  if (Test-Path -LiteralPath $colorDir -PathType Container)
  {
    return $colorDir
  }

  # 回退：按模式名解析 resources\cursors\<mode>。
  $baseDir = Join-Path $repoRoot ('resources\cursors\' + $Mode)
  Write-ThemeLog ("Cursor color dir missing, fallback to base: {0}" -f $colorDir)
  return $baseDir
}

function Ensure-CursorNative
{
  # CursorNative 保留作诊断。套用路径不要调用 SetFile / SetSystemCursor。
  # powershell.exe 不感知 DPI，SetSystemCursor 塞 64px 会被 200% 缩放再放大成 128。
  if (([System.Management.Automation.PSTypeName]'CursorNative').Type)
  {
    return $true
  }

  $code = @'
using System;
using System.Runtime.InteropServices;
public static class CursorNative {
  // LoadCursorFromFile 只返回 32x32 位图，会忽略 .cur 里的更大尺寸；
  // 必须用 LoadImage + LR_LOADFROMFILE 才能拿到原始尺寸（如 64/96/144）。
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern IntPtr LoadImage(IntPtr hinst, string lpszName, uint uType, int cxDesired, int cyDesired, uint fuLoad);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern IntPtr CopyIcon(IntPtr hIcon);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool DestroyCursor(IntPtr hCursor);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool SetSystemCursor(IntPtr hcur, uint id);
  [DllImport("user32.dll")]
  public static extern bool GetCursorInfo(ref CURSORINFO info);
  [DllImport("user32.dll")]
  public static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO info);
  [DllImport("gdi32.dll")]
  public static extern bool DeleteObject(IntPtr ho);
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct CURSORINFO {
    public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct ICONINFO {
    public bool fIcon; public int xHotspot; public int yHotspot; public IntPtr hbmMask; public IntPtr hbmColor;
  }
  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")]
  public static extern int GetSystemMetricsForDpi(int nIndex, uint dpi);
  // powershell.exe 默认 DPI 不感知：GetSystemMetrics / GetDeviceCaps 在 200% 下都返回 96dpi 的 32。
  // AppliedDPI 是系统真实缩放。200% = 192 -> SM_CXCURSOR 64。
  public static int ExpectedSize() {
    int dpi = 96;
    try {
      object v = Microsoft.Win32.Registry.GetValue(
        @"HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics", "AppliedDPI", 96);
      if (v != null) dpi = Convert.ToInt32(v);
    } catch { dpi = 96; }
    if (dpi < 96) dpi = 96;
    int cx = GetSystemMetricsForDpi(13, (uint)dpi);
    if (cx <= 0) cx = 32;
    return cx;
  }
  // 从文件加载句柄；SetSystemCursor 会 Destroy 传入的句柄，所以必须 CopyIcon。
  // size 显式指定目标像素：多尺寸 .cur 里 cx/cy=0 只会取第一个条目（32px），
  // 必须传具体值才能命中 32/64/96/144 的原生资源。
  public static bool SetFile(string path, uint id, int size) {
    if (string.IsNullOrEmpty(path)) return false;
    // IMAGE_CURSOR=2, LR_LOADFROMFILE=0x10
    IntPtr loaded = LoadImage(IntPtr.Zero, path, 2, size, size, 0x10);
    if (loaded == IntPtr.Zero) return false;
    IntPtr copy = CopyIcon(loaded);
    DestroyCursor(loaded);
    if (copy == IntPtr.Zero) return false;
    return SetSystemCursor(copy, id);
  }
  // 核对当前箭头是不是彩色自定义指针。系统默认是 1bpp、热点 10,10。
  public static string LiveArrow() {
    CURSORINFO ci = new CURSORINFO();
    ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
    if (!GetCursorInfo(ref ci) || ci.hCursor == IntPtr.Zero) return "fail";
    ICONINFO ii;
    if (!GetIconInfo(ci.hCursor, out ii)) return "noinfo";
    try {
      if (ii.hbmColor == IntPtr.Zero)
        return string.Format("hot={0},{1} mono", ii.xHotspot, ii.yHotspot);
      return string.Format("hot={0},{1} color", ii.xHotspot, ii.yHotspot);
    } finally {
      if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
      if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
    }
  }
}
'@
  try
  {
    Add-Type -TypeDefinition $code -ErrorAction Stop
    return $true
  }
  catch
  {
    Write-ThemeLog ("CursorNative load failed: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Sync-ThemeFileCursors
{
  param(
    [Parameter(Mandatory = $true)]$Roles,
    [Parameter(Mandatory = $true)]$Paths,
    [Parameter(Mandatory = $true)][string]$SchemeName
  )

  # 锁屏/切回会话时 Win11 会按 CurrentTheme 重载指针。不把自定义路径写进 .theme，系统就会打回 Windows_11_dark/light。
  $themesKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
  $themePath = (Get-ItemProperty -LiteralPath $themesKey -Name CurrentTheme -ErrorAction SilentlyContinue).CurrentTheme
  if (-not $themePath -or -not (Test-Path -LiteralPath $themePath -PathType Leaf))
  {
    Write-ThemeLog 'Cursor theme file skip: CurrentTheme missing'
    return
  }

  # 第一次改 CurrentTheme 前留一份备份，避免写坏 UTF-16 .theme。
  $backupDir = Join-Path $PSScriptRoot 'backup-themes'
  if (-not (Test-Path -LiteralPath $backupDir -PathType Container))
  {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
  }
  $backupPath = Join-Path $backupDir (([IO.Path]::GetFileNameWithoutExtension($themePath)) + '.theme.before-cursor.bak')
  if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf))
  {
    Copy-Item -LiteralPath $themePath -Destination $backupPath -Force
    Write-ThemeLog ("Cursor theme file backup: {0}" -f $backupPath)
  }

  $unicode = [Text.Encoding]::Unicode
  $bytes = [IO.File]::ReadAllBytes($themePath)
  $isUnicode = ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
  $text = if ($isUnicode) { $unicode.GetString($bytes, 2, $bytes.Length - 2) } else { [Text.Encoding]::UTF8.GetString($bytes) }
  $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $rawLines = [regex]::Split($text, '\r\n|\n|\r')

  $wanted = @{}
  foreach ($role in $Roles)
  {
    $wanted[$role.Name] = [string]$Paths[$role.Name]
  }
  $wanted['DefaultValue'] = $SchemeName
  # SchemeName 必须写成自定义方案名。若保留原主题里的 @mmres.dll,-800（默认方案 ID），
  # 重启/锁屏后 Windows 会按该 ID 把指针打回系统默认。
  $wanted['SchemeName'] = $SchemeName
  $outLines = New-Object System.Collections.Generic.List[string]
  $inSection = $false
  $wroteSection = $false
  $seen = @{}
  foreach ($line in $rawLines)
  {
    if ($line -match '^\[(.+)\]\s*$')
    {
      if ($inSection)
      {
        foreach ($name in $wanted.Keys)
        {
          if (-not $seen.ContainsKey($name))
          {
            $outLines.Add($name + '=' + $wanted[$name])
          }
        }
        $inSection = $false
      }
      $inSection = ($matches[1] -eq 'Control Panel\Cursors')
      if ($inSection)
      {
        $wroteSection = $true
        $seen = @{}
      }
      $outLines.Add($line)
      continue
    }

    if ($inSection -and $line -match '^([^=]+)=(.*)$')
    {
      $name = $matches[1].Trim()
      if ($wanted.ContainsKey($name))
      {
        # 同名键只写一次；重复行（如残留的 SchemeName=@mmres.dll,-800）直接丢弃。
        if (-not $seen.ContainsKey($name))
        {
          $outLines.Add($name + '=' + $wanted[$name])
          $seen[$name] = $true
        }
        continue
      }
    }
    $outLines.Add($line)
  }

  if ($inSection)
  {
    foreach ($name in $wanted.Keys)
    {
      if (-not $seen.ContainsKey($name))
      {
        $outLines.Add($name + '=' + $wanted[$name])
      }
    }
  }
  elseif (-not $wroteSection)
  {
    if ($outLines.Count -gt 0 -and $outLines[$outLines.Count - 1] -ne '')
    {
      $outLines.Add('')
    }
    $outLines.Add('[Control Panel\Cursors]')
    foreach ($name in $wanted.Keys)
    {
      $outLines.Add($name + '=' + $wanted[$name])
    }
  }

  $text = ($outLines -join $newline)
  if (-not $text.EndsWith($newline))
  {
    $text += $newline
  }

  if ($isUnicode)
  {
    [IO.File]::WriteAllBytes($themePath, ($unicode.GetPreamble() + $unicode.GetBytes($text)))
  }
  else
  {
    [IO.File]::WriteAllText($themePath, $text, (New-Object Text.UTF8Encoding $false))
  }
  Write-ThemeLog ("Cursor theme file synced: {0}" -f $themePath)
}

function Disable-AccessibilityCursorOverlay
{
  # Win11「辅助功能 → 鼠标指针样式」一旦设了颜色，DWM 就画彩色系统指针，
  # 鼠标属性里的整套 .cur/.ani 方案不会显示。0xFFFFFFFF = Windows 默认，让方案文件生效。
  $key = 'HKCU:\Software\Microsoft\Accessibility'
  if (-not (Test-Path -LiteralPath $key))
  {
    return $false
  }

  $current = (Get-ItemProperty -LiteralPath $key -Name CursorColor -ErrorAction SilentlyContinue).CursorColor
  if ($null -eq $current)
  {
    return $false
  }

  $asUint = [uint32]0
  try
  {
    $asUint = [uint32][int]$current
  }
  catch
  {
    try { $asUint = [uint32]$current } catch { $asUint = 0 }
  }

  if ($asUint -eq [uint32]::MaxValue)
  {
    return $false
  }

  Set-ItemProperty -LiteralPath $key -Name CursorColor -Value ([int]-1) -Type DWord
  # 只清颜色。不要在这里写 CursorSize，否则会和系统 DPI 选档打架。
  # 尺寸由 SPI_SETCURSORS 按注册表和当前 DPI 决定。
  Write-ThemeLog ("Cursor overlay cleared: CursorColor={0} -> default" -f $current)
  return $true
}

function Set-WindowsCursorScheme
{
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('light', 'dark')]
    [string]$Mode,
    $Config
  )

  if (-not $Config.cursor -or -not $Config.cursor.enabled)
  {
    Write-ThemeLog 'Cursor switch skipped: disabled'
    return $false
  }

  $dir = Resolve-ThemeCursorDirectory -Mode $Mode -Config $Config
  if (-not (Test-Path -LiteralPath $dir -PathType Container))
  {
    Write-ThemeLog ("Cursor switch skipped: missing {0}" -f $dir)
    return $false
  }

  # 角色名对应 HKCU\Control Panel\Cursors 的值名；Id 是 SetSystemCursor 的 OCR_*。
  $roles = @(
    @{ Name = 'Arrow'; File = 'arrow.cur'; Id = 32512 },
    @{ Name = 'Help'; File = 'help.cur'; Id = 32651 },
    @{ Name = 'AppStarting'; File = 'appstarting.ani'; Id = 32650 },
    @{ Name = 'Wait'; File = 'wait.ani'; Id = 32514 },
    @{ Name = 'Crosshair'; File = 'crosshair.cur'; Id = 32515 },
    @{ Name = 'IBeam'; File = 'ibeam.cur'; Id = 32513 },
    @{ Name = 'NWPen'; File = 'nwpen.cur'; Id = 32631 },
    @{ Name = 'No'; File = 'no.cur'; Id = 32648 },
    @{ Name = 'SizeNS'; File = 'sizens.cur'; Id = 32645 },
    @{ Name = 'SizeWE'; File = 'sizewe.cur'; Id = 32644 },
    @{ Name = 'SizeNWSE'; File = 'sizenwse.cur'; Id = 32642 },
    @{ Name = 'SizeNESW'; File = 'sizenesw.cur'; Id = 32643 },
    @{ Name = 'SizeAll'; File = 'sizeall.cur'; Id = 32646 },
    @{ Name = 'UpArrow'; File = 'uparrow.cur'; Id = 32516 },
    @{ Name = 'Hand'; File = 'hand.cur'; Id = 32649 },
    @{ Name = 'Person'; File = 'person.cur'; Id = 32672 },
    @{ Name = 'Pin'; File = 'pin.cur'; Id = 32671 }
  )

  $paths = @{}
  foreach ($role in $roles)
  {
    $path = Join-Path $dir $role.File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
      Write-ThemeLog ("Cursor switch skipped: missing {0}" -f $path)
      return $false
    }
    $paths[$role.Name] = $path
  }

  $schemeName = if ($Mode -eq 'light') { [string]$Config.cursor.light_scheme } else { [string]$Config.cursor.dark_scheme }
  if (-not $schemeName)
  {
    $schemeName = if ($Mode -eq 'light') { 'Cursor Concept 3 Light' } else { 'Cursor Concept 3 Dark' }
  }

  # Windows 方案字符串顺序固定，Person/Pin 是 Win10+ 扩展。
  $schemeValue = @(
    $paths.Arrow, $paths.Help, $paths.AppStarting, $paths.Wait, $paths.Crosshair, $paths.IBeam,
    $paths.NWPen, $paths.No, $paths.SizeNS, $paths.SizeWE, $paths.SizeNWSE, $paths.SizeNESW,
    $paths.SizeAll, $paths.UpArrow, $paths.Hand, $paths.Person, $paths.Pin
  ) -join ','

  $key = 'HKCU:\Control Panel\Cursors'
  $schemesKey = 'HKCU:\Control Panel\Cursors\Schemes'
  if (-not (Test-Path -LiteralPath $schemesKey))
  {
    New-Item -Path $schemesKey -Force | Out-Null
  }

  Set-ItemProperty -LiteralPath $schemesKey -Name $schemeName -Value $schemeValue -Type String
  # REG_SZ 方案名；鼠标属性读的是这个默认值。
  Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $schemeName -Type String
  Set-ItemProperty -LiteralPath $key -Name 'Scheme Source' -Value 1 -Type DWord

  # 不写 CursorBaseSize / CursorSize，也不调用 SetSystemCursor。
  # powershell.exe 不感知 DPI。它用 SetSystemCursor 塞 64px 句柄时，
  # 200% 缩放的系统会再放大成 128；登录/主题重载又按注册表加载 64，于是一会儿大一会儿小。
  # 持久化只写注册表路径和 .theme。当前会话用 SPI_SETCURSORS 让系统自己按 DPI 选尺寸。
  foreach ($role in $roles)
  {
    # REG_EXPAND_SZ：和 Install.inf / 鼠标属性写入类型一致。
    Set-ItemProperty -LiteralPath $key -Name $role.Name -Value $paths[$role.Name] -Type ExpandString
  }

  # 辅助功能彩色指针会盖住整套方案。只清颜色，不写 CursorSize。
  $overlayCleared = $false
  try
  {
    $overlayCleared = Disable-AccessibilityCursorOverlay
  }
  catch
  {
    Write-ThemeLog ("Cursor overlay clear failed: {0}" -f $_.Exception.Message)
  }

  try
  {
    Sync-ThemeFileCursors -Roles $roles -Paths $paths -SchemeName $schemeName
  }
  catch
  {
    Write-ThemeLog ("Cursor theme file sync failed: {0}" -f $_.Exception.Message)
  }

  $setCount = $roles.Count
  $live = 'registry'
  if (-not ('SystemParametersInfoCursor' -as [type]))
  {
    $spiCode = "using System; using System.Runtime.InteropServices; public static class SystemParametersInfoCursor { [DllImport(`"user32.dll`", SetLastError=true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni); }"
    Add-Type -TypeDefinition $spiCode -ErrorAction Stop
  }
  try
  {
    # SPI_SETCURSORS = 0x0057. 让系统按注册表和当前 DPI 自己选尺寸。
    [SystemParametersInfoCursor]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0x0003) | Out-Null
    $live = 'reloaded'
  }
  catch
  {
    Write-ThemeLog ("Cursor SPI_SETCURSORS failed: {0}" -f $_.Exception.Message)
    $live = 'reload-fail'
  }

  Write-ThemeLog ("Cursor switch done: mode={0} scheme={1} set={2}/{3} live={4} overlay={5} dir={6}" -f `
      $Mode, $schemeName, $setCount, $roles.Count, $live, $overlayCleared, $dir)
  return $true
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

function Get-WallpaperImageFile
{
  param([Parameter(Mandatory = $true)][string]$Directory)

  return @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -match '(?i)^\.(jpg|jpeg|png|bmp)$' })
}

function Resolve-WallpaperImage
{
  param($Config, [Parameter(Mandatory = $true)][ValidateSet('light', 'dark')][string]$Mode)

  $wallpaper = $Config.wallpaper
  $directory = [string]$wallpaper.directory

  # 1) Explicit file wins: absolute path, or a name relative to wallpaper.directory.
  $explicit = if ($Mode -eq 'light') { [string]$wallpaper.light_wallpaper } else { [string]$wallpaper.dark_wallpaper }
  if ($explicit)
  {
    $candidate = $explicit
    if (-not [System.IO.Path]::IsPathRooted($candidate) -and $directory)
    {
      $candidate = Join-Path $directory $candidate
    }
    if (Test-Path -LiteralPath $candidate -PathType Leaf)
    {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
    Write-ThemeLog ("Wallpaper explicit path missing: {0}" -f $candidate)
  }

  if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container))
  {
    return $null
  }

  # 2) Mode subdirectory: light/day/sunrise vs dark/night/sunset.
  $subNames = if ($Mode -eq 'light') { @('light', 'day', 'sunrise') } else { @('dark', 'night', 'sunset') }
  $images = @()
  foreach ($subName in $subNames)
  {
    $subDirectory = Join-Path $directory $subName
    if (Test-Path -LiteralPath $subDirectory -PathType Container)
    {
      $images = @(Get-WallpaperImageFile -Directory $subDirectory)
      if ($images.Count -gt 0)
      {
        break
      }
    }
  }

  # 3) Flat pool: every image in the directory.
  if ($images.Count -eq 0)
  {
    $images = @(Get-WallpaperImageFile -Directory $directory)
  }
  if ($images.Count -eq 0)
  {
    Write-ThemeLog ("Wallpaper directory has no images: {0}" -f $directory)
    return $null
  }

  $sorted = @($images | Sort-Object FullName)
  $count = $sorted.Count
  $pick = if ($wallpaper.pick) { [string]$wallpaper.pick } else { 'daily' }
  if ($pick -eq 'random')
  {
    $index = Get-Random -Minimum 0 -Maximum $count
  }
  elseif ($pick -eq 'each')
  {
    # Sunrise and sunset each advance one slot; stable inside a time slot without a state file.
    $index = (((Get-Date).Date.DayOfYear * 2) + $(if ($Mode -eq 'dark') { 1 } else { 0 })) % $count
  }
  else
  {
    $index = (Get-Date).Date.DayOfYear % $count
  }
  return $sorted[$index].FullName
}

function Sync-LockScreenWallpaper
{
  param($Config, [string]$ImagePath)

  if (-not $Config.wallpaper.sync_lock_screen)
  {
    return $false
  }

  $scriptPath = Join-Path $PSScriptRoot 'Set-LockScreenFromWallpaper.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf))
  {
    Write-ThemeLog 'LockScreen skipped: Set-LockScreenFromWallpaper.ps1 missing'
    return $false
  }

  # WinRT lock screen API requires Windows PowerShell 5.1 (System.Runtime.WindowsRuntime).
  # Spawn a child host so the script's exit code stays contained.
  $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $winPs -PathType Leaf))
  {
    $winPs = 'powershell.exe'
  }

  $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
  $source = 'desktop-wallpaper'
  if ($ImagePath -and (Test-Path -LiteralPath $ImagePath -PathType Leaf))
  {
    $arguments += @('-ImagePath', $ImagePath)
    $source = $ImagePath
  }

  try
  {
    & $winPs @arguments | Out-Null
    if ($LASTEXITCODE -ne 0)
    {
      throw ("exit code {0}" -f $LASTEXITCODE)
    }
    Write-ThemeLog ("LockScreen synced from {0}" -f $source)
    return $true
  }
  catch
  {
    Write-ThemeLog ("LockScreen sync failed: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Get-ThemeHiddenAction
{
  param([Parameter(Mandatory = $true)][string]$ScriptPath)

  $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
  return New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
}

function Get-ThemeTaskSettings
{
  param([switch]$DisableStartWhenAvailable)

  # Light/Dark 必须关掉 StartWhenAvailable：关机错过的日出/日落不能在开机时补跑，否则会和登录对齐任务抢最后一次切换
  $settings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -WakeToRun `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

  if (-not $DisableStartWhenAvailable)
  {
    $settings.StartWhenAvailable = $true
  }
  else
  {
    $settings.StartWhenAvailable = $false
  }

  return $settings
}

function Get-ThemeLogonTrigger
{
  param([string]$Delay = 'PT10S')

  # 登录后稍等 DWM / Explorer，再按当前时间对齐主题
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $trigger.Delay = $Delay
  return $trigger
}

function Get-ThemeSessionStateTrigger
{
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ConsoleConnect', 'SessionUnlock')]
    [string]$StateChange
  )

  # New-ScheduledTaskTrigger 没有解锁/切回控制台。CIM 的 SessionStateChange 才能在锁屏回来时重套指针。
  # TASK_SESSION_STATE_CHANGE_TYPE: ConsoleConnect=1, SessionUnlock=8
  $id = if ($StateChange -eq 'SessionUnlock') { 8 } else { 1 }
  $class = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger' -ErrorAction Stop
  $trigger = New-CimInstance -CimClass $class -ClientOnly
  $trigger.Enabled = $true
  $trigger.StateChange = $id
  # 解锁当下立刻跑。Win11 延迟覆盖由 Apply-CursorsNow 自己补套，不要再 Delay 触发器。
  $trigger.Delay = 'PT0S'
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  if ($user)
  {
    $trigger.UserId = $user
  }
  return $trigger
}

function Get-ThemeCursorUnlockTriggers
{
  # 锁屏解锁、Win+L 回来、切回本机会话都要抢在系统 .theme 把指针盖掉之前。
  return @(
    (Get-ThemeSessionStateTrigger -StateChange 'SessionUnlock'),
    (Get-ThemeSessionStateTrigger -StateChange 'ConsoleConnect')
  )
}

function Ensure-ThemeScheduledTask
{
  param(
    [Parameter(Mandatory = $true)][string]$TaskName,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    $Trigger = $null,
    [switch]$DisableStartWhenAvailable
  )

  $action = Get-ThemeHiddenAction -ScriptPath $ScriptPath
  $settings = Get-ThemeTaskSettings -DisableStartWhenAvailable:$DisableStartWhenAvailable
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing)
  {
    if ($null -ne $Trigger)
    {
      Repair-ThemeScheduledTaskWindow -TaskName $TaskName -ScriptPath $ScriptPath -Trigger $Trigger -DisableStartWhenAvailable:$DisableStartWhenAvailable
    }
    else
    {
      Repair-ThemeScheduledTaskWindow -TaskName $TaskName -ScriptPath $ScriptPath -DisableStartWhenAvailable:$DisableStartWhenAvailable
    }
    return
  }

  $register = @{
    TaskName = $TaskName
    Action = $action
    Settings = $settings
    Description = "Theme Scheduler - $TaskName"
  }
  if ($null -ne $Trigger)
  {
    $register.Trigger = $Trigger
  }
  Register-ScheduledTask @register | Out-Null
}

function Repair-ThemeScheduledTaskWindow
{
  param(
    [Parameter(Mandatory = $true)][string]$TaskName,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    $Trigger = $null,
    [switch]$DisableStartWhenAvailable
  )

  $action = Get-ThemeHiddenAction -ScriptPath $ScriptPath
  $settings = Get-ThemeTaskSettings -DisableStartWhenAvailable:$DisableStartWhenAvailable
  if ($null -ne $Trigger)
  {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings -Trigger $Trigger | Out-Null
  }
  else
  {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings | Out-Null
  }
}

function Write-ThemeLog
{
  param([string]$Message)

  # 计划任务无控制台，切换结果只写本地日志，便于核对注册表和 Explorer 重启
  $logFile = Join-Path $PSScriptRoot 'theme-scheduler.log'
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
  Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
}

function Get-ThemePersonalizeState
{
  $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  $themes = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
  return [pscustomobject]@{
    AppsUseLightTheme    = (Get-ItemProperty -LiteralPath $personalize -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
    SystemUsesLightTheme = (Get-ItemProperty -LiteralPath $personalize -Name SystemUsesLightTheme -ErrorAction SilentlyContinue).SystemUsesLightTheme
    CurrentTheme         = (Get-ItemProperty -LiteralPath $themes -Name CurrentTheme -ErrorAction SilentlyContinue).CurrentTheme
  }
}

function Ensure-ThemeRefreshNative
{
  # 一次性加载 user32 / uxtheme 刷新入口。序号导出随系统版本变化，调用处必须单独 catch
  if (([System.Management.Automation.PSTypeName]'ThemeRefreshNative').Type)
  {
    return $true
  }

  $code = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ThemeRefreshNative {
  public const uint WM_SETTINGCHANGE = 0x001A;
  public const uint WM_THEMECHANGED = 0x031A;
  public const uint WM_DWMCOLORIZATIONCOLORCHANGED = 0x0320;
  public const uint WM_EXPLORER_EXIT = 0x5B4;
  public const uint SMTO_ABORTIFHUNG = 0x0002;

  [DllImport("user32.dll", EntryPoint = "SendMessageTimeout", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr SendMessageTimeoutStr(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

  [DllImport("user32.dll", EntryPoint = "SendMessageTimeout", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr SendMessageTimeoutPtr(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

  [DllImport("user32.dll")]
  public static extern bool UpdatePerUserSystemParameters(uint flags, bool force);

  [DllImport("uxtheme.dll", EntryPoint = "#104")]
  public static extern void RefreshImmersiveColorPolicyState();

  [DllImport("uxtheme.dll", EntryPoint = "#136")]
  public static extern void FlushMenuThemes();

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

  [DllImport("user32.dll")]
  private static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

  [DllImport("dwmapi.dll")]
  private static extern int DwmSetWindowAttribute(IntPtr hWnd, int attribute, ref int value, int size);

  [DllImport("user32.dll")]
  private static extern bool RedrawWindow(IntPtr hWnd, IntPtr updateRect, IntPtr updateRgn, uint flags);

  private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  private const uint RDW_INVALIDATE = 0x0001;
  private const uint RDW_UPDATENOW = 0x0100;
  private const uint RDW_ALLCHILDREN = 0x0080;
  private const uint RDW_FRAME = 0x0400;
  private const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
  private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  private const int DWMWA_BORDER_COLOR = 34;
  private const int DWMWA_CAPTION_COLOR = 35;
  private const int DWMWA_TEXT_COLOR = 36;
  private static int _explorerDark;
  private static int _explorerRefreshed;

  private static void SetExplorerFrameColors(IntPtr hWnd, bool darkMode) {
    int dark = darkMode ? 1 : 0;
    int hr = DwmSetWindowAttribute(hWnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
    if (hr != 0) DwmSetWindowAttribute(hWnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref dark, sizeof(int));

    // COLORREF 0x00BBGGRR。Apps-only 时用纯色标题栏贴应用深浅色，不改 SystemUsesLightTheme。
    int caption = darkMode ? 0x00202020 : 0x00F3F3F3;
    int border = darkMode ? 0x00202020 : 0x00E5E5E5;
    int text = darkMode ? 0x00FFFFFF : 0x001A1A1A;
    DwmSetWindowAttribute(hWnd, DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
    DwmSetWindowAttribute(hWnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
    DwmSetWindowAttribute(hWnd, DWMWA_TEXT_COLOR, ref text, sizeof(int));
  }

  private static bool EnumExplorerWindows(IntPtr hWnd, IntPtr lParam) {
    if (!IsWindowVisible(hWnd)) return true;
    var name = new StringBuilder(128);
    GetClassName(hWnd, name, name.Capacity);
    var className = name.ToString();
    if (className != "CabinetWClass" && className != "ExploreWClass") return true;

    IntPtr result;
    SendMessageTimeoutStr(hWnd, WM_SETTINGCHANGE, IntPtr.Zero, "ImmersiveColorSet", SMTO_ABORTIFHUNG, 2000, out result);
    SendMessageTimeoutPtr(hWnd, WM_THEMECHANGED, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 2000, out result);
    SendMessageTimeoutPtr(hWnd, WM_DWMCOLORIZATIONCOLORCHANGED, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 2000, out result);

    SetExplorerFrameColors(hWnd, _explorerDark != 0);
    RedrawWindow(hWnd, IntPtr.Zero, IntPtr.Zero,
      RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_FRAME);
    _explorerRefreshed++;
    return true;
  }

  public static int RefreshExplorerWindows(bool darkMode) {
    _explorerDark = darkMode ? 1 : 0;
    _explorerRefreshed = 0;
    EnumWindowsProc callback = EnumExplorerWindows;
    EnumWindows(callback, IntPtr.Zero);
    GC.KeepAlive(callback);
    return _explorerRefreshed;
  }
}
'@
  try
  {
    Add-Type -TypeDefinition $code -ErrorAction Stop
    return $true
  }
  catch
  {
    Write-ThemeLog ("ThemeRefreshNative load failed: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Send-ThemeBroadcast
{
  param([string]$SettingName = 'ImmersiveColorSet')

  if (-not (Ensure-ThemeRefreshNative))
  {
    return
  }

  $broadcast = [IntPtr]0xffff
  $result = [IntPtr]::Zero
  $flags = [ThemeRefreshNative]::SMTO_ABORTIFHUNG

  # 广播给所有顶层窗口，再点名任务栏和溢出区，提高托盘宿主收到 ImmersiveColorSet 的概率
  [ThemeRefreshNative]::SendMessageTimeoutStr($broadcast, [ThemeRefreshNative]::WM_SETTINGCHANGE, [IntPtr]::Zero, $SettingName, $flags, 5000, [ref]$result) | Out-Null
  [ThemeRefreshNative]::SendMessageTimeoutPtr($broadcast, [ThemeRefreshNative]::WM_THEMECHANGED, [IntPtr]::Zero, [IntPtr]::Zero, $flags, 2000, [ref]$result) | Out-Null
  [ThemeRefreshNative]::SendMessageTimeoutPtr($broadcast, [ThemeRefreshNative]::WM_DWMCOLORIZATIONCOLORCHANGED, [IntPtr]::Zero, [IntPtr]::Zero, $flags, 2000, [ref]$result) | Out-Null

  foreach ($className in @('Shell_TrayWnd', 'NotifyIconOverflowWindow', 'Progman'))
  {
    $hwnd = [ThemeRefreshNative]::FindWindow($className, $null)
    if ($hwnd -eq [IntPtr]::Zero)
    {
      continue
    }
    [ThemeRefreshNative]::SendMessageTimeoutStr($hwnd, [ThemeRefreshNative]::WM_SETTINGCHANGE, [IntPtr]::Zero, $SettingName, $flags, 2000, [ref]$result) | Out-Null
    [ThemeRefreshNative]::SendMessageTimeoutPtr($hwnd, [ThemeRefreshNative]::WM_THEMECHANGED, [IntPtr]::Zero, [IntPtr]::Zero, $flags, 2000, [ref]$result) | Out-Null
  }
}

function Restart-ThemeShellHosts
{
  # 这些进程由系统按需拉起。重启可清掉开始菜单/操作中心的旧色缓存，但不保证第三方托盘图标变色
  foreach ($name in @('ShellExperienceHost', 'StartMenuExperienceHost'))
  {
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

function Restart-ThemeExplorerShell
{
  # 任务栏和系统托盘由 Explorer/Shell 持有。广播经常不够，重启 Explorer 是同步托盘底色成功率最高的办法
  # 代价：任务栏会闪一下，已打开的资源管理器窗口可能被关掉。第三方 NotifyIcon 仍可能继续用启动时缓存的图标
  $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
  if ($sessionId -eq 0)
  {
    Write-ThemeLog 'Explorer restart skipped: session 0'
    return
  }

  $before = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  Write-ThemeLog ('Explorer restart begin pids={0}' -f ($before -join ','))

  if (Ensure-ThemeRefreshNative)
  {
    try
    {
      $tray = [ThemeRefreshNative]::FindWindow('Shell_TrayWnd', $null)
      if ($tray -ne [IntPtr]::Zero)
      {
        # 0x5B4 = 任务栏 Ctrl+Shift 右键里的“退出资源管理器”，比直接杀进程更干净
        [ThemeRefreshNative]::PostMessage($tray, [ThemeRefreshNative]::WM_EXPLORER_EXIT, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
      }
    }
    catch
    {
      Write-ThemeLog ('Explorer graceful exit failed: {0}' -f $_.Exception.Message)
    }
  }

  $waitUntil = (Get-Date).AddMilliseconds(4000)
  while ((Get-Date) -lt $waitUntil -and (Get-Process -Name explorer -ErrorAction SilentlyContinue))
  {
    Start-Sleep -Milliseconds 200
  }

  $still = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
  if ($still.Count -gt 0)
  {
    Write-ThemeLog ('Explorer force stop pids={0}' -f (($still | ForEach-Object { $_.Id }) -join ','))
    $still | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
  }

  $explorerPath = Join-Path $env:WINDIR 'explorer.exe'
  # 系统有时会自己把 Shell 拉起来，已存在就不要再开第二个 explorer
  if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue))
  {
    Start-Process -FilePath $explorerPath
    Write-ThemeLog 'Explorer process started'
  }
  else
  {
    Write-ThemeLog 'Explorer already running after stop'
  }

  $trayOk = $false
  if (Ensure-ThemeRefreshNative)
  {
    $trayUntil = (Get-Date).AddMilliseconds(8000)
    while ((Get-Date) -lt $trayUntil)
    {
      Start-Sleep -Milliseconds 250
      try
      {
        $hwnd = [ThemeRefreshNative]::FindWindow('Shell_TrayWnd', $null)
        if ($hwnd -ne [IntPtr]::Zero)
        {
          $trayOk = $true
          break
        }
      }
      catch
      {
      }
    }
  }
  else
  {
    Start-Sleep -Milliseconds 1500
    $trayOk = [bool](Get-Process -Name explorer -ErrorAction SilentlyContinue)
  }

  if (-not $trayOk)
  {
    Write-ThemeLog 'Explorer tray timeout, starting explorer again'
    Start-Process -FilePath $explorerPath
    Start-Sleep -Milliseconds 1500
  }

  $after = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  Write-ThemeLog ('Explorer restart end tray={0} pids={1}' -f $(if ($trayOk) { 'ok' } else { 'timeout' }), ($after -join ','))
}

function Invoke-ThemeShellRefresh
{
  param([switch]$RestartExplorer)

  # 最大强度刷新：uxtheme 策略 + 菜单主题、系统参数、主题广播，必要时再重建 Explorer/托盘
  $notes = @()
  $native = Ensure-ThemeRefreshNative
  if ($native)
  {
    try
    {
      [ThemeRefreshNative]::RefreshImmersiveColorPolicyState()
      $notes += 'uxtheme#104=ok'
    }
    catch
    {
      $notes += 'uxtheme#104=fail'
    }

    try
    {
      [ThemeRefreshNative]::FlushMenuThemes()
      $notes += 'uxtheme#136=ok'
    }
    catch
    {
      $notes += 'uxtheme#136=fail'
    }

    try
    {
      Send-ThemeBroadcast -SettingName 'ImmersiveColorSet'
      Start-Sleep -Milliseconds 100
      Send-ThemeBroadcast -SettingName 'ImmersiveColorSet'
      $notes += 'broadcast=ok'
    }
    catch
    {
      $notes += ('broadcast=fail:{0}' -f $_.Exception.Message)
    }

    try
    {
      [ThemeRefreshNative]::UpdatePerUserSystemParameters(1, $true) | Out-Null
      $notes += 'userparams=ok'
    }
    catch
    {
      $notes += 'userparams=fail'
    }
  }
  else
  {
    $notes += 'native=unavailable'
  }

  if ($RestartExplorer)
  {
    try
    {
      Restart-ThemeExplorerShell
      Restart-ThemeShellHosts
      Start-Sleep -Milliseconds 300
      Send-ThemeBroadcast -SettingName 'ImmersiveColorSet'
      $notes += 'explorer=restarted'
    }
    catch
    {
      $notes += ('explorer=fail:{0}' -f $_.Exception.Message)
    }
  }

  # 不重启 Explorer 时，已打开的文件夹窗口不会自动跟 AppsUseLightTheme。
  # 枚举 CabinetWClass/ExploreWClass，按当前应用深浅色写 DWM 标题栏并强制重绘。
  if ($native)
  {
    try
    {
      $appsLight = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
      $darkMode = ($appsLight -eq 0)
      $refreshed = [ThemeRefreshNative]::RefreshExplorerWindows($darkMode)
      $notes += ('explorer-windows={0} dark={1}' -f $refreshed, $(if ($darkMode) { 1 } else { 0 }))

      # 不关窗口：让已打开的文件夹视图按当前 Apps 色重读，比关窗重开轻。
      $shell = New-Object -ComObject Shell.Application
      $viewCount = 0
      foreach ($window in @($shell.Windows()))
      {
        try
        {
          $fullName = [string]$window.FullName
          if (-not $fullName -or ($fullName -notmatch '(?i)\\explorer\.exe$'))
          {
            continue
          }
          $window.Refresh()
          $viewCount++
        }
        catch
        {
        }
      }
      $notes += ('explorer-views={0}' -f $viewCount)
    }
    catch
    {
      $notes += ('explorer-windows=fail:{0}' -f $_.Exception.Message)
    }
  }

  Write-ThemeLog ('Theme refresh: {0}' -f ($notes -join ' '))
}

function Invoke-ImmersiveColorRefresh
{
  # 兼容旧调用：只做广播级刷新，不重启 Explorer
  Invoke-ThemeShellRefresh
}

function Set-WindowsColorMode
{
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('light', 'dark')]
    [string]$Mode,
    $Config
  )

  $lightValue = if ($Mode -eq 'light') { 1 } else { 0 }
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  $before = Get-ThemePersonalizeState
  Write-ThemeLog ('Mode switch start: target={0} apps={1} system={2} before apps={3} system={4} theme={5}' -f `
      $Mode, $Config.mode_settings.switch_apps, $Config.mode_settings.switch_system, `
      $before.AppsUseLightTheme, $before.SystemUsesLightTheme, $before.CurrentTheme)

  if ($Config.mode_settings.switch_apps)
  {
    Set-ItemProperty -LiteralPath $key -Name AppsUseLightTheme -Value $lightValue -Type DWord
  }
  if ($Config.mode_settings.switch_system)
  {
    Set-ItemProperty -LiteralPath $key -Name SystemUsesLightTheme -Value $lightValue -Type DWord
  }

  # 系统壳（任务栏/托盘）只有在 switch_system 时才会换色；此时重启 Explorer 成功率最高
  Invoke-ThemeShellRefresh -RestartExplorer:([bool]$Config.mode_settings.switch_system)

  $after = Get-ThemePersonalizeState
  Write-ThemeLog ('Mode switch done: apps={0} system={1} theme={2}' -f `
      $after.AppsUseLightTheme, $after.SystemUsesLightTheme, $after.CurrentTheme)
}

function Invoke-ThemeNotify
{
  param(
    [string]$Type = 'info',
    [string]$Icon = ([string][char]0x2600 + [string][char]0xFE0F),
    [string]$Text = ''
  )
  try
  {
    $notifyLib = Join-Path (Split-Path $PSScriptRoot -Parent) "raycast-scripts\_lib\notify.ps1"
    if (Test-Path -LiteralPath $notifyLib -PathType Leaf)
    {
      . $notifyLib
      $title = "$Icon 主题切换"
      Show-SystemToast -Title $title -Message $Text | Out-Null
    }
  }
  catch
  {
  }
}
