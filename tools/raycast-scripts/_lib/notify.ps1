# Lat3ncy Notify - Raycast Adapter
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {}

function Resolve-ToolboxNotifyAutoHotkey
{
  $localAppData = $env:LOCALAPPDATA
  if (-not $localAppData) {
    try { $localAppData = [Environment]::GetFolderPath('LocalApplicationData') } catch {}
  }
  if ($localAppData)
  {
    $standardV2 = Join-Path $localAppData 'Programs\AutoHotkey\v2'
    foreach ($engineName in @('AutoHotkey64.exe', 'AutoHotkey32.exe'))
    {
      $candidate = Join-Path $standardV2 $engineName
      if (Test-Path -LiteralPath $candidate -PathType Leaf)
      {
        return $candidate
      }
    }
  }

  $command = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue
  if ($command)
  {
    $executable = $command.Source
    $shimFile = [IO.Path]::ChangeExtension($executable, '.shim')
    if (Test-Path -LiteralPath $shimFile)
    {
      try {
        $shimText = Get-Content -Raw -LiteralPath $shimFile
        if ($shimText -match '(?m)^path\s*=\s*"([^"]+)"')
        {
          $shimTarget = $Matches[1]
          if ([IO.Path]::GetFileName($shimTarget) -ieq 'AutoHotkeyUX.exe')
          {
            $installRoot = Split-Path (Split-Path $shimTarget -Parent) -Parent
            $engineName = if ([Environment]::Is64BitOperatingSystem) { 'AutoHotkey64.exe' } else { 'AutoHotkey32.exe' }
            $engine = Join-Path (Join-Path $installRoot 'v2') $engineName
            if (Test-Path -LiteralPath $engine) { return $engine }
          }
          if (Test-Path -LiteralPath $shimTarget) { return $shimTarget }
        }
      } catch {}
    }
    return $executable
  }

  $programFiles = $env:ProgramFiles
  if (-not $programFiles) {
    try { $programFiles = [Environment]::GetFolderPath('ProgramFiles') } catch {}
  }
  if ($programFiles)
  {
    foreach ($candidate in @(
        (Join-Path $programFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $programFiles 'AutoHotkey\v2\AutoHotkey32.exe'),
        (Join-Path $programFiles 'AutoHotkey\v2\AutoHotkey.exe')
      ))
    {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }

  foreach ($root in @($env:USERPROFILE, $env:SCOOP) | Where-Object { $_ })
  {
    foreach ($candidate in @(
        (Join-Path $root 'scoop\apps\autohotkey\current\AutoHotkey64.exe'),
        (Join-Path $root 'scoop\apps\autohotkey\current\AutoHotkey32.exe')
      ))
    {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }

  return $null
}

function Resolve-ToolboxRepositoryRoot
{
  $searchDirs = @($PSScriptRoot, (Get-Location).Path)
  foreach ($dir in $searchDirs)
  {
    $current = $dir
    while ($current)
    {
      if (Test-Path -LiteralPath (Join-Path $current 'shared\notify\notify-cli.ahk') -PathType Leaf)
      {
        return (Resolve-Path -LiteralPath $current).Path
      }
      $parent = Split-Path $current -Parent
      if (-not $parent -or $parent -eq $current)
      {
        break
      }
      $current = $parent
    }
  }
  return $null
}

function Start-ToolboxNotifyProcess
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $FilePath,

    [string[]] $Arguments = @(),

    [string] $WorkingDirectory = ''
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  if ($WorkingDirectory)
  {
    $startInfo.WorkingDirectory = $WorkingDirectory
  }

  $escapedArgs = foreach ($arg in $Arguments)
  {
    $str = [string] $arg
    if ($str -match '[\s"]')
    {
      '"{0}"' -f ($str -replace '(\\+)"', '$1$1\"' -replace '(\\+)$', '$1$1' -replace '"', '\"')
    } else
    {
      $str
    }
  }
  $startInfo.Arguments = ($escapedArgs -join ' ')

  $process = [Diagnostics.Process]::Start($startInfo)
  if (-not $process)
  {
    return $false
  }

  $process.Dispose()
  return $true
}

function Show-ToolboxNotify
{
  param(
    [ValidateSet('state', 'success', 'info', 'error')]
    [string] $Type = 'info',

    [Parameter(Mandatory = $true)]
    [string] $Icon,

    [string] $Text = '',

    [int] $Duration = 0
  )

  try
  {
    $repositoryRoot = Resolve-ToolboxRepositoryRoot
    if (-not $repositoryRoot)
    {
      return $false
    }
    $notifyDirectory = Join-Path $repositoryRoot 'shared\notify'
    $notifyExecutable = Join-Path $notifyDirectory 'notify.exe'

    $arguments = @($Type, $Icon, $Text)
    if ($Duration -gt 0)
    {
      $arguments += [string] $Duration
    }

    if (Test-Path -LiteralPath $notifyExecutable -PathType Leaf)
    {
      return Start-ToolboxNotifyProcess -FilePath $notifyExecutable -Arguments $arguments -WorkingDirectory $notifyDirectory
    }

    $notifyScript = Join-Path $notifyDirectory 'notify-cli.ahk'
    if (-not (Test-Path -LiteralPath $notifyScript -PathType Leaf))
    {
      return $false
    }

    $autoHotkey = Resolve-ToolboxNotifyAutoHotkey
    if (-not $autoHotkey)
    {
      return $false
    }

    return Start-ToolboxNotifyProcess -FilePath $autoHotkey -Arguments (@($notifyScript) + $arguments) -WorkingDirectory $notifyDirectory
  } catch
  {
    return $false
  }
}

function Show-SystemToast
{
  param(
    [string] $Title = 'Lat3ncy Toolbox',
    [string] $Message = ''
  )

  try
  {
    $repositoryRoot = Resolve-ToolboxRepositoryRoot
    if (-not $repositoryRoot)
    {
      return $false
    }
    $toastScript = Join-Path $repositoryRoot 'shared\notify\toast.ps1'
    if (-not (Test-Path -LiteralPath $toastScript -PathType Leaf))
    {
      return $false
    }

    return Start-ToolboxNotifyProcess -FilePath "powershell.exe" -Arguments @(
      "-ExecutionPolicy", "Bypass",
      "-NoProfile",
      "-File", $toastScript,
      $Title,
      $Message
    )
  } catch
  {
    return $false
  }
}
