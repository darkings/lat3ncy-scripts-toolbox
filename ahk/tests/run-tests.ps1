$ErrorActionPreference = 'Stop'

# Task 1 test entry point. Each invocation owns a unique result file and waits for
# the real AHK v2 engine so concurrent runs and parse failures cannot reuse PASS.
$resultFile = Join-Path ([System.IO.Path]::GetTempPath()) (
  'lat3ncy-toolbox-test-{0}.txt' -f [guid]::NewGuid().ToString('N')
)
$vsCodeTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'lat3ncy-copy-path-folder-{0}' -f [guid]::NewGuid().ToString('N')
)
$testScript = Join-Path $PSScriptRoot 'run-tests.ahk'

function Resolve-AutoHotkeyV2Executable
{
  # 优先标准 v2 安装位置（官方安装程序默认安装到 LOCALAPPDATA）
  if ($env:LOCALAPPDATA)
  {
    $standardV2 = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2'
    foreach ($engineName in @('AutoHotkey64.exe', 'AutoHotkey32.exe'))
    {
      $candidate = Join-Path $standardV2 $engineName
      if (Test-Path -LiteralPath $candidate -PathType Leaf)
      {
        return $candidate
      }
    }
  }

  $command = Get-Command AutoHotkey.exe -ErrorAction Stop
  $executable = $command.Source
  $shimFile = [System.IO.Path]::ChangeExtension($executable, '.shim')

  if (Test-Path -LiteralPath $shimFile)
  {
    $shimText = Get-Content -Raw -LiteralPath $shimFile
    if ($shimText -match '(?m)^path\s*=\s*"([^"]+)"')
    {
      $shimTarget = $Matches[1]
      if ([System.IO.Path]::GetFileName($shimTarget) -ieq 'AutoHotkeyUX.exe')
      {
        $installRoot = Split-Path (Split-Path $shimTarget -Parent) -Parent
        $engineName = if ([Environment]::Is64BitOperatingSystem)
        {
          'AutoHotkey64.exe'
        } else
        {
          'AutoHotkey32.exe'
        }
        $engine = Join-Path (Join-Path $installRoot 'v2') $engineName
        if (Test-Path -LiteralPath $engine)
        {
          return $engine
        }
        throw "Unable to locate the AutoHotkey v2 engine behind shim target: $shimTarget"
      }
      if (Test-Path -LiteralPath $shimTarget)
      {
        return $shimTarget
      }
    }
  }

  return $executable
}

function Test-FeatureLoadsIndependently
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $AutoHotkey,
    [Parameter(Mandatory = $true)]
    [string] $NotifyRoot,
    [Parameter(Mandatory = $true)]
    [string] $FeaturePath
  )

  $stubPath = Join-Path ([System.IO.Path]::GetTempPath()) (
    'lat3ncy-toolbox-feature-{0}.ahk' -f [guid]::NewGuid().ToString('N')
  )
  # 生产入口统一加载 python helper。独立加载也始终注入：
  # 朗读/翻译依赖 ToolboxPython，漏注入会弹 AHK 错误框并把 runner 卡死。
  # AHK 对同一 helper 只会加载一次，重复注入本身无害。
  # caret 锚点由 renderer.ahk / ime-hud.ahk include-once 加载，stub 不要再引一次。
  $pythonHelper = Join-Path (Split-Path $NotifyRoot -Parent) 'python.ahk'
  $stub = @"
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
OnError (*) => ExitApp(1)
#Include "$(Join-Path $NotifyRoot 'renderer.ahk')"
#Include "$(Join-Path $NotifyRoot 'notify.ahk')"
#Include "$pythonHelper"
#Include "$FeaturePath"
ExitApp 0
"@

  try
  {
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($stubPath, $stub, $utf8WithoutBom)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $AutoHotkey
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = '/ErrorStdOut=UTF-8 "{0}"' -f $stubPath

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(20000))
    {
      try { $process.Kill() } catch {}
      throw "Feature independent AHK v2 load timed out: $FeaturePath"
    }
    $standardOutput = $stdoutTask.Result
    $standardError = $stderrTask.Result

    if ($standardOutput)
    {
      [Console]::Out.Write($standardOutput)
    }
    if ($standardError)
    {
      [Console]::Error.Write($standardError)
    }

    $engineOutput = $standardOutput + "`n" + $standardError
    $hasParseError = $engineOutput -match '(?im)==>|\bError:|cannot be opened|does not contain a recognized action'
    if ($process.ExitCode -ne 0 -or $hasParseError)
    {
      throw "Feature failed independent AHK v2 load: $FeaturePath"
    }

    [Console]::Out.WriteLine('PASS: independent feature load {0}' -f [System.IO.Path]::GetFileName($FeaturePath))
  } finally
  {
    Remove-Item -LiteralPath $stubPath -ErrorAction SilentlyContinue
  }
}

