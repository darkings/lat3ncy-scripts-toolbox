# 系统捕获落盘监视器：等 Windows 写出文件后，复制到剪贴板并报告路径。
# 由 screenshot.ps1 / record-screen.ps1 隐藏启动；screenshot-ocr.ps1 禁止调用。
param(
  # Screenshot：等 ScreenClippingHost 结束再扫截图目录。
  # Record：在捕获目录上等新视频，不依赖 SnippingTool 退出。
  [Parameter(Mandatory = $true)]
  [ValidateSet('Screenshot', 'Record')]
  [string] $Mode,

  # 入口脚本记下的本地时间，用来排除这次框选之前的旧文件。
  [string] $StartedAt = ''
)

$ErrorActionPreference = 'Stop'

# 后台进程，任何异常都静默退出，避免弹窗或污染 Raycast 输出。
trap {
  exit 0
}

. (Join-Path (Split-Path $PSScriptRoot -Parent) '_lib\notify.ps1')

# 把入口传来的时间解析成本地 DateTime；解析失败就用“现在往前 2 秒”。
function Convert-WatcherStartTime
{
  param([string] $Value)

  if ($Value)
  {
    try
    {
      return [datetime]::ParseExact(
        $Value,
        'yyyy-MM-ddTHH:mm:ss.fffffff',
        [cultureinfo]::InvariantCulture
      )
    } catch {}
  }

  return (Get-Date).AddSeconds(-2)
}

# 用 Known Folder 解析系统截图/捕获目录，避免写死中文路径或 OneDrive 盘符。
function Get-ToolboxKnownFolderPath
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $FolderId,

    [Parameter(Mandatory = $true)]
    [string] $FallbackPath
  )

  try
  {
    if (-not ('Lat3ncyKnownFolder' -as [type]))
    {
      Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Lat3ncyKnownFolder {
    [DllImport("shell32.dll")]
    public static extern int SHGetKnownFolderPath(
        ref Guid rfid,
        uint dwFlags,
        IntPtr hToken,
        out IntPtr ppszPath);
}
"@
    }

    $guid = [Guid]$FolderId
    $buffer = [IntPtr]::Zero
    $hr = [Lat3ncyKnownFolder]::SHGetKnownFolderPath(
      [ref]$guid,
      0,
      [IntPtr]::Zero,
      [ref]$buffer
    )
    if ($hr -eq 0 -and $buffer -ne [IntPtr]::Zero)
    {
      $resolved = [Runtime.InteropServices.Marshal]::PtrToStringUni($buffer)
      [Runtime.InteropServices.Marshal]::FreeCoTaskMem($buffer)
      if ($resolved)
      {
        return $resolved
      }
    }
  } catch {}

  return $FallbackPath
}

# 在目录里找这次开始之后写入的最新匹配文件。
function Find-LatestCaptureFile
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $Directory,

    [Parameter(Mandatory = $true)]
    [string[]] $Extensions,

    [Parameter(Mandatory = $true)]
    [datetime] $Since
  )

  $threshold = $Since.AddSeconds(-1)
  Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
    Where-Object {
      $extension = $_.Extension.ToLowerInvariant()
      ($Extensions -contains $extension) -and ($_.LastWriteTime -ge $threshold)
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

# 等文件长度连续三次相同，避免录屏刚创建或仍在写入时就去报路径。
function Wait-CaptureFileStable
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $Path
  )

  $previousLength = -1
  $unchanged = 0
  for ($i = 0; $i -lt 40; $i++)
  {
    try
    {
      $length = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
      if ($length -gt 0 -and $length -eq $previousLength)
      {
        $unchanged++
        if ($unchanged -ge 3)
        {
          return $true
        }
      } else
      {
        $unchanged = 0
        $previousLength = $length
      }
    } catch {}
    Start-Sleep -Milliseconds 500
  }

  return $false
}

# 等指定进程出现，可选再等它退出。超时后仍返回，交给后续扫目录。
function Wait-CaptureProcess
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $ProcessName,

    [Parameter(Mandatory = $true)]
    [int] $AppearTimeoutMs,

    [int] $ExitTimeoutMs = 0,

    [switch] $WaitExit
  )

  $appearDeadline = [datetime]::UtcNow.AddMilliseconds($AppearTimeoutMs)
  $seen = $false
  while ([datetime]::UtcNow -lt $appearDeadline)
  {
    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    {
      $seen = $true
      break
    }
    Start-Sleep -Milliseconds 150
  }

  if (-not $WaitExit)
  {
    return $seen
  }
  if (-not $seen)
  {
    return $false
  }

  $exitDeadline = [datetime]::UtcNow.AddMilliseconds($ExitTimeoutMs)
  while ([datetime]::UtcNow -lt $exitDeadline)
  {
    if (-not (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue))
    {
      return $true
    }
    Start-Sleep -Milliseconds 200
  }

  return $true
}

