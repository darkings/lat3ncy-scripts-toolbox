# ToolboxProcess.ps1
# Dot-sourceable helpers shared by Ensure-ToolboxRunning.ps1 and Start-Toolbox.ps1.
#
# The watchdog must only recognize THIS repository's ahk/main.ahk. Matching by
# process name alone is wrong: any other AutoHotkey script would then block
# recovery. main.ahk also creates a per-repository named mutex
# (Local\Lat3ncyToolboxInstance-<path hash>); that marker is authoritative and
# works even when CIM/command lines are unavailable. Relative ".\ahk\main.ahk"
# paths and unreadable command lines are never treated as a positive match.
# Query failures are also distinct from "target absent"; treating a failed query
# as absent can start a duplicate instance (main.ahk uses #SingleInstance Force,
# so the new instance would replace the running one).
#
# ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI.
# The Chinese dialog title is built from code points so this file stays ASCII.
$script:ToolboxStartupErrorTitle = -join @(
  [char]0x542F, [char]0x52A8, [char]0x9519, [char]0x8BEF
)
. (Join-Path $PSScriptRoot '..\power-policy\PowerPolicy.Identity.ps1')

function Get-ToolboxDeploymentState {
  param([string]$MainScript)
  $mutex=$null;$owned=$false
  try {
    $mutex=[Threading.Mutex]::OpenExisting(((Get-ToolboxInstanceName $MainScript)+'-Deployment'))
    try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
    if($owned){return 'idle'}
    return 'active'
  } catch [Threading.WaitHandleCannotBeOpenedException] {return 'idle'}
  catch {return 'unknown'}
  finally {if($owned){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}

function Test-ToolboxMainScriptCommandLine {
  param(
    [string]$CommandLine,
    [Parameter(Mandatory = $true)]
    [string]$MainScript
  )

  return Test-ToolboxScriptCommandLine -CommandLine $CommandLine -ScriptPath $MainScript
}

function Test-ToolboxScriptCommandLine {
  param([string]$CommandLine, [Parameter(Mandatory = $true)][string]$ScriptPath)

  if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($ScriptPath)) {
    return $false
  }

  $normalized = $CommandLine.Replace('/', '\')
  $normalizedMain = ([System.IO.Path]::GetFullPath($ScriptPath)).Replace('/', '\')

  # Only an exact absolute path can prove which checkout owns the process. A
  # relative ".\ahk\main.ahk" is ambiguous (any repository can use it), so it is
  # intentionally not accepted here; the per-repository instance marker covers
  # normal launches of this toolbox.
  $pathPattern = [regex]::Escape($normalizedMain)
  $absolutePattern = '(?i)(?:^|\s)"' + $pathPattern + '"(?=$|\s)'
  if ($normalizedMain -notmatch '\s') {
    $absolutePattern += '|(?i)(?:^|\s)' + $pathPattern + '(?=$|\s)'
  }
  return $normalized -match $absolutePattern
}

function ConvertTo-ToolboxCommandLineArgument {
  param([AllowEmptyString()][string]$Value)
  return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ToolboxPowerPolicySnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$PowerScript,
    [scriptblock]$ProcessProvider,
    [scriptblock]$HeartbeatProvider,
    [scriptblock]$IdentityProvider,
    [scriptblock]$FingerprintProvider,
    [datetime]$NowUtc = [DateTime]::UtcNow,
    [int]$MaxHeartbeatAgeSeconds = 60
  )
  # Injected process lists stay isolated unless a heartbeat is also supplied.
  if (-not $HeartbeatProvider -and -not $ProcessProvider) {
    $HeartbeatProvider = {
      $path=Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\power-policy-status.json'
      if(Test-Path -LiteralPath $path -PathType Leaf){Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop}
    }
  }
  if(-not $IdentityProvider){$IdentityProvider={param($Id) Get-ToolboxProcessStartIdentity -ProcessId $Id}}
  if(-not $FingerprintProvider){$FingerprintProvider={param($Path) Get-ToolboxPowerFingerprint -PowerScript $Path}}
  $heartbeatError=''
  if($HeartbeatProvider){
    try {
      $beat=& $HeartbeatProvider
      if($beat -and $beat.identityVersion -eq 1){
        $expected=[IO.Path]::GetFullPath($PowerScript)
        $root=Split-Path (Split-Path (Split-Path $expected -Parent) -Parent) -Parent
        if([string]::Equals([IO.Path]::GetFullPath([string]$beat.scriptPath),$expected,[StringComparison]::OrdinalIgnoreCase) -and
           [string]::Equals([IO.Path]::GetFullPath([string]$beat.repoRoot),$root,[StringComparison]::OrdinalIgnoreCase)){
          if([int]$beat.pid -le 0 -or [long]$beat.startTicks -le 0 -or [string]$beat.sourceFingerprint -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid heartbeat identity'}
          $identity=& $IdentityProvider ([int]$beat.pid)
          if($identity.Status -eq 'present' -and $identity.Name -in @('pwsh','powershell') -and
             [long]$identity.StartTicks -eq [long]$beat.startTicks){
            # PS 5.1 leaves JSON ISO dates as strings; newer PS 7 converts them
            # to DateTime. Casting that object to string loses Kind/timezone.
            if($beat.updatedUtc -is [datetime]){$updatedUtc=$beat.updatedUtc.ToUniversalTime()}
            elseif($beat.updatedUtc -is [datetimeoffset]){$updatedUtc=$beat.updatedUtc.UtcDateTime}
            else{$updatedUtc=[DateTimeOffset]::Parse([string]$beat.updatedUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime}
            $age=($NowUtc.ToUniversalTime()-$updatedUtc).TotalSeconds
            if($age -lt -5 -or $age -gt $MaxHeartbeatAgeSeconds){
              return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage 'PowerPolicy identity matches but heartbeat is stale or in the future'
            }
            $fingerprint=& $FingerprintProvider $expected
            $state=if($fingerprint -eq $beat.sourceFingerprint){'running'}else{'outdated'}
            $snapshot=New-ToolboxProcessSnapshot -Status $state -Processes @([pscustomobject]@{ProcessId=[int]$beat.pid})
            $snapshot | Add-Member -NotePropertyName Evidence -NotePropertyValue 'heartbeat'
            return $snapshot
          }
          if($identity.Status -eq 'unknown'){$heartbeatError='Heartbeat process identity is unreadable'}
        }
      }
    } catch {$heartbeatError='Invalid PowerPolicy heartbeat: '+$_.Exception.Message}
  }
  if (-not $ProcessProvider) { $ProcessProvider = { Get-CimInstance Win32_Process -ErrorAction Stop } }
  try { $all = @(& $ProcessProvider) }
  catch { return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage $_.Exception.Message }
  $hosts = @($all | Where-Object { $_.Name -in @('pwsh.exe','powershell.exe') })
  $matching = @($hosts | Where-Object {
    $_.CommandLine -and
    (Test-ToolboxScriptCommandLine -CommandLine $_.CommandLine -ScriptPath $PowerScript) -and
    $_.CommandLine -match '(?i)(?:^|\s)-Run(?=\s|$)'
  })
  if ($matching.Count -gt 0) {
    if($heartbeatError){return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage $heartbeatError}
    return New-ToolboxProcessSnapshot -Status 'running' -Processes $matching
  }
  if (@($hosts | Where-Object { -not $_.CommandLine }).Count -gt 0) {
    return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage 'PowerShell process command line is unreadable'
  }
  return New-ToolboxProcessSnapshot -Status 'not-running'
}

# FNV-1a 32-bit over the lower-cased UTF-8 path. Keep byte-for-byte identical to
# ToolboxInstance.Hash() in shared/notify/toolbox-instance.ahk; run-tests.ps1
# compares the two implementations.
function Get-ToolboxInstanceHash {
  param(
    [AllowEmptyString()]
    [string]$Text
  )

  $normalized = $Text.TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
  $hash = [uint64]2166136261
  foreach ($byte in $bytes) {
    $hash = ((($hash -bxor [uint64]$byte) * [uint64]16777619) -band [uint64]4294967295)
  }
  return $hash.ToString('x8')
}

function Get-ToolboxInstanceName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MainScript
  )

  $fullMain = [System.IO.Path]::GetFullPath($MainScript)
  $repoRoot = Split-Path (Split-Path $fullMain -Parent) -Parent
  return 'Local\Lat3ncyToolboxInstance-' + (Get-ToolboxInstanceHash -Text $repoRoot)
}

function Get-ToolboxInstanceMarkerState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MainScript,
    [scriptblock]$MarkerProvider
  )

  $mutexName = Get-ToolboxInstanceName -MainScript $MainScript
  if (-not $MarkerProvider) {
    $MarkerProvider = {
      param([string]$Name)
      try {
        $mutex = [System.Threading.Mutex]::OpenExisting($Name)
        try { $mutex.Dispose() } catch {}
        return 'present'
      } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return 'absent'
      } catch [System.UnauthorizedAccessException] {
        # The object exists even if this token cannot open it for synchronize.
        return 'present'
      } catch {
        return 'unknown'
      }
    }
  }

  try {
    $state = & $MarkerProvider $mutexName
  } catch {
    return 'unknown'
  }
  if ($state -eq 'present' -or $state -eq 'absent') {
    return $state
  }
  return 'unknown'
}