$runnerExitCode = 1
try
{
  $autoHotkey = Resolve-AutoHotkeyV2Executable
  $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  $featureRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'features'
  $notifyRoot = Join-Path (Join-Path $repoRoot 'shared') 'notify'
  $independentFeatures = @(
    (Join-Path $featureRoot 'caps-lock-ime.ahk'),
    (Join-Path $featureRoot 'always-on-top.ahk'),
    (Join-Path $featureRoot 'hide-active-window.ahk'),
    (Join-Path $featureRoot 'toggle-hidden-files.ahk'),
    (Join-Path $featureRoot 'toggle-dotfiles.ahk'),
    (Join-Path $featureRoot 'toggle-file-extensions.ahk'),
    (Join-Path $featureRoot 'foreground-process.ahk'),
    (Join-Path $featureRoot 'search-selected-text.ahk'),
    (Join-Path (Join-Path $featureRoot 'smart-paste') 'smart-paste.ahk'),
    (Join-Path $featureRoot 'open-selected-target.ahk'),
    (Join-Path $featureRoot 'locate-selected-target.ahk'),
    (Join-Path $featureRoot 'speak-selected-text.ahk'),
    (Join-Path $featureRoot 'translate-selected-text.ahk'),
    (Join-Path $featureRoot 'audio-switcher.ahk'),
    (Join-Path $featureRoot 'switch-app-window.ahk'),
    (Join-Path $notifyRoot 'run-nowindow.ahk'),
    (Join-Path $notifyRoot 'ime-hud.ahk'),
    (Join-Path $notifyRoot 'translation-panel.ahk'),
    (Join-Path (Split-Path $notifyRoot -Parent) 'python.ahk')
  )
  foreach ($featurePath in $independentFeatures)
  {
    Test-FeatureLoadsIndependently -AutoHotkey $autoHotkey -NotifyRoot $notifyRoot -FeaturePath $featurePath
  }

  $raycastRoot = Join-Path (Join-Path $repoRoot 'tools') 'raycast-scripts'
  $rgbRoot = Join-Path (Join-Path $repoRoot 'tools') 'rgb'
  $themeRoot = Join-Path (Join-Path $repoRoot 'tools') 'theme-scheduler'
  # 只做 AST 解析，绝不执行 install.ps1 / Install-*：那些脚本会改服务、计划任务和硬件。
  $powerShellScripts = @(
    (Join-Path (Join-Path $featureRoot 'smart-paste') 'save-clipboard-image.ps1'),
    (Join-Path (Join-Path $raycastRoot '_lib') 'notify.ps1'),
    (Join-Path $raycastRoot 'screenshot.ps1'),
    (Join-Path $raycastRoot 'screenshot-ocr.ps1'),
    (Join-Path $raycastRoot 'record-screen.ps1'),
    (Join-Path (Join-Path $raycastRoot 'capture') 'watch-save.ps1'),
    (Join-Path $raycastRoot 'restart-autohotkey.ps1'),
    (Join-Path $raycastRoot 'reset-navicat.ps1'),
    (Join-Path $raycastRoot 'toggle-rgb.ps1'),
    (Join-Path $raycastRoot 'open-neomutt.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'DshRemoteUtils.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'Watch-DshRemote.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'Start-DshRemote.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'Stop-DshRemote.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'Get-DshRemoteStatus.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'Install-Watcher.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'Restart-Watcher.ps1'),
    (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'dsh-remote') 'Uninstall-Watcher.ps1'),
    (Join-Path $themeRoot 'ThemeUtils.ps1'),
    (Join-Path $themeRoot 'Update-ThemeSchedule.ps1'),
    (Join-Path $themeRoot 'Install-ThemeScheduler.ps1'),
    (Join-Path $themeRoot 'Uninstall-ThemeScheduler.ps1'),
    (Join-Path $themeRoot 'Set-Theme-Light.ps1'),
    (Join-Path $themeRoot 'Set-Theme-Dark.ps1'),
    (Join-Path $themeRoot 'Apply-ThemeNow.ps1'),
    (Join-Path $themeRoot 'Apply-CursorsNow.ps1'),
    (Join-Path $rgbRoot 'install.ps1'),
    (Join-Path $rgbRoot 'Start-OpenRGB.ps1'),
    (Join-Path $rgbRoot 'Stop-OpenRGB.ps1'),
    (Join-Path $rgbRoot 'Start-Ambient.ps1'),
    (Join-Path $rgbRoot 'Stop-Ambient.ps1'),
    (Join-Path $rgbRoot 'Install-Ambient.ps1'),
    (Join-Path $rgbRoot 'build_hi75.ps1')
  )
  $legacyImeHudDir = Join-Path (Join-Path $repoRoot 'tools') 'ime-hud'
  if (Test-Path -LiteralPath $legacyImeHudDir)
  {
    throw "legacy tools/ime-hud still exists; only tools/ime-hud-winui is allowed"
  }
  $legacyNotifyCli = Join-Path $notifyRoot 'notify-cli.ahk'
  if (Test-Path -LiteralPath $legacyNotifyCli)
  {
    throw "legacy shared/notify/notify-cli.ahk still exists; Raycast/OCR now use system toast only"
  }
  $legacyNotifyDev = Join-Path $notifyRoot 'dev'
  if (Test-Path -LiteralPath $legacyNotifyDev)
  {
    throw "legacy shared/notify/dev still exists; old HUD visual tests are gone"
  }

  $imeHudWinUiExe = Join-Path (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'ime-hud-winui') 'out') 'ImeHudWinUi.exe'
  if (-not (Test-Path -LiteralPath $imeHudWinUiExe -PathType Leaf))
  {
    throw "ImeHudWinUi.exe is missing; publish tools/ime-hud-winui before running tests"
  }
  # WinUI 是 WinExe，直接 & 调用时 5.1 经常不填 $LASTEXITCODE。
  # 用 Process 读 ExitCode，避免把 0 误判成失败。
  $selfTestInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $selfTestInfo.FileName = $imeHudWinUiExe
  $selfTestInfo.Arguments = '--self-test'
  $selfTestInfo.UseShellExecute = $false
  $selfTestInfo.CreateNoWindow = $true
  $selfTestInfo.RedirectStandardOutput = $true
  $selfTestInfo.RedirectStandardError = $true
  $selfTestProcess = [System.Diagnostics.Process]::Start($selfTestInfo)
  $selfTestOut = $selfTestProcess.StandardOutput.ReadToEndAsync()
  $selfTestErr = $selfTestProcess.StandardError.ReadToEndAsync()
  if (-not $selfTestProcess.WaitForExit(30000))
  {
    try { $selfTestProcess.Kill() } catch {}
    throw 'ImeHudWinUi --self-test timed out'
  }
  [void]$selfTestOut.Result
  [void]$selfTestErr.Result
  if ($selfTestProcess.ExitCode -ne 0)
  {
    throw ("ImeHudWinUi --self-test failed with exit code {0}" -f $selfTestProcess.ExitCode)
  }
  [Console]::Out.WriteLine('PASS: ImeHudWinUi --self-test')

  foreach ($scriptPath in $powerShellScripts)
  {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
      $scriptPath,
      [ref]$null,
      [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0)
    {
      throw ('PowerShell AST parse failed for {0}: {1}' -f $scriptPath, ($parseErrors.Message -join '; '))
    }
    [Console]::Out.WriteLine('PASS: PowerShell AST parse {0}' -f [System.IO.Path]::GetFileName($scriptPath))
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $autoHotkey
  $startInfo.WorkingDirectory = $PSScriptRoot
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.Arguments = '/ErrorStdOut=UTF-8 "{0}" --test "{1}" "{2}"' -f $testScript, $resultFile, $vsCodeTestRoot

  $process = [System.Diagnostics.Process]::Start($startInfo)
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(60000))
  {
    try { $process.Kill() } catch {}
    throw 'AutoHotkey core assertions timed out'
  }
  $standardOutput = $stdoutTask.Result
  $standardError = $stderrTask.Result

  if ($standardOutput)
  {
    [Console]::Out.Write($standardOutput)
  }
  if ($standardError)
  {
    [Console]::Error.Write($standardError)
  }

  $engineOutput = $standardOutput + "`n" + $standardError
  $hasParseError = $engineOutput -match '(?im)==>|\bError:|cannot be opened|does not contain a recognized action'
  $hasResult = Test-Path -LiteralPath $resultFile
  $result = if ($hasResult)
  { Get-Content -Raw -LiteralPath $resultFile
  } else
  { ''
  }
  $hasFreshPass = $hasResult -and $result.Trim() -ceq 'PASS: core assertions'

  if ($process.ExitCode -ne 0 -or $hasParseError -or -not $hasFreshPass)
  {
    if (-not $hasResult)
    {
      [Console]::Error.WriteLine('AutoHotkey test result file was not created.')
    } elseif (-not $hasFreshPass)
    {
      if ($result)
      {
        [Console]::Error.Write($result)
      }
      [Console]::Error.WriteLine('AutoHotkey test result is not the exact expected PASS marker.')
    }
  } else
  {
    [Console]::Out.Write($result)
    $runnerExitCode = 0
  }
} catch
{
  [Console]::Error.WriteLine($_.Exception.Message)
} finally
{
  Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $vsCodeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $runnerExitCode
