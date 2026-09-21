# Lat3ncy Notify - Raycast Adapter
# Raycast 生产通知只走系统 Toast；旧 HUD CLI / Show-ToolboxNotify 已删除。
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {}

function Resolve-ToolboxRepositoryRoot
{
  $searchDirs = @($PSScriptRoot, (Get-Location).Path)
  foreach ($dir in $searchDirs)
  {
    $current = $dir
    while ($current)
    {
      if (Test-Path -LiteralPath (Join-Path $current 'shared\notify\toast.ps1') -PathType Leaf)
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