function New-ToolboxProcessSnapshot {
  param(
    [ValidateSet('running', 'not-running', 'query-failed', 'outdated')]
    [string]$Status,
    [object[]]$Processes = @(),
    [string]$ErrorMessage = ''
  )

  $ids = @($Processes | ForEach-Object { [int]$_.ProcessId })
  return [pscustomobject]@{
    Status       = $Status
    Processes    = @($Processes)
    ProcessIds   = $ids
    ErrorMessage = $ErrorMessage
  }
}

function Get-ToolboxProcessSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MainScript,
    [scriptblock]$ProcessProvider,
    # Used only when the command-line query fails: an empty AutoHotkey process
    # list proves the target is absent, while a non-empty list is ambiguous.
    [scriptblock]$NameProvider,
    [scriptblock]$MarkerProvider
  )

  if (-not $ProcessProvider) {
    $ProcessProvider = {
      Get-CimInstance Win32_Process -ErrorAction Stop
    }
  }
  if (-not $NameProvider) {
    $NameProvider = {
      Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -like 'AutoHotkey*' }
    }
  }

  # The named mutex is authoritative and independent of WMI/CIM visibility.
  $markerState = Get-ToolboxInstanceMarkerState -MainScript $MainScript -MarkerProvider $MarkerProvider
  if ($markerState -eq 'present') {
    return New-ToolboxProcessSnapshot -Status 'running'
  }

  try {
    $all = @(& $ProcessProvider)
  } catch {
    $queryError = $_.Exception.Message
    try {
      $named = @(& $NameProvider)
    } catch {
      return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage ($queryError + '; ' + $_.Exception.Message)
    }
    if ($markerState -eq 'absent' -and $named.Count -eq 0) {
      return New-ToolboxProcessSnapshot -Status 'not-running' -ErrorMessage ('command-line query failed but no AutoHotkey process is running: ' + $queryError)
    }
    return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage $queryError
  }

  $ahkProcesses = @($all | Where-Object { $_ -and $_.Name -like 'AutoHotkey*.exe' })
  $matching = @($ahkProcesses | Where-Object {
      $_.CommandLine -and
      (Test-ToolboxMainScriptCommandLine -CommandLine $_.CommandLine -MainScript $MainScript)
    })
  if ($matching.Count -gt 0) {
    return New-ToolboxProcessSnapshot -Status 'running' -Processes $matching
  }

  # A readable command line that points at another checkout/relative path is not
  # this toolbox. But a missing command line could be our instance; do not turn
  # that into "absent" and start a replacement.
  $unreadable = @($ahkProcesses | Where-Object { -not $_.CommandLine })
  if ($unreadable.Count -gt 0) {
    return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage 'AutoHotkey process command line is unreadable; cannot prove it is not the toolbox'
  }
  if ($markerState -eq 'unknown') {
    return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage 'toolbox instance marker state is unknown'
  }
  return New-ToolboxProcessSnapshot -Status 'not-running'
}

