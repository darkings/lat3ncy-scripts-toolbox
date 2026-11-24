$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\ToolboxControls.ps1')

function Test-ThemeFeatureEnabled {
  return (Test-ToolboxModuleEnabled -Module theme -RepoRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
}

function Get-ThemeConfig
{
  # 进程内记忆化：每个脚本进程都会调用一次，实测解析约 75ms。
  # 目前每个进程只读到一次，所以收益很小；但 Apply-ThemeNow 这类会间接再读，
  # 而且缓存后调用方可以放心多次取配置。
  if ($script:ThemeConfigCache)
  {
    return $script:ThemeConfigCache
  }

  $configFile = Join-Path $PSScriptRoot 'config.toml'
  $config = @{
    general = @{
      switch_type = 'mode'
      show_notification = $false
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
    keyboard_backlight = @{
      enabled = $true
      light_level = 0
      dark_level = 1
      idle_timeout_seconds = 30
      wake_on_mouse_click = $true
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

  $script:ThemeConfigCache = $config
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

  # 登录/唤醒时网络可能还没好。sun 模式算不出来时，复用已经校准过的 Daily 触发时间。
  #
  # 为什么不直接用 Get-ScheduledTask：它走 MSFT_ScheduledTask 这个 CIM 类，是本工具里
  # 最贵的单点开销。2026-10-31 实测单次 814-928ms，而且和 -TaskName 过滤无关
  # （查一个根本不存在的任务也要 845ms，本质是全量枚举）；本函数在热路径上会被调两次，
  # 等于每次切换白付 1.6-1.8 秒 —— 日志里"任务 08:35:08 启动、08:35:12 才写出第一行"
  # 的那 4 秒，大头就是它。
  #
  # 改成直接读任务定义 XML（实测约 60ms，且不需要 Import-Module ScheduledTasks 的 232ms）：
  # 我们只关心 CalendarTrigger 的 StartBoundary，XML 里是明文。
  $boundary = $null
  try
  {
    $tasksDir = Join-Path $env:WINDIR 'System32'
    $tasksDir = Join-Path $tasksDir 'Tasks'
    # 任务计划程序在磁盘上的根任务文件名没有扩展名（如 ...\Tasks\Theme-Light）；
    # 早期/迁移过来的布局可能带 .xml，两种都试一次。
    $xmlPath = Join-Path $tasksDir $TaskName
    if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf))
    {
      $xmlPath = Join-Path $tasksDir ($TaskName + '.xml')
    }
    if (Test-Path -LiteralPath $xmlPath -PathType Leaf)
    {
      $xml = [xml](Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop)
      $nodes = @($xml.Task.Triggers.ChildNodes | Where-Object { $_.StartBoundary })
      if ($nodes.Count -gt 0)
      {
        $boundary = [string]$nodes[0].StartBoundary
      }
    }
  }
  catch
  {
  }

  if (-not $boundary)
  {
    # 兜底：任务文件读不到（权限/被加密/不在根目录）时退回旧的 CIM 查询。
    try
    {
      $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
      if ($task)
      {
        $daily = @($task.Triggers | Where-Object { $_.StartBoundary }) | Select-Object -First 1
        if ($daily)
        {
          $boundary = [string]$daily.StartBoundary
        }
      }
    }
    catch
    {
    }
  }

  if (-not $boundary)
  {
    return $null
  }

  try
  {
    # 统一投影到今天：StartBoundary 可能是"今天还没到"或"今天已过、下次在明天"，
    # 调用方要的是"今天这一次的触发时刻"。日出日落每天只差约 1 分钟，
    # 投影比走网络或退回 07:00/19:00 准得多。
    return (Get-Date).Date.Add([datetime]::Parse($boundary).TimeOfDay)
  }
  catch
  {
    return $null
  }
}

function Get-ThemeScheduleTimes
{
  param(
    $Config = $null,
    [switch]$ForceRefresh
  )

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

  $today = (Get-Date).Date

  # 1) 同一天就复用：若今天已经校准过 Theme-Light / Theme-Dark，直接复用已注册时间，绝不跑网络。
  # 彻底解决日志里 source=ip 占绝大多数、每次解锁/切换都在开局吃 1.5 秒 HTTP 的问题。
  if (-not $ForceRefresh)
  {
    $existingRise = Get-ExistingThemeTaskTime -TaskName 'Theme-Light'
    $existingSet = Get-ExistingThemeTaskTime -TaskName 'Theme-Dark'
    if ($existingRise -and $existingSet -and ($existingRise.Date -eq $today) -and ($existingSet.Date -eq $today))
    {
      return [pscustomobject]@{
        RiseTime = $existingRise
        SetTime = $existingSet
        TriggerMode = 'sun'
        Source = 'existing-task'
      }
    }
  }

  # 2) 任务时间不是今天（例如 00:10 首次更新当天、或无任务、或 ForceRefresh），走网络经纬度计算
  $coords = Get-ThemeCoordinates -Config $Config
  if ($coords)
  {
    $sun = Get-ThemeSunTimes -Lat $coords.Lat -Lon $coords.Lon -Date (Get-Date)
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

  # 3) 网络失败：退回到已有任务的时间（投影到今天），日出日落每天仅差约 1 分钟，远比写死 07:00/19:00 准
  if (-not $existingRise -or -not $existingSet)
  {
    $existingRise = Get-ExistingThemeTaskTime -TaskName 'Theme-Light'
    $existingSet = Get-ExistingThemeTaskTime -TaskName 'Theme-Dark'
  }
  if ($existingRise -and $existingSet)
  {
    return [pscustomobject]@{
      RiseTime = $today.Add($existingRise.TimeOfDay)
      SetTime = $today.Add($existingSet.TimeOfDay)
      TriggerMode = 'sun'
      Source = 'existing-task-projected'
    }
  }

  # 4) 最终兜底：使用 config 里的固定备用时间（投影到今天）
  $fLight = [datetime]::Parse($fallbackLight)
  $fDark = [datetime]::Parse($fallbackDark)
  return [pscustomobject]@{
    RiseTime = $today.Add($fLight.TimeOfDay)
    SetTime = $today.Add($fDark.TimeOfDay)
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
    return $false
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
  # .theme 是 INI：只有 UTF-16LE+BOM 与 UTF-8+BOM 能按 BOM 判定；
  # 其余（ANSI，Windows 按系统代码页写入的那些）必须按系统 ANSI 代码页解码，
  # 并且用同一编码回写。以前非 UTF-16 一律当 UTF-8 读、再以 UTF-8 无 BOM 写回，
  # 中文方案名/路径会被解成 U+FFFD 并永久损坏。
  $hasUtf8Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  if ($isUnicode)
  {
    $sourceEncoding = $unicode
    $preambleLength = 2
  }
  elseif ($hasUtf8Bom)
  {
    $sourceEncoding = New-Object Text.UTF8Encoding $true
    $preambleLength = 3
  }
  else
  {
    $sourceEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    $preambleLength = 0
  }
  $text = $sourceEncoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
  $originalText = $text
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

  # 内容没变就不要重写：整份 .theme 重写既慢，又会在解锁/唤醒瞬间和并发的
  # Theme-Apply-Cursors 抢同一把文件锁（日志里 6 次「正由另一进程使用」都出在这里）。
  $original = $originalText
  if ($text -ceq $original)
  {
    return $false
  }

  # 按原编码整体回写（BOM 有无保持不变），写完读回比对；不一致就用备份还原。
  $outBytes = $sourceEncoding.GetBytes($text)
  if ($preambleLength -gt 0)
  {
    $outBytes = [byte[]]($sourceEncoding.GetPreamble() + $outBytes)
  }
  [IO.File]::WriteAllBytes($themePath, $outBytes)

  $verifyBytes = [IO.File]::ReadAllBytes($themePath)
  $verifyText = ''
  if ($verifyBytes.Length -ge $preambleLength)
  {
    $verifyText = $sourceEncoding.GetString($verifyBytes, $preambleLength, $verifyBytes.Length - $preambleLength)
  }
  if ($verifyText -cne $text)
  {
    Write-ThemeLog (("Cursor theme file verify mismatch, restoring backup: {0}" -f $themePath))
    Copy-Item -LiteralPath $backupPath -Destination $themePath -Force
    return $false
  }
  Write-ThemeLog ("Cursor theme file synced: {0}" -f $themePath)
  return $true
}

function Test-ThemeFileCursorPaths
{
  param(
    [Parameter(Mandatory = $true)]$Roles,
    [Parameter(Mandatory = $true)]$Paths,
    [Parameter(Mandatory = $true)][string]$SchemeName
  )

  # 只读检查 .theme 的 [Control Panel\Cursors] 段是否已经等于目标值。
  # 读不了、或段里缺项都算「不确定」，返回 $false 让调用方走完整路径，绝不猜。
  $themesKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
  $themePath = (Get-ItemProperty -LiteralPath $themesKey -Name CurrentTheme -ErrorAction SilentlyContinue).CurrentTheme
  if (-not $themePath -or -not (Test-Path -LiteralPath $themePath -PathType Leaf))
  {
    return $false
  }

  try
  {
    $bytes = [IO.File]::ReadAllBytes($themePath)
    $isUnicode = ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
    $text = if ($isUnicode) { [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) } else { [Text.Encoding]::UTF8.GetString($bytes) }
  }
  catch
  {
    return $false
  }

  $inSection = $false
  $found = @{}
  foreach ($line in [regex]::Split($text, '\r\n|\n|\r'))
  {
    if ($line -match '^\[(.+)\]\s*$')
    {
      $inSection = ($matches[1] -eq 'Control Panel\Cursors')
      continue
    }
    if ($inSection -and $line -match '^([^=]+)=(.+)$')
    {
      $found[$matches[1].Trim()] = $matches[2].Trim()
    }
  }

  foreach ($role in $Roles)
  {
    if (-not $found.ContainsKey($role.Name))
    {
      return $false
    }
    $want = ([string]$Paths[$role.Name]).TrimEnd('\')
    $have = ([string]$found[$role.Name]).TrimEnd('\')
    if (-not [string]::Equals($want, $have, [StringComparison]::OrdinalIgnoreCase))
    {
      return $false
    }
  }

  if (-not $found.ContainsKey('SchemeName') -or $found['SchemeName'] -ne $SchemeName)
  {
    return $false
  }
  return $true
}

function Test-CursorSchemeApplied
{
  param(
    [Parameter(Mandatory = $true)]$Roles,
    [Parameter(Mandatory = $true)]$Paths,
    [Parameter(Mandatory = $true)][string]$SchemeName
  )

  # 注册表里 17 个角色已指向目标文件、且 .theme 也一致 -> 本次套用是白做的。
  # 颜色那条走「值相同就跳过」的幂等检查，指针这条同理：实测 47% 的套用发生在
  # 上一次套用后 3 秒内（解锁/切回控制台连发），这些全是可以省掉的。
  $key = 'HKCU:\Control Panel\Cursors'
  try
  {
    $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
  }
  catch
  {
    return $false
  }

  if ($null -eq $props.'Scheme Source' -or [int]$props.'Scheme Source' -ne 1)
  {
    return $false
  }

  foreach ($role in $Roles)
  {
    if (-not $props.PSObject.Properties.Name.Contains($role.Name))
    {
      return $false
    }
    $want = ([string]$Paths[$role.Name]).TrimEnd('\')
    $have = ([string]$props.($role.Name)).TrimEnd('\')
    if (-not [string]::Equals($want, $have, [StringComparison]::OrdinalIgnoreCase))
    {
      return $false
    }
  }

  return (Test-ThemeFileCursorPaths -Roles $Roles -Paths $Paths -SchemeName $SchemeName)
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

  if (-not ('SystemParametersInfoCursor' -as [type]))
  {
    $spiCode = "using System; using System.Runtime.InteropServices; public static class SystemParametersInfoCursor { [DllImport(`"user32.dll`", SetLastError=true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni); }"
    Add-Type -TypeDefinition $spiCode -ErrorAction Stop
  }

  try
  {
    # 幂等短路：注册表 17 个角色 + Schemes 方案 + .theme 段都已等于目标值时，绝不再重复写注册表与磁盘。
    # 只需重发一次 SPI_SETCURSORS，盖掉系统在锁屏后按 .theme 重载的那一拍默认指针。
    if (Test-CursorSchemeApplied -Roles $roles -Paths $paths -SchemeName $schemeName)
    {
      [SystemParametersInfoCursor]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0x0003) | Out-Null
      Write-ThemeLog ("Cursor switch skipped (already applied): mode={0} scheme={1} live=rebroadcast dir={2}" -f $Mode, $schemeName, $dir)
      return $true
    }

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
      Sync-ThemeFileCursors -Roles $roles -Paths $paths -SchemeName $schemeName | Out-Null
    }
    catch
    {
      Write-ThemeLog ("Cursor theme file sync failed: {0}" -f $_.Exception.Message)
    }

    $setCount = $roles.Count
    # SPI_SETCURSORS = 0x0057. 让系统按注册表和当前 DPI 自己选尺寸。
    [SystemParametersInfoCursor]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0x0003) | Out-Null
    $live = 'reloaded'

    Write-ThemeLog ("Cursor switch done: mode={0} scheme={1} set={2}/{3} live={4} overlay={5} dir={6}" -f `
        $Mode, $schemeName, $setCount, $roles.Count, $live, $overlayCleared, $dir)
    return $true
  }
  catch
  {
    Write-ThemeLog ("Cursor switch failed: {0}" -f $_.Exception.Message)
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

  # 幂等短路：当前桌面壁纸已经是这张图就别再设一次。
  # SPI_SETDESKWALLPAPER 带 SPIF_SENDCHANGE，会让整个桌面重绘并广播一次设置变更。
  if (Test-SameWallpaperPath -Left $ImagePath -Right (Get-DesktopWallpaperPath))
  {
    Write-ThemeLog ("Desktop wallpaper unchanged, skipped: {0}" -f $ImagePath)
    return $true
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

function Get-WallpaperPool
{
  param($Config, [ValidateSet('light', 'dark', '')][string]$Mode = '')

  $directory = [string]$Config.wallpaper.directory
  if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container))
  {
    return @()
  }

  # 进程内缓存：同一次切换里 Resolve-WallpaperImage 会被调用 1~2 次，
  # 每次都重新枚举目录 + 逐项规范化路径（实测 31~103ms）。目录内容在一次运行内不会变。
  $cacheKey = '{0}|{1}' -f $directory, $Mode
  if ($script:WallpaperPoolCache -and $script:WallpaperPoolCache.ContainsKey($cacheKey))
  {
    return $script:WallpaperPoolCache[$cacheKey]
  }

  $images = @()
  if ($Mode)
  {
    $subNames = if ($Mode -eq 'light') { @('light', 'day', 'sunrise') } else { @('dark', 'night', 'sunset') }
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
  }

  if ($images.Count -eq 0)
  {
    $images = @(Get-WallpaperImageFile -Directory $directory)
  }

  $sorted = @($images | Sort-Object FullName)
  if (-not $script:WallpaperPoolCache)
  {
    $script:WallpaperPoolCache = @{}
  }
  $script:WallpaperPoolCache[$cacheKey] = $sorted
  return $sorted
}

function ConvertTo-CanonicalPath
{
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path))
  {
    return ''
  }

  $trimmed = $Path.Trim().Trim('"')
  try
  {
    $full = [System.IO.Path]::GetFullPath($trimmed)
  }
  catch
  {
    return $trimmed
  }

  if (Test-Path -LiteralPath $full)
  {
    try
    {
      $resolved = (Resolve-Path -LiteralPath $full).Path
      if (-not [string]::IsNullOrWhiteSpace($resolved))
      {
        $full = $resolved
      }
    }
    catch
    {
    }
  }

  return [System.IO.Path]::GetFullPath($full)
}

function Test-SameWallpaperPath
{
  param(
    [string]$Left,
    [string]$Right
  )

  $leftPath = ConvertTo-CanonicalPath $Left
  $rightPath = ConvertTo-CanonicalPath $Right
  if ([string]::IsNullOrWhiteSpace($leftPath) -or [string]::IsNullOrWhiteSpace($rightPath))
  {
    return $false
  }

  return [string]::Equals($leftPath, $rightPath, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DesktopWallpaperPath
{
  try
  {
    return [string](Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction Stop).Wallpaper
  }
  catch
  {
    return ''
  }
}

function Get-NextWallpaperImage
{
  param(
    $Config,
    [string]$CurrentPath = '',
    [ValidateSet('light', 'dark', '')]
    [string]$Mode = ''
  )

  $pool = @(Get-WallpaperPool -Config $Config -Mode $Mode)
  if ($pool.Count -eq 0)
  {
    return $null
  }
  if ($pool.Count -eq 1)
  {
    return $pool[0].FullName
  }

  $index = -1
  if ($CurrentPath)
  {
    for ($i = 0; $i -lt $pool.Count; $i++)
    {
      if (Test-SameWallpaperPath $pool[$i].FullName $CurrentPath)
      {
        $index = $i
        break
      }
    }
  }

  $next = if ($index -ge 0) { ($index + 1) % $pool.Count } else { 0 }
  return $pool[$next].FullName
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

  # 3) Same ordered pool as the manual next-wallpaper command.
  return Get-NextWallpaperImage -Config $Config -CurrentPath (Get-DesktopWallpaperPath) -Mode $Mode
}

function Read-LockScreenResult
{
  # 读 Set-LockScreenFromWallpaper.ps1 的 -ResultFile（UTF-8 单行 key=value）。
  # 不解析子进程 stdout/stderr：控制台重定向里的中文按 OEM 代码页编码，
  # 本文件既可能跑在 5.1（计划任务）也可能被 pwsh 7 dot-source（Raycast），读法不统一。
  param([string]$Path)

  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf))
  {
    return $null
  }

  $result = @{}
  foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
  {
    $index = $line.IndexOf('=')
    if ($index -gt 0)
    {
      $result[$line.Substring(0, $index)] = $line.Substring($index + 1)
    }
  }
  if ($result.Count -eq 0) { return $null }
  return [pscustomobject]$result
}

function Sync-LockScreenWallpaper
{
  param($Config, [string]$ImagePath)

  $script:ThemeLockScreenError = $null

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

  $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("lat3ncy-lockscreen-{0}.result" -f [guid]::NewGuid().ToString('n'))

  $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-ResultFile', $resultPath)
  $source = 'desktop-wallpaper'
  if ($ImagePath -and (Test-Path -LiteralPath $ImagePath -PathType Leaf))
  {
    $arguments += @('-ImagePath', $ImagePath)
    $source = $ImagePath
  }

  # 不用 Start-Process：带 -RedirectStandard* 时 pwsh 7 拿不到 ExitCode（返回 null），
  # 这里要同时拿到退出码和子进程输出。输出按 OEM 代码页解码，中文才不会变乱码。
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $winPs
  $startInfo.Arguments = ($arguments | ForEach-Object {
      $text = [string]$_
      if ($text -match '[\s"]')
      {
        '"{0}"' -f ($text -replace '(\\+)"', '$1$1\"' -replace '(\\+)$', '$1$1' -replace '"', '\"')
      }
      else
      {
        $text
      }
    }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $consoleEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
  $startInfo.StandardOutputEncoding = $consoleEncoding
  $startInfo.StandardErrorEncoding = $consoleEncoding

  # 子进程里 WinRT 落地大图实测要 13-19s（6000x3000 JPEG、16-bit PNG 转码），
  # 上限给它留足余量；超时就杀掉并如实记日志，不能让整个切换流程被锁屏同步无限拖着。
  $timeoutMs = 60000
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  try
  {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutMs))
    {
      try { $process.Kill() } catch { }
      $script:ThemeLockScreenError = ('子进程 {0}s 未返回，已结束' -f ($timeoutMs / 1000))
      Write-ThemeLog ("LockScreen sync timeout after {0}s, child killed" -f ($timeoutMs / 1000))
      return $false
    }
    # 再等一次让异步读流收尾，之后 .Result 才是完整的
    $process.WaitForExit()

    $result = Read-LockScreenResult -Path $resultPath
    if ($process.ExitCode -ne 0)
    {
      $detail = if ($result -and $result.error) { [string]$result.error } else { '' }
      if (-not $detail)
      {
        # 子进程在写结果文件之前就挂了（参数错误、找不到壁纸等），退回第一条 stderr
        $stderrText = ''
        try { $stderrText = [string]$stderrTask.Result } catch { }
        $firstLine = @($stderrText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($firstLine.Count -gt 0)
        {
          $detail = ($firstLine[0] -replace '^[A-Za-z]:\\[^:]+\.ps1\s*:\s*', '').Trim()
        }
      }
      if (-not $detail) { $detail = ('exit code {0}' -f $process.ExitCode) }
      $script:ThemeLockScreenError = $detail
      throw $detail
    }

    $method = if ($result -and $result.method) { ' (' + [string]$result.method + ')' } else { '' }
    Write-ThemeLog ("LockScreen synced from {0}{1}" -f $source, $method)
    return $true
  }
  catch
  {
    if (-not $script:ThemeLockScreenError)
    {
      $script:ThemeLockScreenError = $_.Exception.Message
    }
    Write-ThemeLog ("LockScreen sync failed: {0}" -f $_.Exception.Message)
    return $false
  }
  finally
  {
    try { $process.Dispose() } catch { }
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-ThemeShimDirectory
{
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = $env:TEMP }
  return (Join-Path $base 'lat3ncy-toolbox\theme-tasks')
}

function Get-ThemeHiddenAction
{
  param([Parameter(Mandatory = $true)][string]$ScriptPath)

  # 为什么不让任务计划程序直接跑 powershell.exe：
  # powershell.exe 是控制台程序，任务以交互方式在用户会话里启动时会分配真实控制台，
  # 于是睡眠唤醒/解锁时屏幕上会蹦出一个终端窗口；任务的 -Hidden 只管任务自身，
  # 管不到子进程的窗口。conhost.exe --headless 外壳同样不抑制窗口（而且不是它的用途）。
  # wscript.exe 是 GUI 程序，不分配控制台；它再用 WshShell.Run(..., 0, True) 静默等待
  # PowerShell 跑完，任务状态仍然准确。
  $shimDir = Get-ThemeShimDirectory
  if (-not (Test-Path -LiteralPath $shimDir)) {
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
  }
  $shimName = ([System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)) + '.vbs'
  $shimPath = Join-Path $shimDir $shimName

  $command = 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
  # VBS 字符串里双引号要写成两个双引号
  $escaped = $command.Replace('"', '""')
  $vbs = @(
    "' Lat3ncy Toolbox - generated by Get-ThemeHiddenAction. Do not edit; re-run Install-ThemeScheduler.ps1."
    'Option Explicit'
    'Dim sh, exitCode'
    'Set sh = CreateObject("WScript.Shell")'
    ('exitCode = sh.Run("{0}", 0, True)' -f $escaped)
    'WScript.Quit exitCode'
  ) -join "`r`n"
  [System.IO.File]::WriteAllText($shimPath, $vbs + "`r`n", [System.Text.Encoding]::ASCII)

  return New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $shimPath)
}

function Get-ThemeTaskSettings
{
  param([switch]$DisableStartWhenAvailable)

  # StartWhenAvailable 默认打开：关机/休眠错过的日出日落允许在开机或恢复后补跑。
  # 2026-10-31 实测：S4 恢复后的补跑时机由任务计划程序内部扫描决定，实测晚 6 分 00 秒到
  # 24 分钟不等（只有恰好撞上 S0ix 退出才可能是秒级），所以它只能当最终一致性兜底。
  # 唤醒后的即时对齐交给 Theme-Apply-Cursors 的解锁/控制台连接触发器（实测唤醒后 0.5 秒内拉起）。
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

function Start-ThemeTail
{
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('light', 'dark')]
    [string]$Mode,
    [switch]$PlanOnly
  )

  # 壁纸 / 光标 / 键盘灯 / 锁屏 都发生在"界面已经变色之后"，用户看不到它们，
  # 但实测会把任务尾巴拖长 5-17 秒（锁屏 p90 10s、壁纸 SPI 1.5-2s、光标四个 pass 共 8s、
  # 锁屏子进程 WaitForExit 最长 60s）。抽成独立进程后主脚本能立刻返回，
  # 任务状态也真实反映"颜色切完了"而不是"壁纸也换完了"。
  $tailScript = Join-Path $PSScriptRoot 'Set-Theme-Tail.ps1'
  if (-not (Test-Path -LiteralPath $tailScript -PathType Leaf))
  {
    Write-ThemeLog ("Tail missing: {0}" -f $tailScript)
    return $false
  }

  $psExe = Join-Path $env:WINDIR 'System32'
  $psExe = Join-Path $psExe 'WindowsPowerShell'
  $psExe = Join-Path $psExe 'v1.0'
  $psExe = Join-Path $psExe 'powershell.exe'

  $argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1}' -f $tailScript, $Mode
  if ($PlanOnly)
  {
    $argLine = $argLine + ' -PlanOnly'
  }

  # 必须静默：powershell.exe 是控制台程序，Start-Process -WindowStyle Hidden 只设置
  # STARTUPINFO 的 wShowWindow，仍然会分配 conhost，唤醒时可能在屏幕上闪一个终端窗口。
  # 这里和 Sync-LockScreenWallpaper 用同一套做法：UseShellExecute=false + CreateNoWindow=true，
  # 根本不给子进程创建控制台，再叠一次 -WindowStyle Hidden 兜底。
  try
  {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $psExe
    $startInfo.Arguments = $argLine
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($process)
    {
      $process.Dispose()
    }
    Write-ThemeLog ("Tail dispatched: mode={0} (wallpaper/cursor/backlight/lockscreen in background)" -f $Mode)
    return $true
  }
  catch
  {
    Write-ThemeLog ("Tail dispatch failed: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Write-ThemeLog
{
  param([string]$Message)

  # 计划任务无控制台，切换结果只写本地日志，便于核对注册表和 Explorer 重启。
  # 日志里会带子进程回传的中文原因，固定写 UTF-8：5.1 的 Add-Content 默认按 ANSI 写，
  # 和 pwsh 7（默认 UTF-8）混在一起会变成乱码。
  $logFile = Join-Path $PSScriptRoot 'theme-scheduler.log'
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
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

  // SendNotifyMessage：同进程窗口同步直达，其他进程只投递、不入队等待。
  // 系统自己广播 WM_SETTINGCHANGE 用的就是它 —— 正好避开 SendMessageTimeout
  // 「最坏等待 = 超时 x 顶层窗口数」的长尾（本机 26 个窗口，日志里出过 111 秒和 560 秒）。
  [DllImport("user32.dll", EntryPoint = "SendNotifyMessage", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern bool SendNotifyMessageStr(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);

  [DllImport("user32.dll", EntryPoint = "SendNotifyMessage", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern bool SendNotifyMessagePtr(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

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
    // 只给一条 WM_SETTINGCHANGE 做 400ms 有限同步确认（够它重读标题栏色），其余两条投递不等待。
    // 原来是 3 条 x 1500ms 全同步：一个忙住的资源管理器窗口就能吃掉 4.5 秒。
    SendMessageTimeoutStr(hWnd, WM_SETTINGCHANGE, IntPtr.Zero, "ImmersiveColorSet", SMTO_ABORTIFHUNG, 400, out result);
    SendNotifyMessagePtr(hWnd, WM_THEMECHANGED, IntPtr.Zero, IntPtr.Zero);
    SendNotifyMessagePtr(hWnd, WM_DWMCOLORIZATIONCOLORCHANGED, IntPtr.Zero, IntPtr.Zero);

    SetExplorerFrameColors(hWnd, _explorerDark != 0);
    // 去掉 RDW_UPDATENOW：让它走消息循环异步重绘，别在切换脚本里同步等整棵子窗口树画完。
    RedrawWindow(hWnd, IntPtr.Zero, IntPtr.Zero,
      RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_FRAME);
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

  # 全局广播改用 SendNotifyMessage（投递不等待）。原来的 SendMessageTimeout 是同步的：
  # 任一顶层窗口「忙但未挂起」就吃满整个超时，而总等待 = 超时 x 顶层窗口数 ——
  # 本机 26 个可见顶层窗口 x 9 条消息，理论最坏约 97 秒，日志里实测过 111 秒和 560 秒。
  # ImmersiveColorSet / WM_THEMECHANGED / DWM 颜色变化本身就是"通知"，不需要回执。
  [ThemeRefreshNative]::SendNotifyMessageStr($broadcast, [ThemeRefreshNative]::WM_SETTINGCHANGE, [IntPtr]::Zero, $SettingName) | Out-Null
  [ThemeRefreshNative]::SendNotifyMessagePtr($broadcast, [ThemeRefreshNative]::WM_THEMECHANGED, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
  [ThemeRefreshNative]::SendNotifyMessagePtr($broadcast, [ThemeRefreshNative]::WM_DWMCOLORIZATIONCOLORCHANGED, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null

  # 任务栏 / 托盘溢出区 / 桌面这三个宿主决定托盘底色，点名给一次有限同步确认。
  # 400ms 足够：正常 Explorer 是毫秒级响应，真挂起的窗口本来也不该等。
  foreach ($className in @('Shell_TrayWnd', 'NotifyIconOverflowWindow', 'Progman'))
  {
    $hwnd = [ThemeRefreshNative]::FindWindow($className, $null)
    if ($hwnd -eq [IntPtr]::Zero)
    {
      continue
    }
    [ThemeRefreshNative]::SendMessageTimeoutStr($hwnd, [ThemeRefreshNative]::WM_SETTINGCHANGE, [IntPtr]::Zero, $SettingName, $flags, 400, [ref]$result) | Out-Null
    [ThemeRefreshNative]::SendNotifyMessagePtr($hwnd, [ThemeRefreshNative]::WM_THEMECHANGED, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    [ThemeRefreshNative]::SendNotifyMessagePtr($hwnd, [ThemeRefreshNative]::WM_DWMCOLORIZATIONCOLORCHANGED, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
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
      # 只广播一次。原来连发两次（中间 sleep 100ms）是想等第一次广播里忙的窗口腾出手，
      # 但 Send-ThemeBroadcast 内部本来就对 Shell_TrayWnd / NotifyIconOverflowWindow / Progman
      # 逐窗口点名重发，第二次全量广播只是在为「某个窗口忙」付第二遍最坏 4.5 秒的账。
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

  # 幂等短路：App/System 值本来就等于目标（常见于解锁后重复触发、或登录时已经对齐），
  # 连注册表都不用写，更不用跑整套 uxtheme 策略刷新 + 两次全窗口广播 + Shell COM 刷新。
  # 实测这套刷新中位 3 秒、p90 12 秒，里面绝大多数是白做的。
  $appsAlready = (-not $Config.mode_settings.switch_apps) -or ([int]$before.AppsUseLightTheme -eq $lightValue)
  $sysAlready = (-not $Config.mode_settings.switch_system) -or ([int]$before.SystemUsesLightTheme -eq $lightValue)
  if ($appsAlready -and $sysAlready)
  {
    Write-ThemeLog ('Mode switch skipped (already {0}): apps={1} system={2} theme={3}' -f `
        $Mode, $before.AppsUseLightTheme, $before.SystemUsesLightTheme, $before.CurrentTheme)
    return $false
  }

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
  return $true
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

function Test-IsThinkPadDevice
{
  if ($null -ne $script:IsThinkPadDeviceCache)
  {
    return $script:IsThinkPadDeviceCache
  }

  $isThinkPad = $false
  try
  {
    $biosKey = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
    if (Test-Path -LiteralPath $biosKey)
    {
      $bios = Get-ItemProperty -LiteralPath $biosKey -ErrorAction SilentlyContinue
      if ($bios)
      {
        $vendor = "{0} {1} {2}" -f $bios.SystemManufacturer, $bios.BaseBoardManufacturer, $bios.BIOSVendor
        $product = "{0} {1} {2} {3}" -f $bios.SystemFamily, $bios.SystemProductName, $bios.SystemVersion, $bios.SystemSKU
        if ($vendor -match '(?i)lenovo' -and $product -match '(?i)thinkpad')
        {
          $isThinkPad = $true
        }
      }
    }
  }
  catch
  {
  }

  $script:IsThinkPadDeviceCache = $isThinkPad
  return $isThinkPad
}

function Ensure-ThinkPadBacklightNative
{
  if (([System.Management.Automation.PSTypeName]'ThinkPadBacklightNative').Type)
  {
    return $true
  }

  $code = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class ThinkPadBacklightNative {
  private const uint GENERIC_READ = 0x80000000;
  private const uint GENERIC_WRITE = 0x40000000;
  private const uint FILE_SHARE_READ = 0x00000001;
  private const uint FILE_SHARE_WRITE = 0x00000002;
  private const uint OPEN_EXISTING = 3;
  private const uint IOCTL_READ = 0x00222680;
  private const uint IOCTL_WRITE = 0x00222684;
  private const int IBMPMDRV_HAS_BACKLIGHT_BIT = 0x00200000;
  private const int IBMPMDRV_WRITE_FLAG = 0x00000100;

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  private static extern SafeFileHandle CreateFile(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition,
    uint dwFlagsAndAttributes, IntPtr hTemplateFile);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool DeviceIoControl(
    SafeFileHandle hDevice, uint dwIoControlCode,
    byte[] lpInBuffer, int nInBufferSize,
    byte[] lpOutBuffer, int nOutBufferSize,
    out int lpBytesReturned, IntPtr lpOverlapped);

  public static int GetBacklightLevel() {
    try {
      using (var h = CreateFile(@"\\.\IBMPmDrv", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
        if (h.IsInvalid) return -1;
        byte[] inBuf = new byte[4];
        byte[] outBuf = new byte[4];
        int ret;
        if (!DeviceIoControl(h, IOCTL_READ, inBuf, 4, outBuf, 4, out ret, IntPtr.Zero) || ret < 4) {
          return -2;
        }
        int code = BitConverter.ToInt32(outBuf, 0);
        if ((code & IBMPMDRV_HAS_BACKLIGHT_BIT) == 0) return -3;
        return code & 0x0F;
      }
    } catch {
      return -4;
    }
  }

  public static bool SetBacklightLevel(int targetLevel, out int prevLevel, out string error) {
    prevLevel = -1;
    error = null;
    if (targetLevel < 0 || targetLevel > 2) {
      error = "Invalid target level " + targetLevel;
      return false;
    }
    try {
      using (var h = CreateFile(@"\\.\IBMPmDrv", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
        if (h.IsInvalid) {
          error = "Failed to open \\\\.\\IBMPmDrv (win32=" + Marshal.GetLastWin32Error() + ")";
          return false;
        }
        byte[] inBuf = new byte[4];
        byte[] outBuf = new byte[4];
        int ret;
        if (!DeviceIoControl(h, IOCTL_READ, inBuf, 4, outBuf, 4, out ret, IntPtr.Zero) || ret < 4) {
          error = "DeviceIoControl read failed (win32=" + Marshal.GetLastWin32Error() + ")";
          return false;
        }
        int code = BitConverter.ToInt32(outBuf, 0);
        if ((code & IBMPMDRV_HAS_BACKLIGHT_BIT) == 0) {
          error = "Device does not report keyboard backlight support";
          return false;
        }
        prevLevel = code & 0x0F;
        if (prevLevel == targetLevel) {
          return true;
        }

        int arg = IBMPMDRV_WRITE_FLAG | (code & 0xF0) | (targetLevel & 0x0F);
        byte[] writeIn = BitConverter.GetBytes(arg);
        byte[] writeOut = new byte[4];
        if (!DeviceIoControl(h, IOCTL_WRITE, writeIn, 4, writeOut, 4, out ret, IntPtr.Zero)) {
          error = "DeviceIoControl write failed (win32=" + Marshal.GetLastWin32Error() + ")";
          return false;
        }
        return true;
      }
    } catch (Exception ex) {
      error = ex.Message;
      return false;
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
    return $false
  }
}

function Test-ThinkPadCapability
{
  if ($null -ne $script:ThinkPadCapabilityCache)
  {
    return $script:ThinkPadCapabilityCache
  }

  if (-not (Test-IsThinkPadDevice))
  {
    $script:ThinkPadCapabilityCache = $false
    return $false
  }

  if (-not (Ensure-ThinkPadBacklightNative))
  {
    $script:ThinkPadCapabilityCache = $false
    return $false
  }

  $level = [ThinkPadBacklightNative]::GetBacklightLevel()
  $capable = ($level -ge 0)
  $script:ThinkPadCapabilityCache = $capable
  return $capable
}

function Get-ThinkPadKeyboardBacklight
{
  if (-not (Test-ThinkPadCapability))
  {
    return -1
  }
  return [ThinkPadBacklightNative]::GetBacklightLevel()
}

function Set-ThinkPadKeyboardBacklight
{
  param(
    [ValidateRange(0, 2)]
    [int]$Level = -1,
    [ValidateSet('light', 'dark', '')]
    [string]$Mode = '',
    $Config = $null
  )

  if (-not $Config)
  {
    $Config = Get-ThemeConfig
  }

  if ($Config.keyboard_backlight -and -not $Config.keyboard_backlight.enabled)
  {
    Write-ThemeLog 'Keyboard backlight switch skipped: disabled in config'
    return $false
  }

  if (-not (Test-ThinkPadCapability))
  {
    Write-ThemeLog 'Keyboard backlight switch skipped: not a supported ThinkPad device or driver unavailable'
    return $false
  }

  if ($Level -lt 0)
  {
    if ($Mode -eq 'light')
    {
      $Level = if ($Config.keyboard_backlight -and $null -ne $Config.keyboard_backlight.light_level) { [int]$Config.keyboard_backlight.light_level } else { 0 }
    }
    elseif ($Mode -eq 'dark')
    {
      $Level = if ($Config.keyboard_backlight -and $null -ne $Config.keyboard_backlight.dark_level) { [int]$Config.keyboard_backlight.dark_level } else { 1 }
    }
    else
    {
      Write-ThemeLog 'Keyboard backlight switch skipped: neither Level nor Mode specified'
      return $false
    }
  }

  $prevLevel = -1
  $err = $null
  $ok = [ThinkPadBacklightNative]::SetBacklightLevel($Level, [ref]$prevLevel, [ref]$err)
  if ($ok)
  {
    if ($prevLevel -eq $Level)
    {
      Write-ThemeLog ("Keyboard backlight unchanged (already level {0}), skipped" -f $Level)
    }
    else
    {
      Write-ThemeLog ("Keyboard backlight switched: {0} -> {1}" -f $prevLevel, $Level)
    }
    return $true
  }
  else
  {
    Write-ThemeLog ("Keyboard backlight switch failed: {0}" -f $err)
    return $false
  }
}

