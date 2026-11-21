# Ensure-ToolboxRunning.ps1
# Watchdog entry for TWO targets:
#   1) ahk/main.ahk                       - start via Start-Toolbox.ps1
#   2) tools/power-policy/PowerPolicy.ps1 - start the PowerPolicy scheduled task
# Called by the Lat3ncyToolbox-Watchdog scheduled task at logon and every 5 minutes.
# Only starts; never kills an already running instance.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI,
# and non-ASCII here would break parsing silently (bit us twice).

param(
  [int]$KeepLogLines = 300
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mainScript = Join-Path $repoRoot 'ahk\main.ahk'
$startScript = Join-Path $repoRoot 'tools\startup\Start-Toolbox.ps1'
$powerScript = Join-Path $repoRoot 'tools\power-policy\PowerPolicy.ps1'
$powerTask = 'PowerPolicy'
$logDirectory = Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox'
$logFile = Join-Path $logDirectory 'startup.log'

. (Join-Path $PSScriptRoot 'ToolboxProcess.ps1')

function Write-StartupLog {
  param([string]$Message)
  try {
    if (!(Test-Path -LiteralPath $logDirectory)) {
      $null = New-Item -ItemType Directory -Path $logDirectory -Force
    }
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $KeepLogLines) {
      $lines[-$KeepLogLines..-1] | Set-Content -LiteralPath $logFile -Encoding UTF8
    }
  } catch {
  }
}

# ---------------------------------------------------------------- target 1: AHK

function Get-ToolboxAhkSnapshot {
  return Get-ToolboxProcessSnapshot -MainScript $mainScript
}

# ---------------------------------------------------- target 2: power policy

function Get-PowerPolicySnapshot {
  return Get-ToolboxPowerPolicySnapshot -PowerScript $powerScript
}

# ------------------------------------------------------------------- main

# A crashed deployer releases its kernel lease automatically; no stale flag.
if((Get-ToolboxDeploymentState $mainScript) -ne 'idle'){exit 0}
$failures = @()

# --- target 1
if (-not (Test-Path -LiteralPath $mainScript)) {
  Write-StartupLog "watchdog: main.ahk missing, skipped ($mainScript)"
  $failures += 'ahk-missing'
} else {
  $snapshot = Get-ToolboxAhkSnapshot
  $action = Get-WatchdogAhkAction -Status $snapshot.Status
  switch ($action) {
    'query-failed' {
      Write-StartupLog ("watchdog: process query failed; not starting to avoid a duplicate: " + $snapshot.ErrorMessage)
      $failures += 'ahk-query-failed'
    }
    'quiet' {
      # Normal case: stay quiet so the log does not grow every 5 minutes.
    }
    'start' {
      Write-StartupLog "watchdog: main.ahk not running, starting toolbox"
      try {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $startScript *> $null
      } catch {
        Write-StartupLog ("watchdog: Start-Toolbox failed: " + $_.Exception.Message)
        $failures += 'ahk-start-failed'
      }

      $started = $false
      $queryFailed = $false
      for ($i = 0; $i -lt 10; $i++) {
        $after = Get-ToolboxAhkSnapshot
        if ($after.Status -eq 'running') {
          Write-StartupLog ("watchdog: ahk started - PID " + ($after.ProcessIds -join ', '))
          $started = $true
          break
        }
        $queryFailed = $after.Status -eq 'query-failed'
        Start-Sleep -Seconds 1
      }
      if (-not $started) {
        if ($queryFailed) {
          Write-StartupLog "watchdog: process query kept failing after start; not retrying"
        } else {
          Write-StartupLog "watchdog: still no main.ahk after start (see the startup: line above)"
        }
        $failures += 'ahk-not-up'
      }
    }
  }
}

# --- target 2
if (-not (Test-Path -LiteralPath $powerScript)) {
  Write-StartupLog "watchdog: PowerPolicy.ps1 missing, skipped ($powerScript)"
} else {
  $powerSnapshot = Get-PowerPolicySnapshot
  if ($powerSnapshot.Status -eq 'query-failed') {
    Write-StartupLog ("watchdog: power policy query failed; not starting to avoid a duplicate: " + $powerSnapshot.ErrorMessage)
    $failures += 'power-query-failed'
  } elseif ($powerSnapshot.Status -eq 'running') {
    # Normal case: quiet.
  } elseif ($powerSnapshot.Status -eq 'outdated') {
    Write-StartupLog 'watchdog: power policy is running older sources/config; reload required, not starting a duplicate'
    $failures += 'power-outdated'
  } else {
    $task = Get-ScheduledTask -TaskName $powerTask -ErrorAction SilentlyContinue
    if (-not $task) {
      Write-StartupLog "watchdog: task '$powerTask' not registered, skipped (run tools\power-policy\Install-PowerPolicy.ps1)"
    } else {
      Write-StartupLog "watchdog: power policy resident not running, starting task '$powerTask'"
      try {
        Start-ScheduledTask -TaskName $powerTask -ErrorAction Stop
      } catch {
        Write-StartupLog ("watchdog: Start-ScheduledTask '$powerTask' failed: " + $_.Exception.Message)
        $failures += 'power-start-failed'
      }

      $powerUp = $false
      $powerQueryFailed = $false
      for ($i = 0; $i -lt 15; $i++) {
        $afterPower = Get-PowerPolicySnapshot
        if ($afterPower.Status -eq 'running') {
          Write-StartupLog ("watchdog: power policy started - PID " + ($afterPower.ProcessIds -join ', '))
          $powerUp = $true
          break
        }
        $powerQueryFailed = $afterPower.Status -eq 'query-failed'
        Start-Sleep -Seconds 1
      }
      if (-not $powerUp) {
        if ($powerQueryFailed) {
          Write-StartupLog "watchdog: power policy query kept failing after start; not retrying"
        } else {
          Write-StartupLog "watchdog: power policy still not running after start"
        }
        $failures += 'power-not-up'
      }
    }
  }
}

if ($failures.Count -gt 0) {
  Write-StartupLog ("watchdog: exit with failures - " + ($failures -join ', '))
  exit 1
}
exit 0
