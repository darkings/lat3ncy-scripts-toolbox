# ToolboxProcess.Tests.ps1
# Isolated behavior tests for the watchdog process matcher.
# No real watchdog task, no AutoHotkey process, no CIM query is executed here.
# ASCII only on purpose (Windows PowerShell 5.1 without BOM reads ANSI).

param([string]$AutoHotkeyPath = '')

$ErrorActionPreference = 'Stop'

$helperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ToolboxProcess.ps1'
. $helperPath

$script:failed = 0

function Assert-True {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) {
    [Console]::Error.WriteLine("FAIL: $Name")
    $script:failed++
  }
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Name)
  if ($Expected -ne $Actual) {
    [Console]::Error.WriteLine("FAIL: $Name (expected '$Expected', got '$Actual')")
    $script:failed++
  }
}

$main = 'C:\Users\Example\Projects\lat3ncy-scripts-toolbox\ahk\main.ahk'
$other = 'C:\Users\Example\Projects\other-scripts\ahk\main.ahk'

# --- instance hash: known FNV-1a vectors (must match ToolboxInstance.Hash) ---
Assert-Equal '811c9dc5' (Get-ToolboxInstanceHash -Text '') 'FNV-1a empty'
Assert-Equal 'e40c292c' (Get-ToolboxInstanceHash -Text 'a') 'FNV-1a a'
Assert-Equal 'e40c292c' (Get-ToolboxInstanceHash -Text 'A') 'FNV-1a lower-cases input'
Assert-Equal '1a47e90b' (Get-ToolboxInstanceHash -Text 'abc') 'FNV-1a abc'
Assert-Equal (Get-ToolboxInstanceHash -Text 'C:\Repo') (Get-ToolboxInstanceHash -Text 'C:\Repo\') 'FNV-1a trims trailing slash'
$markerName = Get-ToolboxInstanceName -MainScript $main
Assert-True ($markerName -eq 'Local\Lat3ncyToolboxInstance-' + (Get-ToolboxInstanceHash -Text 'C:\Users\Example\Projects\lat3ncy-scripts-toolbox')) 'instance name includes repository hash'

# --- exact matching: only this repository's ahk/main.ahk -------------------
Assert-True (Test-ToolboxMainScriptCommandLine -CommandLine ('"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "' + $main + '"') -MainScript $main) 'quoted absolute path matches'
Assert-True (Test-ToolboxMainScriptCommandLine -CommandLine ('AutoHotkey64.exe ' + $main.Replace('\', '/')) -MainScript $main) 'forward-slash absolute path matches'

# Relative paths are ambiguous: any checkout can be launched with ".\ahk\main.ahk".
Assert-True (-not (Test-ToolboxMainScriptCommandLine -CommandLine 'AutoHotkey64.exe .\ahk\main.ahk' -MainScript $main)) 'relative launch cannot prove ownership'
Assert-True (-not (Test-ToolboxMainScriptCommandLine -CommandLine 'AutoHotkey64.exe ahk\main.ahk --debug' -MainScript $main)) 'relative launch with args cannot prove ownership'
Assert-True (-not (Test-ToolboxMainScriptCommandLine -CommandLine '"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\Apps\MyAhkScript.ahk"' -MainScript $main)) 'unrelated AutoHotkey script does not match'
Assert-True (-not (Test-ToolboxMainScriptCommandLine -CommandLine ('AutoHotkey64.exe ' + $other) -MainScript $main)) 'another repo main.ahk does not match'
Assert-True (-not (Test-ToolboxMainScriptCommandLine -CommandLine ($main + '.bak') -MainScript $main)) 'backup suffix does not match'
Assert-True (-not (Test-ToolboxMainScriptCommandLine -CommandLine 'AutoHotkey64.exe D:\other\ahk\main.ahk' -MainScript $main)) 'absolute other-repo relative-looking path does not match'
Assert-True (-not (Test-ToolboxMainScriptCommandLine -CommandLine '' -MainScript $main)) 'empty command line does not match'

# --- snapshot: markers, false positives and unreadable command lines -------
$unrelatedAhk = @([pscustomobject]@{
    Name = 'AutoHotkey64.exe'; ProcessId = 111; CommandLine = 'AutoHotkey64.exe C:\Apps\MyAhkScript.ahk'
  })
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { $unrelatedAhk } -MarkerProvider { 'absent' }
Assert-Equal 'not-running' $snapshot.Status 'unrelated AutoHotkey process is not the toolbox'
Assert-Equal 'start' (Get-WatchdogAhkAction -Status $snapshot.Status) 'unrelated AutoHotkey process does not block watchdog recovery'
Assert-Equal 'start' (Get-StartupGuardAction -Status $snapshot.Status) 'unrelated AutoHotkey process does not block startup'

$relativeAhk = @([pscustomobject]@{
    Name = 'AutoHotkey64.exe'; ProcessId = 112; CommandLine = 'AutoHotkey64.exe .\ahk\main.ahk'
  })
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { $relativeAhk } -MarkerProvider { 'absent' }
Assert-Equal 'not-running' $snapshot.Status 'relative main.ahk from another checkout is not this toolbox'

$unreadableAhk = @([pscustomobject]@{
    Name = 'AutoHotkey64.exe'; ProcessId = 113; CommandLine = $null
  })
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { $unreadableAhk } -MarkerProvider { 'absent' }
Assert-Equal 'query-failed' $snapshot.Status 'unreadable AutoHotkey command line stays unknown'
Assert-Equal 'query-failed' (Get-WatchdogAhkAction -Status $snapshot.Status) 'unreadable command line never starts a duplicate'

$toolboxProcess = @([pscustomobject]@{
    Name = 'AutoHotkey64.exe'; ProcessId = 222; CommandLine = ('AutoHotkey64.exe "' + $main + '"')
  })
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { $toolboxProcess } -MarkerProvider { 'absent' }
Assert-Equal 'running' $snapshot.Status 'exact toolbox process is recognized (legacy instance)'
Assert-Equal 222 ($snapshot.ProcessIds -join ',') 'snapshot keeps the toolbox pid'
Assert-Equal 'quiet' (Get-WatchdogAhkAction -Status $snapshot.Status) 'watchdog stays quiet when it owns the process'

# The marker is authoritative, independent of CIM and unreadable command lines.
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -MarkerProvider { 'present' } -ProcessProvider { throw 'must not query CIM' }
Assert-Equal 'running' $snapshot.Status 'instance marker alone proves the toolbox is running'
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -MarkerProvider { 'present' } -ProcessProvider { $unreadableAhk }
Assert-Equal 'running' $snapshot.Status 'marker overrides an unreadable toolbox command line'

$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -MarkerProvider { 'unknown' } -ProcessProvider { $toolboxProcess }
Assert-Equal 'running' $snapshot.Status 'unknown marker still accepts an exact readable path'
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -MarkerProvider { 'unknown' } -ProcessProvider { $unrelatedAhk }
Assert-Equal 'query-failed' $snapshot.Status 'unknown marker with no exact match stays unknown'

$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { throw 'CIM is unavailable' } -MarkerProvider { 'absent' } -NameProvider {
    @([pscustomobject]@{ ProcessName = 'AutoHotkey64'; Id = 555 })
  }
Assert-Equal 'query-failed' $snapshot.Status 'process query failure is distinct from absent'
Assert-Equal 'CIM is unavailable' $snapshot.ErrorMessage 'query failure keeps the diagnostic'
Assert-Equal 'query-failed' (Get-WatchdogAhkAction -Status $snapshot.Status) 'watchdog does not start after a query failure'
Assert-Equal 'query-failed' (Get-StartupGuardAction -Status $snapshot.Status -Force) 'startup does not force-stop after a query failure'

# CIM failure plus zero AutoHotkey processes proves the target is absent; starting
# is safe and does not risk replacing a running #SingleInstance Force instance.
$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { throw 'CIM is unavailable' } -MarkerProvider { 'absent' } -NameProvider { @() }
Assert-Equal 'not-running' $snapshot.Status 'query failure with no AutoHotkey process means absent'
Assert-Equal 'start' (Get-WatchdogAhkAction -Status $snapshot.Status) 'watchdog may start when no AutoHotkey process exists'
Assert-Equal 'start' (Get-StartupGuardAction -Status $snapshot.Status) 'startup may start when no AutoHotkey process exists'

$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { throw 'CIM is unavailable' } -MarkerProvider { 'absent' } -NameProvider { throw 'process enumeration failed' }
Assert-Equal 'query-failed' $snapshot.Status 'name query failure also stays unknown'

$snapshot = Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider { @() } -MarkerProvider { 'absent' }
Assert-Equal 'not-running' $snapshot.Status 'empty process list means the target is absent'

# --- real named mutex: marker present/absent without starting any watchdog --
# Use a synthetic repository path so the test can never collide with a live
# production toolbox marker for this checkout.
$markerTestMain = 'C:\Users\Example\Projects\marker-test-repo\ahk\main.ahk'
$markerTestName = Get-ToolboxInstanceName -MainScript $markerTestMain
$testMutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, $markerTestName
try {
  Assert-Equal 'present' (Get-ToolboxInstanceMarkerState -MainScript $markerTestMain) 'created instance mutex is detected'
  $snapshot = Get-ToolboxProcessSnapshot -MainScript $markerTestMain -ProcessProvider { throw 'must not query CIM' }
  Assert-Equal 'running' $snapshot.Status 'real instance mutex is authoritative for the snapshot'
} finally {
  $testMutex.Dispose()
}
Start-Sleep -Milliseconds 100
Assert-Equal 'absent' (Get-ToolboxInstanceMarkerState -MainScript $markerTestMain) 'disposed instance mutex is absent'

# --- startup error dialog: only the launched pid may be inspected ----------
$startupErrorTitle = -join @([char]0x542F, [char]0x52A8, [char]0x9519, [char]0x8BEF)
$foreignDialog = @([pscustomobject]@{ Id = 333; MainWindowTitle = $startupErrorTitle })
$snapshot = Get-ToolboxStartupErrorDialogSnapshot -ProcessIds @(444) -ProcessProvider {
    param([int[]]$Ids)
    $foreignDialog
  }
Assert-Equal 'not-running' $snapshot.Status 'error dialog from another AHK process is ignored'

$ownDialog = @([pscustomobject]@{ Id = 444; MainWindowTitle = $startupErrorTitle })
$snapshot = Get-ToolboxStartupErrorDialogSnapshot -ProcessIds @(444) -ProcessProvider {
    param([int[]]$Ids)
    $ownDialog
  }
Assert-Equal 'running' $snapshot.Status 'error dialog from the launched toolbox pid is recognized'

$snapshot = Get-ToolboxStartupErrorDialogSnapshot -ProcessIds @(444) -ProcessProvider {
    param([int[]]$Ids)
    throw 'process query failed'
  }
Assert-Equal 'query-failed' $snapshot.Status 'dialog query failure is distinct from no dialog'

# The power watchdog must use this checkout's absolute path and an exact -Run token.
$power = 'C:\Example\My Tools\tools\power-policy\PowerPolicy.ps1'
foreach ($command in @(
  'pwsh.exe -File C:\Other\PowerPolicy.ps1 -Run',
  ('pwsh.exe -File "' + $power + '" -RunOnce'),
  ('pwsh.exe -File "' + $power + '.old" -Run')
)) {
  $snapshot = Get-ToolboxPowerPolicySnapshot -PowerScript $power -ProcessProvider {
    [pscustomobject]@{ Name='pwsh.exe'; ProcessId=91; CommandLine=$command }
  }
  Assert-Equal 'not-running' $snapshot.Status 'foreign script / parameter prefix is not resident'
}
$snapshot=Get-ToolboxPowerPolicySnapshot -PowerScript $power -ProcessProvider {
  [pscustomobject]@{Name='powershell.exe';ProcessId=92;CommandLine=('powershell.exe -File "'+$power+'" -Run')}
}
Assert-Equal 'running' $snapshot.Status 'exact power script works for Windows PowerShell too'
$snapshot=Get-ToolboxPowerPolicySnapshot -PowerScript $power -ProcessProvider {
  [pscustomobject]@{Name='pwsh.exe';ProcessId=93;CommandLine=$null}
}
Assert-Equal 'query-failed' $snapshot.Status 'unreadable power process remains unknown'

# Execute just the real restart matcher, never the script's stop/start actions.
$restart=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'raycast-scripts\restart-autohotkey.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($restart,[ref]$tokens,[ref]$errors)
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ToolboxAutoHotkeyProcess'},$true)
Invoke-Expression $definition.Extent.Text
$resolvedMainScript=$main
function Get-CimInstance {
  @([pscustomobject]@{Name='AutoHotkey64.exe';ProcessId=94;CommandLine='AutoHotkey64.exe C:\Other\lat3ncy-scripts-toolbox\ahk\main.ahk'},
    [pscustomobject]@{Name='AutoHotkey64.exe';ProcessId=95;CommandLine=('AutoHotkey64.exe "'+$main+'"')})
}
try {
  $selected=@(Get-ToolboxAutoHotkeyProcess)
  Assert-Equal 1 $selected.Count 'restart selects only current checkout'
  Assert-Equal 95 $selected[0].ProcessId 'foreign checkout never enters kill list'
} finally { Remove-Item Function:\Get-CimInstance }

if ($AutoHotkeyPath) {
  $spaceRoot=Join-Path ([IO.Path]::GetTempPath()) ('toolbox startup space ' + [Guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $spaceRoot)
  try {
    $stub=Join-Path $spaceRoot 'main.ahk'; $result=Join-Path $spaceRoot 'result.txt'
    [IO.File]::WriteAllText($stub, "#Requires AutoHotkey v2.0`nFileAppend `"launched`", A_Args[1]`nExitApp 0`n", [Text.Encoding]::ASCII)
    $arguments=(ConvertTo-ToolboxCommandLineArgument $stub) + ' ' + (ConvertTo-ToolboxCommandLineArgument $result)
    $started=Start-Process -FilePath $AutoHotkeyPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not $started.WaitForExit(10000)) { $started.Kill(); throw 'spaced AHK launch timed out' }
    Assert-Equal 0 $started.ExitCode 'spaced path launches real AHK'
    Assert-Equal 'launched' ([IO.File]::ReadAllText($result)) 'AHK receives full spaced script and argument paths'
    $started.Dispose()
  } finally {
    Get-ChildItem -LiteralPath $spaceRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $spaceRoot
  }
}

if ($script:failed -gt 0) {
  [Console]::Error.WriteLine("startup tests failed: $($script:failed)")
  exit 1
}
[Console]::Out.WriteLine('PASS: startup process isolation tests')
exit 0
