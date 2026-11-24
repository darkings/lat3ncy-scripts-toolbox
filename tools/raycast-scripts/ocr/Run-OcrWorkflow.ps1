# This wrapper and its Python child stay inside the caller's required Windows Job.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]{1,120}$')][string]$RequestId,
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [Parameter(Mandatory=$true)][uint32]$BaselineSequence,
    [string]$ImageFile=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OcrHost.ps1')
. (Join-Path $PSScriptRoot '..\..\ToolboxControls.ps1')
if(-not(Test-ToolboxModuleEnabled -Module ocr -RepoRoot (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent))){
    [IO.File]::WriteAllText($ResultFile,"version=1`nrequest_id=$RequestId`nstatus=cancelled`nerror_kind=none`ntext=",[Text.UTF8Encoding]::new($false))
    exit 0
}
try {
    $spec=Get-OcrLaunchSpec -ModuleDirectory $PSScriptRoot
    if(-not $spec -or $spec.Kind -ne 'base-host'){throw 'Matching OCR base environment is required'}
    $python=Join-Path (Split-Path $spec.Python -Parent) 'python.exe'
    if(-not (Test-Path -LiteralPath $python -PathType Leaf)){throw 'Matching console interpreter is missing'}
    $arguments=@('-I','-S',$spec.Script,'--workflow','--request-id',$RequestId,
        '--result-file',$ResultFile,'--baseline-sequence',"$BaselineSequence")
    if($ImageFile){$arguments+=@('--image-file',$ImageFile)}
    & $python @arguments
    exit $LASTEXITCODE
} catch {
    # Deliver a fixed error protocol; no private exception/output is exported.
    [IO.File]::WriteAllText($ResultFile,"version=1`nrequest_id=$RequestId`nstatus=error`nerror_kind=host`ntext=",[Text.UTF8Encoding]::new($false))
    exit 1
}