function Get-ToolboxStartupErrorDialogSnapshot {
  param(
    [int[]]$ProcessIds = @(),
    [scriptblock]$ProcessProvider
  )

  if (-not $ProcessIds -or $ProcessIds.Count -eq 0) {
    return New-ToolboxProcessSnapshot -Status 'not-running'
  }
  if (-not $ProcessProvider) {
    $ProcessProvider = {
      param([int[]]$Ids)
      Get-Process -Id $Ids -ErrorAction SilentlyContinue
    }
  }

  try {
    $processes = @(& $ProcessProvider $ProcessIds)
  } catch {
    return New-ToolboxProcessSnapshot -Status 'query-failed' -ErrorMessage $_.Exception.Message
  }

  $dialogs = @($processes | Where-Object {
      $_ -and $_.MainWindowTitle -and $_.MainWindowTitle -match $script:ToolboxStartupErrorTitle -and
      ($ProcessIds -contains [int]$_.Id)
    })
  if ($dialogs.Count -gt 0) {
    return New-ToolboxProcessSnapshot -Status 'running' -Processes $dialogs
  }
  return New-ToolboxProcessSnapshot -Status 'not-running'
}

function Get-WatchdogAhkAction {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Status
  )

  switch ($Status) {
    'running' { return 'quiet' }
    'not-running' { return 'start' }
    default { return 'query-failed' }
  }
}

