$ErrorActionPreference = 'Stop'

# Task 1 test entry point. Each invocation owns a unique result file and waits for
# the real AHK v2 engine so concurrent runs and parse failures cannot reuse PASS.
$resultFile = Join-Path ([System.IO.Path]::GetTempPath()) (
    'lat3ncy-toolbox-test-{0}.txt' -f [guid]::NewGuid().ToString('N')
)
$testScript = Join-Path $PSScriptRoot 'run-tests.ahk'

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

$runnerExitCode = 1
try {
    $autoHotkey = Resolve-AutoHotkeyV2Executable
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $autoHotkey
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = '/ErrorStdOut=UTF-8 "{0}" --test "{1}"' -f $testScript, $resultFile

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

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
    $hasFreshPass = $hasResult -and $result.Trim() -ceq 'PASS: core assertions'

    if ($process.ExitCode -ne 0 -or $hasParseError -or -not $hasFreshPass) {
        if (-not $hasResult) {
            [Console]::Error.WriteLine('AutoHotkey test result file was not created.')
        } elseif (-not $hasFreshPass) {
            [Console]::Error.WriteLine('AutoHotkey test result is not the exact expected PASS marker.')
        }
    } else {
        [Console]::Out.Write($result)
        $runnerExitCode = 0
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
}

exit $runnerExitCode
