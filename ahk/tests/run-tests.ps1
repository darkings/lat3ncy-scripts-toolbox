param(
  # Build tools/ime-hud-winui from source into test-out and then run the full suite.
  # Without this switch the suite refuses a missing/stale test-out build.
  [switch]$BuildImeHud
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\tools\ime-hud-winui\BuildSupport.ps1')

# Task 1 test entry point. Each invocation owns a unique result file and waits for
# the real AHK v2 engine so concurrent runs and parse failures cannot reuse PASS.
$resultFile = Join-Path ([System.IO.Path]::GetTempPath()) (
  'lat3ncy-toolbox-test-{0}.txt' -f [guid]::NewGuid().ToString('N')
)
$vsCodeTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'lat3ncy-copy-path-folder-{0}' -f [guid]::NewGuid().ToString('N')
)
$testScript = Join-Path $PSScriptRoot 'run-tests.ahk'

function Invoke-CheckedProcess
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $FilePath,
    [string[]] $Arguments = @(),
    [Parameter(Mandatory = $true)]
    [string] $Label,
    [int] $TimeoutSeconds = 180
  )

  $argumentLine = (@($Arguments) | ForEach-Object {
      if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = $argumentLine
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($startInfo)
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutSeconds * 1000))
  {
    try { $process.Kill() } catch {}
    throw "$Label timed out after $TimeoutSeconds seconds"
  }
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  if ($stdout) { [Console]::Out.Write($stdout) }
  if ($stderr) { [Console]::Error.Write($stderr) }
  if ($process.ExitCode -ne 0)
  {
    throw "$Label failed with exit code $($process.ExitCode)"
  }
  [Console]::Out.WriteLine("PASS: $Label")
}