function Get-StartupGuardAction {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Status,
    [switch]$Force
  )

  switch ($Status) {
    'running' { if ($Force) { return 'force' } else { return 'skip' } }
    'not-running' { return 'start' }
    default { return 'query-failed' }
  }
}
function Stop-ToolboxOwnedHudProcess {
  param([Parameter(Mandatory=$true)][string]$Repo,
        [scriptblock]$ProcessProvider,
        [scriptblock]$IdentityProvider,
        [scriptblock]$Stopper)
  $expected=[IO.Path]::GetFullPath((Join-Path $Repo 'tools\ime-hud-winui\out\ImeHudWinUi.exe'))
  if(-not $ProcessProvider){$ProcessProvider={@(Get-Process -Name ImeHudWinUi -ErrorAction SilentlyContinue)}}
  if(-not $IdentityProvider){$IdentityProvider={param($Id) Get-Process -Id $Id -ErrorAction Stop}}
  if(-not $Stopper){$Stopper={param($Process) Stop-Process -InputObject $Process -Force -ErrorAction Stop}}
  $all=@();$live=$null
  try{
    $all=@(& $ProcessProvider)
    # Complete preflight before stopping anything. A different checkout is never a target.
    foreach($process in $all){
      if(-not $process.Path -or $process.Path -ine $expected){throw 'HUD ownership is unavailable or belongs to another checkout'}
      [void]$process.StartTime
    }
    foreach($process in $all){
      $ticks=$process.StartTime.ToUniversalTime().ToFileTimeUtc()
      $live=& $IdentityProvider $process.Id
      if(-not $live -or $live.HasExited -or $live.Path -ine $expected -or $live.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $ticks){throw 'HUD identity changed before restart'}
      # Holding the verified Process handle prevents a recycled PID becoming the target.
      & $Stopper $live
      if($live -is [Diagnostics.Process]){$live.Dispose()};$live=$null
    }
  }finally{
    if($live -is [Diagnostics.Process]){$live.Dispose()}
    foreach($process in $all){if($process -is [Diagnostics.Process]){$process.Dispose()}}
  }
}