# 截图工具开了自动保存后，系统不一定再往剪贴板写内容。
# 文件稳定落盘后，把这次捕获重新放进剪贴板：截图放图片，录屏放文件。
function Copy-CaptureFileToClipboard
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $Path,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Screenshot', 'Record')]
    [string] $Mode
  )

  if ($Mode -eq 'Record')
  {
    # 视频不能当图片粘贴；按文件放入剪贴板，资源管理器/聊天窗口可直接粘贴该文件。
    Set-Clipboard -LiteralPath $Path
    return
  }

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  # 先读进内存，避免 Image.FromFile 长时间锁住刚保存的 png。
  $bytes = [IO.File]::ReadAllBytes($Path)
  $sourceStream = [IO.MemoryStream]::new($bytes)
  $image = $null
  $pngStream = $null
  try
  {
    $image = [Drawing.Image]::FromStream($sourceStream)
    $pngStream = [IO.MemoryStream]::new()
    $image.Save($pngStream, [Drawing.Imaging.ImageFormat]::Png)
    $pngStream.Position = 0

    # CF_BITMAP 兼容 Word/QQ；PNG 格式保留透明通道，给支持它的应用用。
    $data = New-Object Windows.Forms.DataObject
    $data.SetImage($image)
    $data.SetData('PNG', $false, $pngStream)
    [Windows.Forms.Clipboard]::SetDataObject($data, $true)
    # copy=true 仍是异步 OLE 拷贝；立刻 Dispose/退出时 PNG 流可能还没写完。
    Start-Sleep -Milliseconds 150
  }
  finally
  {
    if ($image)
    {
      $image.Dispose()
    }
    if ($pngStream)
    {
      $pngStream.Dispose()
    }
    $sourceStream.Dispose()
  }
}

# 录屏会话可能很长，用文件系统事件等待新文件；OneDrive 偶发丢事件时再定时补扫。
function Wait-NewCaptureFile
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $Directory,

    [Parameter(Mandatory = $true)]
    [string[]] $Extensions,

    [Parameter(Mandatory = $true)]
    [datetime] $Since,

    [Parameter(Mandatory = $true)]
    [int] $TimeoutSeconds
  )

  $existing = Find-LatestCaptureFile -Directory $Directory -Extensions $Extensions -Since $Since
  if ($existing)
  {
    return $existing
  }

  $watcher = $null
  $createdId = 'Lat3ncyCaptureCreated-' + [guid]::NewGuid().ToString('N')
  $renamedId = 'Lat3ncyCaptureRenamed-' + [guid]::NewGuid().ToString('N')
  try
  {
    $watcher = [IO.FileSystemWatcher]::new($Directory)
    $watcher.Filter = '*.*'
    $watcher.IncludeSubdirectories = $false
    $watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite
    $watcher.EnableRaisingEvents = $true
    Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier $createdId | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier $renamedId | Out-Null

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $nextScan = [datetime]::UtcNow
    while ([datetime]::UtcNow -lt $deadline)
    {
      $event = Wait-Event -SourceIdentifier $createdId -Timeout 1
      if (-not $event)
      {
        $event = Wait-Event -SourceIdentifier $renamedId -Timeout 0
      }
      if ($event)
      {
        Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
      }

      if ([datetime]::UtcNow -ge $nextScan)
      {
        $found = Find-LatestCaptureFile -Directory $Directory -Extensions $Extensions -Since $Since
        if ($found)
        {
          return $found
        }
        $nextScan = [datetime]::UtcNow.AddSeconds(5)
      }
    }
  } finally
  {
    Unregister-Event -SourceIdentifier $createdId -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $renamedId -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $createdId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $renamedId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    if ($watcher)
    {
      $watcher.EnableRaisingEvents = $false
      $watcher.Dispose()
    }
  }

  return $null
}

$since = Convert-WatcherStartTime -Value $StartedAt
$pictures = [Environment]::GetFolderPath('MyPictures')
$videos = [Environment]::GetFolderPath('MyVideos')

if ($Mode -eq 'Screenshot')
{
  $directory = Get-ToolboxKnownFolderPath -FolderId 'B7BEDE81-DF94-4682-A7D8-57A52620B86F' -FallbackPath (Join-Path $pictures 'Screenshots')
  $extensions = @('.png', '.jpg', '.jpeg')
  $title = '✓ 截图已保存'
  if (-not (Test-Path -LiteralPath $directory -PathType Container))
  {
    exit 0
  }

  # 框选对应 ScreenClippingHost：出现后再等它退出，取消时目录里不会有新文件。
  [void](Wait-CaptureProcess -ProcessName 'ScreenClippingHost' -AppearTimeoutMs 5000 -ExitTimeoutMs 180000 -WaitExit)
  Start-Sleep -Milliseconds 700
  $file = Find-LatestCaptureFile -Directory $directory -Extensions $extensions -Since $since
} else
{
  $directory = Get-ToolboxKnownFolderPath -FolderId 'EDC0FE71-98D8-4F4A-B920-C8DC90DB7AE9' -FallbackPath (Join-Path $videos 'Captures')
  $extensions = @('.mp4', '.mov', '.mkv')
  $title = '✓ 录屏已保存'
  if (-not (Test-Path -LiteralPath $directory -PathType Container))
  {
    exit 0
  }

  # SnippingTool 常驻时不能靠进程退出判断；最多等 30 分钟，取消则超时静默。
  $file = Wait-NewCaptureFile -Directory $directory -Extensions $extensions -Since $since -TimeoutSeconds 1800
}

if (-not $file)
{
  exit 0
}

if (-not (Wait-CaptureFileStable -Path $file.FullName))
{
  exit 0
}

# 保存位置有文件不等于剪贴板有内容；复制失败也不阻断路径通知。
try
{
  Copy-CaptureFileToClipboard -Path $file.FullName -Mode $Mode
}
catch {}

Show-SystemToast -Title $title -Message $file.FullName | Out-Null
exit 0
