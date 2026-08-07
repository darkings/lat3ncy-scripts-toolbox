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
    [string] $FeaturePath
  )

  $stubPath = Join-Path ([System.IO.Path]::GetTempPath()) (
    'lat3ncy-toolbox-feature-{0}.ahk' -f [guid]::NewGuid().ToString('N')
  )
  $stub = @"
#Requires AutoHotkey v2.0
class Shortcuts {
    static CapsLockIme := "`$CapsLock"
    static AlwaysOnTop := "^#t"
    static ToggleHiddenFiles := "#+."
    static SearchSelectedText := "^+g"
    static SmartPaste := "`$^v"
    static VsCodeCopyPath := "+!c"
    static ZedCopyPath := "+!c"
    static OpenSelectedTarget := "^!o"
    static LocateSelectedTarget := "^!e"
    static SwitchAppWindowNext := "!sc029"
    static SwitchAppWindowPrevious := "+!sc029"
}
IsToolboxTestMode() => true
RegisterFeatureHotkey(*) => 0
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
    $startInfo.Arguments = '/ErrorStdOut=UTF-8 "{0}"' -f $stubPath

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

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
  $featureRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'features'
  $independentFeatures = @(
    (Join-Path $featureRoot 'caps-lock-ime.ahk'),
    (Join-Path $featureRoot 'always-on-top.ahk'),
    (Join-Path $featureRoot 'toggle-hidden-files.ahk'),
    (Join-Path $featureRoot 'search-selected-text.ahk'),
    (Join-Path (Join-Path $featureRoot 'smart-paste') 'smart-paste.ahk'),
    (Join-Path $featureRoot 'open-selected-target.ahk'),
    (Join-Path $featureRoot 'locate-selected-target.ahk'),
    (Join-Path $featureRoot 'switch-app-window.ahk')
  )
  foreach ($featurePath in $independentFeatures)
  {
    Test-FeatureLoadsIndependently -AutoHotkey $autoHotkey -FeaturePath $featurePath
  }

  $helperPath = Join-Path (Join-Path $featureRoot 'smart-paste') 'save-clipboard-image.ps1'
  $parseErrors = $null
  [void][Management.Automation.Language.Parser]::ParseFile(
    $helperPath,
    [ref]$null,
    [ref]$parseErrors
  )
  if ($parseErrors.Count -ne 0)
  {
    throw ('PowerShell helper AST parse failed: {0}' -f ($parseErrors.Message -join '; '))
  }
  [Console]::Out.WriteLine('PASS: PowerShell helper AST parse')

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $autoHotkey
  $startInfo.WorkingDirectory = $PSScriptRoot
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Arguments = '/ErrorStdOut=UTF-8 "{0}" --test "{1}" "{2}"' -f $testScript, $resultFile, $vsCodeTestRoot

  $process = [System.Diagnostics.Process]::Start($startInfo)
  $standardOutput = $process.StandardOutput.ReadToEnd()
  $standardError = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

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
