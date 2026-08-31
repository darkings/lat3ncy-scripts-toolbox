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
      light_wallpaper = ''
      dark_wallpaper = ''
    }
    theme_settings = @{
      light_theme_file = 'light.theme'
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

function Get-ThemeHiddenAction
{
  param([Parameter(Mandatory = $true)][string]$ScriptPath)

  $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
  return New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
}

function Get-ThemeTaskSettings
{
  return New-ScheduledTaskSettingsSet `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -WakeToRun `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)
}

function Repair-ThemeScheduledTaskWindow
{
  param(
    [Parameter(Mandatory = $true)][string]$TaskName,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    $Trigger = $null
  )

  $action = Get-ThemeHiddenAction -ScriptPath $ScriptPath
  $settings = Get-ThemeTaskSettings
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
    [string]$Icon = '☀️',
    [string]$Text = ''
  )
  try
  {
    $notifyLib = Join-Path (Split-Path $PSScriptRoot -Parent) 'raycast-scripts\_lib\notify.ps1'
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
