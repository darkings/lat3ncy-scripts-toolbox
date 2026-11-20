# Validates test-out, deploys only HUD artifacts, and reloads this checkout's AHK.
# Build/test first: powershell -File ahk/tests/run-tests.ps1 -BuildImeHud
[CmdletBinding(DefaultParameterSetName='Deploy')]
param(
    [Parameter(ParameterSetName='Deploy')][switch]$PlanOnly,
    [Parameter(ParameterSetName='Deploy')][switch]$ForceReload,
    [Parameter(Mandatory=$true,ParameterSetName='Rollback')][string]$RollbackRelease
)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$project=Join-Path $repo 'tools\ime-hud-winui'
$source=Join-Path $project 'test-out';$target=Join-Path $project 'out'
. (Join-Path $PSScriptRoot 'Deployment.Core.ps1')
. (Join-Path $PSScriptRoot 'Deployment.Runtime.ps1')
. (Join-Path $project 'BuildSupport.ps1')
$lease=[Threading.Mutex]::new($false,((Get-ToolboxInstanceName (Join-Path $repo 'ahk\main.ahk'))+'-Deployment'))
$owned=$false;$release=''
try {
    try {$owned=$lease.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
    if(-not $owned){throw 'Another deployment is running for this checkout'}
    if($RollbackRelease){
        $release=[IO.Path]::GetFullPath($RollbackRelease)
        # Validate before stopping anything. Restore performs the same validation.
        $manifest=Get-Content (Join-Path $release 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if($manifest.TargetRoot -ine $target -or $manifest.Version -ne 1){throw 'Rollback belongs to another target/version'}
        Assert-ToolboxReleaseBackup $release $target
        # Back up current bytes too, so a failed rollback can itself be undone.
        $reverse=@(foreach($entry in $manifest.Files){
            $path=Join-ToolboxReleasePath $target $entry.Relative
            $exists=Test-Path -LiteralPath $path -PathType Leaf
            [pscustomobject]@{Relative=$entry.Relative;Existed=$exists;BeforeHash=$(if($exists){(Get-FileHash $path).Hash}else{''});AfterHash='rollback'}
        })
        $safety=Join-Path $repo ('.tmp\releases\'+[guid]::NewGuid().ToString('N'))
        $null=New-ToolboxRelease $source $target $safety $reverse 'before-rollback'
        try {
            Stop-ToolboxReleaseRuntime $repo
            Restore-ToolboxRelease $release $target
            Start-ToolboxReleaseRuntime $repo
            $health=Test-ToolboxReleaseRuntime $repo
        } catch {
            Stop-ToolboxReleaseRuntime $repo
            Restore-ToolboxRelease $safety $target
            Start-ToolboxReleaseRuntime $repo
            $null=Test-ToolboxReleaseRuntime $repo
            throw
        }
        [pscustomobject]@{Action='rolled-back';Release=$release;SafetyBackup=$safety;Health=$health} | ConvertTo-Json -Depth 5
        return
    }
    $stamp=Get-ImeHudSourceHash $project
    $stampFile=Join-Path $source '.source-stamp'
    if(-not(Test-Path $stampFile) -or [IO.File]::ReadAllText($stampFile).Trim() -ne $stamp){throw 'Missing/stale test-out; run ahk/tests/run-tests.ps1 -BuildImeHud first'}
    Invoke-ToolboxReleaseProcess (Join-Path $source 'ImeHudWinUi.exe') @('--self-test')
    $changes=@(Get-ToolboxReleaseChanges $source $target)
    if($PlanOnly){[pscustomobject]@{Action='plan';SourceStamp=$stamp;ChangedFiles=@($changes | ForEach-Object {$_.Relative})} | ConvertTo-Json -Depth 5;return}
    if(-not $changes.Count -and -not $ForceReload){
        $health=Test-ToolboxReleaseRuntime $repo
        [pscustomobject]@{Action='unchanged';SourceStamp=$stamp;Health=$health} | ConvertTo-Json -Depth 5;return
    }
    $release=Join-Path $repo ('.tmp\releases\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $manifest=New-ToolboxRelease $source $target $release $changes $stamp
    $health=Invoke-ToolboxReleaseTransaction -ReleaseDirectory $release -ExpectedTarget $target `
        -StopRuntime {Stop-ToolboxReleaseRuntime $repo} -StartRuntime {Start-ToolboxReleaseRuntime $repo} `
        -ValidateInstalled {Invoke-ToolboxReleaseProcess (Join-Path $target 'ImeHudWinUi.exe') @('--self-test')} `
        -CheckRuntime {Test-ToolboxReleaseRuntime $repo}
    $manifest.State='healthy'
    $manifest | Add-Member -NotePropertyName Health -NotePropertyValue $health
    $manifest | Add-Member -NotePropertyName HostPath -NotePropertyValue (Get-Process -Id $PID).Path
    Save-ToolboxReleaseManifest $release $manifest
    [pscustomobject]@{Action='deployed';Release=$release;ChangedFiles=@($changes | ForEach-Object {$_.Relative});SourceStamp=$stamp;Health=$health} | ConvertTo-Json -Depth 5
} finally {if($owned){$lease.ReleaseMutex()};$lease.Dispose()}
