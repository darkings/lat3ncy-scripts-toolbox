# Background file observer. No capture input, toast, task or device operations.
param(
    [Parameter(Mandatory=$true)][ValidateSet('Screenshot','Record')][string]$Mode,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$SessionId
)
$ErrorActionPreference='Stop'
trap {
    if($repo -and $session){try{Set-ToolboxCaptureResult $repo $Mode $SessionId failed internal}catch{}}
    exit 0
}
. (Join-Path $PSScriptRoot 'CaptureSupport.ps1')
. (Join-Path $PSScriptRoot 'CaptureRuntime.ps1')
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$session=Read-ToolboxCaptureSession $repo $Mode $SessionId
if(-not $session){exit 0}
$options=$session.options
if(-not $options.CopyToClipboard -and -not $options.ExtraDirectory){exit 0}
$since=[DateTime]::Parse($session.startedUtc).ToUniversalTime();$deadline=[DateTime]::Parse($session.deadlineUtc).ToUniversalTime()
$isCurrent={Test-ToolboxCaptureSession $repo $Mode $SessionId}.GetNewClosure()
if($Mode -eq 'Screenshot'){
    $pictures=[Environment]::GetFolderPath('MyPictures')
    $directory=Get-ToolboxKnownFolderPath -FolderId 'B7BEDE81-DF94-4682-A7D8-57A52620B86F' -FallbackPath (Join-Path $pictures 'Screenshots')
    $extensions=@('.png','.jpg','.jpeg')
}else{
    $videos=[Environment]::GetFolderPath('MyVideos')
    $directory=Get-ToolboxKnownFolderPath -FolderId 'EDC0FE71-98D8-4F4A-B920-C8DC90DB7AE9' -FallbackPath (Join-Path $videos 'Captures')
    $extensions=@('.mp4','.mov','.mkv')
}
$file=Wait-ToolboxCaptureFile $directory $extensions $since $deadline $isCurrent
if(-not $file){
    if([DateTime]::UtcNow -ge $deadline){Set-ToolboxCaptureResult $repo $Mode $SessionId timeout no_file}
    else{Set-ToolboxCaptureResult $repo $Mode $SessionId stopped module_disabled}
    exit 0
}
Set-ToolboxCaptureResult $repo $Mode $SessionId processing none pending pending
if(-not (Wait-ToolboxCaptureStable $file.FullName $deadline $isCurrent)){
    if([DateTime]::UtcNow -ge $deadline){Set-ToolboxCaptureResult $repo $Mode $SessionId timeout file_not_ready}
    else{Set-ToolboxCaptureResult $repo $Mode $SessionId stopped module_disabled}
    exit 0
}
$outcome=Complete-ToolboxCapture $file.FullName $options $repo $Mode $isCurrent
Set-ToolboxCaptureResult $repo $Mode $SessionId $outcome.state none $outcome.clipboard $outcome.extra_copy
exit 0
