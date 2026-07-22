$ErrorActionPreference = 'Stop'

# Task 1 test entry point. It owns result-file cleanup and waits for the real AHK
# v2 engine so a Scoop UX shim or an include/parse failure cannot reuse stale PASS.
$resultFile = Join-Path $env:TEMP 'lat3ncy-toolbox-test-result.txt'
$testScript = Join-Path $PSScriptRoot 'run-tests.ahk'

Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue

function Resolve-AutoHotkeyV2Executable {
    $command = Get-Command AutoHotkey.exe -ErrorAction Stop
    $executable = $command.Source
    $shimFile = [System.IO.Path]::ChangeExtension($executable, '.shim')

    if (Test-Path -LiteralPath $shimFile) {
        $shimText = Get-Content -Raw -LiteralPath $shimFile
        if ($shimText -match '(?m)^path\s*=\s*"([^"]+)"') {
            $shimTarget = $Matches[1]
            if ([System.IO.Path]::GetFileName($shimTarget) -ieq 'AutoHotkeyUX.exe') {
                $installRoot = Split-Path (Split-Path $shimTarget -Parent) -Parent
                $engineName = if ([Environment]::Is64BitOperatingSystem) {
                    'AutoHotkey64.exe'
                } else {
                    'AutoHotkey32.exe'
                }
                $engine = Join-Path (Join-Path $installRoot 'v2') $engineName
                if (Test-Path -LiteralPath $engine) {
                    return $engine
                }
                throw "Unable to locate the AutoHotkey v2 engine behind shim target: $shimTarget"
            }
            if (Test-Path -LiteralPath $shimTarget) {
                return $shimTarget
            }
        }
    }

    return $executable
}

try {
    $autoHotkey = Resolve-AutoHotkeyV2Executable
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $autoHotkey
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = '/ErrorStdOut=UTF-8 "{0}" --test' -f $testScript

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

if ($standardOutput) {
    [Console]::Out.Write($standardOutput)
}
if ($standardError) {
    [Console]::Error.Write($standardError)
}

$engineOutput = $standardOutput + "`n" + $standardError
$hasParseError = $engineOutput -match '(?im)==>|\bError:|cannot be opened|does not contain a recognized action'
$hasResult = Test-Path -LiteralPath $resultFile
$result = if ($hasResult) { Get-Content -Raw -LiteralPath $resultFile } else { '' }
$hasFreshPass = $hasResult -and $result.StartsWith('PASS', [System.StringComparison]::Ordinal)

if ($process.ExitCode -ne 0 -or $hasParseError -or -not $hasFreshPass) {
    if (-not $hasResult) {
        [Console]::Error.WriteLine('AutoHotkey test result file was not created.')
    } elseif (-not $hasFreshPass) {
        [Console]::Error.WriteLine('AutoHotkey test result does not begin with PASS.')
    }
    exit 1
}

[Console]::Out.Write($result)
exit 0
