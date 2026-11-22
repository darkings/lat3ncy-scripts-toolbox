# File completion helpers; dot-sourcing never captures or touches the clipboard.
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

function Find-ToolboxCaptureFile {
    param([string]$Directory,[string[]]$Extensions,[DateTime]$Since)
    # A cancellation cannot reselect a recent pre-existing capture.
    return (Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() -and $_.LastWriteTimeUtc -ge $Since -and $_.CreationTimeUtc -ge $Since.AddMilliseconds(-250) } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
}
function Wait-ToolboxCaptureFile {
    param([string]$Directory,[string[]]$Extensions,[DateTime]$Since,[DateTime]$Deadline,[scriptblock]$IsCurrent)
    if(-not (Test-Path -LiteralPath $Directory -PathType Container)){return $null}
    $watcher=$null;$created='ToolboxCaptureCreated-'+[guid]::NewGuid().ToString('N');$renamed='ToolboxCaptureRenamed-'+[guid]::NewGuid().ToString('N')
    try{
        $watcher=[IO.FileSystemWatcher]::new($Directory);$watcher.Filter='*.*';$watcher.IncludeSubdirectories=$false
        $watcher.NotifyFilter=[IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite
        Register-ObjectEvent $watcher Created -SourceIdentifier $created | Out-Null
        Register-ObjectEvent $watcher Renamed -SourceIdentifier $renamed | Out-Null
        $watcher.EnableRaisingEvents=$true
        while([DateTime]::UtcNow -lt $Deadline){
            if(-not (& $IsCurrent)){return $null}
            $file=Find-ToolboxCaptureFile $Directory $Extensions $Since
            if($file){return $file}
            $event=Wait-Event -SourceIdentifier $created -Timeout 1
            if(-not $event){$event=Get-Event -SourceIdentifier $renamed -ErrorAction SilentlyContinue | Select-Object -First 1}
            if($event){Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue}
        }
    }finally{
        Unregister-Event -SourceIdentifier $created -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $renamed -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $created -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $renamed -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        if($watcher){$watcher.EnableRaisingEvents=$false;$watcher.Dispose()}
    }
    return $null
}
function Wait-ToolboxCaptureStable {
    param([string]$Path,[DateTime]$Deadline,[scriptblock]$IsCurrent,[int]$PollMilliseconds=500)
    $previousLength=-1;$previousWrite=[DateTime]::MinValue;$unchanged=0
    while([DateTime]::UtcNow -lt $Deadline){
        if(-not (& $IsCurrent)){return $false}
        try{
            $file=Get-Item -LiteralPath $Path -ErrorAction Stop
            # A recording can pause without being finished; require writer release.
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
            try{$length=$stream.Length}finally{$stream.Dispose()}
            if($length -gt 0 -and $length -eq $previousLength -and $file.LastWriteTimeUtc -eq $previousWrite){$unchanged++}else{$unchanged=0}
            $previousLength=$length;$previousWrite=$file.LastWriteTimeUtc
            if($unchanged -ge 3){return $true}
        }catch{$unchanged=0}
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    return $false
}
function Copy-ToolboxCaptureExtra {
    param([string]$Source,[string]$Directory,[string]$Repo,[scriptblock]$IsCurrent)
    if(-not $Directory -or -not (& $IsCurrent)){return $null}
    $directoryPath=[Environment]::ExpandEnvironmentVariables($Directory)
    if(-not [IO.Path]::IsPathRooted($directoryPath)){$directoryPath=Join-Path $Repo $directoryPath}
    $directoryPath=[IO.Path]::GetFullPath($directoryPath)
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Source)).TrimEnd('\') -ieq $directoryPath.TrimEnd('\')){return $Source}
    [void][IO.Directory]::CreateDirectory($directoryPath)
    $stem=[IO.Path]::GetFileNameWithoutExtension($Source);$extension=[IO.Path]::GetExtension($Source)
    $destination=Join-Path $directoryPath ($stem+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+$extension)
    $temporary=$destination+'.tmp';$inputStream=$null;$outputStream=$null
    try{
        $inputStream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $outputStream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $inputStream.CopyTo($outputStream);$outputStream.Flush($true);$outputStream.Dispose();$outputStream=$null
        $inputStream.Dispose();$inputStream=$null
        return (Invoke-ToolboxCaptureCommit $Repo {
            if(-not (& $IsCurrent)){return $null}
            [IO.File]::Move($temporary,$destination)
            return $destination
        })
    }finally{
        if($outputStream){$outputStream.Dispose()};if($inputStream){$inputStream.Dispose()}
        if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
    }
}
function Complete-ToolboxCapture {
    param([string]$Path,$Options,[string]$Repo,[string]$Mode,[scriptblock]$IsCurrent)
    if(-not (& $IsCurrent)){return}
    # Copy and clipboard are independent: a bad optional directory cannot prevent paste.
    try{[void](Copy-ToolboxCaptureExtra $Path $Options.ExtraDirectory $Repo $IsCurrent)}catch{}
    if($Options.CopyToClipboard){try{Invoke-ToolboxCaptureCommit $Repo {
        if(& $IsCurrent){Copy-CaptureFileToClipboard -Path $Path -Mode $Mode}
    }}catch{}}
}