function Assert-ImeHudBuildFresh
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectDir,
    [Parameter(Mandatory = $true)]
    [string] $OutDir,
    [switch] $Build
  )

  if ($Build)
  {
    Invoke-ImeHudBuild -ProjectDir $ProjectDir -OutDir $OutDir
    return
  }

  $exe = Join-Path $OutDir 'ImeHudWinUi.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf))
  {
    throw "ImeHudWinUi.exe is missing under $OutDir; run 'ahk\tests\run-tests.ps1 -BuildImeHud'"
  }
  $stampPath = Join-Path $OutDir '.source-stamp'
  if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf))
  {
    throw "ImeHudWinUi build stamp is missing under $OutDir; run 'ahk\tests\run-tests.ps1 -BuildImeHud'"
  }
  $expected = Get-ImeHudSourceHash -ProjectDir $ProjectDir
  $actual = (Get-Content -Raw -LiteralPath $stampPath).Trim()
  if ($actual -ne $expected)
  {
    throw "ImeHudWinUi test-out was built from different sources (stamp mismatch); rerun with -BuildImeHud"
  }
  [Console]::Out.WriteLine('PASS: ImeHudWinUi test build matches current sources')
}


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
#Warn VarUnset, StdOut
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
    (Join-Path $featureRoot 'text-workflow.ahk'),
    (Join-Path $featureRoot 'translate-selected-text.ahk'),
    (Join-Path $featureRoot 'audio-switcher.ahk'),
    (Join-Path $featureRoot 'switch-app-window.ahk'),
    (Join-Path $featureRoot 'find-mouse.ahk'),
    (Join-Path $featureRoot 'thinkpad-backlight.ahk'),
    (Join-Path $notifyRoot 'run-nowindow.ahk'),
    (Join-Path $notifyRoot 'ime-hud.ahk'),
    (Join-Path $notifyRoot 'translation-panel.ahk'),
    (Join-Path $notifyRoot 'toolbox-instance.ahk'),
    (Join-Path (Split-Path $notifyRoot -Parent) 'python.ahk')
  )
  foreach ($featurePath in $independentFeatures)
  {
    Test-FeatureLoadsIndependently -AutoHotkey $autoHotkey -NotifyRoot $notifyRoot -FeaturePath $featurePath
  }

  $raycastRoot = Join-Path (Join-Path $repoRoot 'tools') 'raycast-scripts'
  $rgbRoot = Join-Path (Join-Path $repoRoot 'tools') 'rgb'
  $themeRoot = Join-Path (Join-Path $repoRoot 'tools') 'theme-scheduler'
  $startupRoot = Join-Path (Join-Path $repoRoot 'tools') 'startup'

  # Cross-language check: AHK and PowerShell must produce the same per-repo
  # instance marker name, otherwise the watchdog can never see a live toolbox.
  . (Join-Path $startupRoot 'ToolboxProcess.ps1')
  $mainScriptForMarker = Join-Path $repoRoot 'ahk\main.ahk'
  $expectedMarkerName = Get-ToolboxInstanceName -MainScript $mainScriptForMarker
  $markerStubPath = Join-Path ([System.IO.Path]::GetTempPath()) (
    'lat3ncy-toolbox-marker-{0}.ahk' -f [guid]::NewGuid().ToString('N')
  )
  $markerNameFile = Join-Path ([System.IO.Path]::GetTempPath()) (
    'lat3ncy-toolbox-marker-{0}.txt' -f [guid]::NewGuid().ToString('N')
  )
  try
  {
    $markerStub = @"
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
OnError (*) => ExitApp(1)
#Include "$repoRoot\shared\notify\toolbox-instance.ahk"
FileAppend ToolboxInstance.MutexName("$repoRoot"), "$markerNameFile", "UTF-8"
ExitApp 0
"@
    $markerEncoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($markerStubPath, $markerStub, $markerEncoding)

    $markerInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $markerInfo.FileName = $autoHotkey
    $markerInfo.Arguments = '/ErrorStdOut=UTF-8 "{0}"' -f $markerStubPath
    $markerInfo.UseShellExecute = $false
    $markerInfo.CreateNoWindow = $true
    $markerInfo.RedirectStandardOutput = $true
    $markerInfo.RedirectStandardError = $true
    $markerProcess = [System.Diagnostics.Process]::Start($markerInfo)
    $markerOutTask = $markerProcess.StandardOutput.ReadToEndAsync()
    $markerErrTask = $markerProcess.StandardError.ReadToEndAsync()
    if (-not $markerProcess.WaitForExit(15000))
    {
      try { $markerProcess.Kill() } catch {}
      throw 'toolbox instance marker AHK check timed out'
    }
    $markerEngineOutput = $markerOutTask.Result + "`n" + $markerErrTask.Result
    if ($markerProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $markerNameFile -PathType Leaf))
    {
      throw ("toolbox instance marker AHK check failed: " + $markerEngineOutput.Trim())
    }
    $actualMarkerName = (Get-Content -Raw -LiteralPath $markerNameFile).Trim()
    if ($actualMarkerName -ne $expectedMarkerName)
    {
      throw ("toolbox instance marker mismatch: AHK='{0}' PowerShell='{1}'" -f $actualMarkerName, $expectedMarkerName)
    }
    [Console]::Out.WriteLine('PASS: toolbox instance marker name matches PowerShell')
  }
  finally
  {
    Remove-Item -LiteralPath $markerStubPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $markerNameFile -ErrorAction SilentlyContinue
  }

  # 只做 AST 解析，绝不执行 install.ps1 / Install-*：那些脚本会改服务、计划任务和硬件。
  $legacyImeHudDir = Join-Path (Join-Path $repoRoot 'tools') 'ime-hud'
  # Include newly added modules/tests automatically; do not let a hand-written
  # list silently exclude PowerPolicy or future helpers from AST/BOM checks.
  $powerShellScripts = @(Get-ChildItem -LiteralPath @(
      (Join-Path $repoRoot 'ahk'), (Join-Path $repoRoot 'shared'), (Join-Path $repoRoot 'tools')
    ) -Filter '*.ps1' -Recurse -File | Where-Object {
      $_.FullName -notmatch '\\(bin|obj|out|test-out|dist|\.venv[^\\]*|__pycache__)\\'
    } | Select-Object -ExpandProperty FullName | Sort-Object -Unique)
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
  # codex-switch 现在是 Raycast 扩展（C:\Users\Jie\Projects\codex-switch-raycast），
  # 不再是 Script Command；这里守住，避免旧脚本被重新加回来。
  $legacyCodexSwitch = Join-Path $raycastRoot 'codex-switch.ps1'
  if (Test-Path -LiteralPath $legacyCodexSwitch)
  {
    throw "legacy tools/raycast-scripts/codex-switch.ps1 still exists; use the codex-switch-raycast extension instead"
  }

  $imeHudProjectDir = Join-Path (Join-Path $repoRoot 'tools') 'ime-hud-winui'
  $imeHudOutDir = Join-Path $imeHudProjectDir 'test-out'
  Assert-ImeHudBuildFresh -ProjectDir $imeHudProjectDir -OutDir $imeHudOutDir -Build:$BuildImeHud
  $imeHudWinUiExe = Join-Path $imeHudOutDir 'ImeHudWinUi.exe'
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
  Invoke-CheckedProcess -FilePath (Join-Path $notifyRoot 'anchor-locator.exe') -Arguments @(
    '--self-test'
  ) -Label 'anchor-locator geometry and protocol self-test'

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

  # ---- 编码约定（README「已知坑」）----
  # 非 ASCII 的 .ps1 必须带 UTF-8 BOM：Windows PowerShell 5.1 按 ANSI 解析无 BOM 文件，
  # 中文会变成乱码甚至语法错误（2026-11 连续踩了两次）。以前只写在文档里，没人校验。
  $encodingTargets = @($powerShellScripts) + @($PSCommandPath)
  foreach ($scriptPath in $encodingTargets)
  {
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { continue }
    $bytes = [IO.File]::ReadAllBytes($scriptPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -ge 0x80) { $hasNonAscii = $true; break } }
    if ($hasNonAscii -and -not $hasBom)
    {
      throw ('{0} has non-ASCII bytes but no UTF-8 BOM; PowerShell 5.1 reads BOM-less files as ANSI' -f $scriptPath)
    }
    [Console]::Out.WriteLine('PASS: UTF-8 BOM {0}' -f [System.IO.Path]::GetFileName($scriptPath))
  }

  # run-tests.ps1 自身必须保持 CRLF（README 约定）。
  $selfBytes = [IO.File]::ReadAllBytes($PSCommandPath)
  $bareLf = 0
  for ($i = 0; $i -lt $selfBytes.Length; $i++)
  {
    if ($selfBytes[$i] -eq 0x0A -and ($i -eq 0 -or $selfBytes[$i - 1] -ne 0x0D)) { $bareLf++ }
  }
  if ($bareLf -gt 0) { throw ('run-tests.ps1 has {0} bare LF line endings; it must stay CRLF' -f $bareLf) }
  [Console]::Out.WriteLine('PASS: run-tests.ps1 keeps CRLF line endings')
  # Python helper self-tests + behavior tests belong to the same check entry.
  $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
  if (-not $pythonCommand)
  {
    throw 'python.exe not found; Python 3.11+ is required for translate/tts tests'
  }
  $translateRoot = Join-Path (Join-Path $repoRoot 'tools') 'translate'
  $ttsRoot = Join-Path (Join-Path $repoRoot 'tools') 'tts'
  $translatePy = Join-Path $translateRoot 'translate.py'
  $ttsPy = Join-Path $ttsRoot 'tts_player.py'
  Invoke-CheckedProcess -FilePath $pythonCommand.Source -Arguments @(
    '-m', 'py_compile', $translatePy, $ttsPy
  ) -Label 'Python compile translate/tts'
  Invoke-CheckedProcess -FilePath $pythonCommand.Source -Arguments @(
    $translatePy, '--self-test'
  ) -Label 'translate self-test'
  Invoke-CheckedProcess -FilePath $pythonCommand.Source -Arguments @(
    $ttsPy, '--self-test'
  ) -Label 'tts self-test'
  Invoke-CheckedProcess -FilePath $pythonCommand.Source -Arguments @(
    '-m', 'unittest', 'discover', '-s', $translateRoot, '-p', 'test_*.py', '-v'
  ) -Label 'translate behavior tests'
  Invoke-CheckedProcess -FilePath $pythonCommand.Source -Arguments @(
    '-m', 'unittest', 'discover', '-s', $ttsRoot, '-p', 'test_*.py', '-v'
  ) -Label 'tts behavior tests'

  # Isolated behavior tests for the watchdog matcher (no real task, no CIM query).
  $startupTests = Join-Path (Join-Path $startupRoot 'tests') 'ToolboxProcess.Tests.ps1'
  Invoke-CheckedProcess -FilePath 'powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startupTests, '-AutoHotkeyPath', $autoHotkey
  ) -Label 'startup process isolation tests'
  Invoke-CheckedProcess -FilePath 'powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $startupRoot 'tests\PowerPolicyHeartbeat.Tests.ps1')
  ) -Label 'PowerPolicy heartbeat identity tests'
  Invoke-CheckedProcess -FilePath 'powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $startupRoot 'tests\Deployment.Tests.ps1')
  ) -Label 'release transaction rollback tests'
  Invoke-CheckedProcess -FilePath 'powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $startupRoot 'tests\DeploymentLease.Tests.ps1')
  ) -Label 'deployment lease isolation tests'
  Invoke-CheckedProcess -FilePath 'powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $repoRoot 'tools\build\tests\ManagedBuild.Tests.ps1')
  ) -Label 'managed build provenance tests'

  Invoke-CheckedProcess -FilePath 'powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $repoRoot 'tools\power-policy\tests\Recovery.Tests.ps1')
  ) -Label 'offline power recovery tests'
  Invoke-CheckedProcess -FilePath 'powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $repoRoot 'tools\theme-scheduler\tests\ThemeEntry.Tests.ps1')
  ) -Label 'isolated theme entry tests'
  foreach ($module in @(
    @{ Dir = (Join-Path $raycastRoot 'ocr'); Pattern = 'test_*.py'; Label = 'OCR offline behavior and host tests' },
    @{ Dir = $rgbRoot; Pattern = 'test_protocols.py'; Label = 'RGB offline protocol tests' }
    @{ Dir = (Join-Path $repoRoot 'tools\validation'); Pattern = 'test_*.py'; Label = 'clean snapshot isolation tests' }
  )) {
    Invoke-CheckedProcess -FilePath $pythonCommand.Source -Arguments @(
      '-m', 'unittest', 'discover', '-s', $module.Dir, '-p', $module.Pattern, '-v'
    ) -Label $module.Label
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
