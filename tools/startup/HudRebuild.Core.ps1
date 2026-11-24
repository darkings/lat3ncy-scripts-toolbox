# Composite HUD/anchor release. Loading this file performs no runtime operations.
. (Join-Path $PSScriptRoot 'Deployment.Core.ps1')
. (Join-Path $PSScriptRoot 'ToolboxProcess.ps1')

function Assert-ToolboxHudReleasePath {
    param([string]$Relative)
    # Only these two artifact locations participate. Never release audio/configs.
    $path=$Relative.Replace('/','\')
    if($path -ceq 'shared\notify\anchor-locator.exe'){return}
    $prefix='tools\ime-hud-winui\out\'
    if(-not $path.StartsWith($prefix,[StringComparison]::Ordinal) -or
        $path.Contains('..') -or $path.Contains(':') -or $path.EndsWith('\') -or
        $path -match '(?i)\.log(?:\.|$)'){throw 'Unexpected HUD release artifact'}
}

function Get-ToolboxHudBundleFiles {
    param([string]$Bundle)
    $root=[IO.Path]::GetFullPath($Bundle).TrimEnd('\')
    $null=Join-ToolboxReleasePath $root 'probe'
    foreach($entry in Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop){
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'HUD bundle contains a reparse point'}
        if($entry.PSIsContainer){continue}
        # Native self-tests may create/append their own log beside the exe.
        # Logs remain diagnostic output, never a release artifact.
        if($entry.Name -match '(?i)\.log(?:\.|$)'){continue}
        $relative=$entry.FullName.Substring($root.Length).TrimStart('\')
        Assert-ToolboxHudReleasePath $relative
        [pscustomobject]@{Relative=$relative;Sha256=(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash}
    }
}

function Assert-ToolboxHudCandidate {
    param([string]$Repo,[string]$Work)
    $candidate=Get-Content -LiteralPath (Join-Path $Work 'candidate.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($candidate.Version -ne 1 -or $candidate.Repo -ine [IO.Path]::GetFullPath($Repo)){
        throw 'HUD candidate belongs to another checkout/version'
    }
    $project=Join-Path $Repo 'tools\ime-hud-winui'
    if($candidate.HudSource -cne (Get-ImeHudSourceHash $project) -or
        $candidate.AnchorSource -cne (Get-FileHash -LiteralPath (Join-Path $Repo 'shared\notify\AnchorLocator.cs') -Algorithm SHA256).Hash){
        throw 'HUD/anchor source changed after build'
    }
    $bundle=Join-Path $Work 'bundle'
    $actual=@(Get-ToolboxHudBundleFiles $bundle)
    $expected=@{}
    foreach($entry in $candidate.Files){
        Assert-ToolboxHudReleasePath $entry.Relative
        if($expected.ContainsKey($entry.Relative)){throw 'Duplicate HUD artifact'}
        $expected[$entry.Relative]=[string]$entry.Sha256
    }
    foreach($required in @('shared\notify\anchor-locator.exe','tools\ime-hud-winui\out\ImeHudWinUi.exe',
        'tools\ime-hud-winui\out\ImeHudWinUi.dll','tools\ime-hud-winui\out\.source-stamp')){
        if(-not $expected.ContainsKey($required)){throw 'Incomplete HUD candidate'}
    }
    if($actual.Count -ne $expected.Count){throw 'HUD candidate file set changed'}
    foreach($entry in $actual){
        if(-not $expected.ContainsKey($entry.Relative) -or $expected[$entry.Relative] -cne $entry.Sha256){throw 'HUD candidate artifact changed'}
    }
    if([IO.File]::ReadAllText((Join-Path $bundle 'tools\ime-hud-winui\out\.source-stamp')).Trim() -cne $candidate.HudSource){
        throw 'HUD candidate stamp mismatch'
    }
    return $candidate
}

function Assert-ToolboxHudInstalled {
    param([string]$Repo,$Candidate)
    foreach($entry in $Candidate.Files){
        Assert-ToolboxHudReleasePath $entry.Relative
        $path=Join-ToolboxReleasePath $Repo $entry.Relative
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $entry.Sha256){throw 'HUD installed artifact mismatch'}
    }
}

function Invoke-ToolboxHudRebuild {
    param([string]$Repo,[scriptblock]$BuildCandidate,[scriptblock]$TestCandidate,
        [scriptblock]$StopRuntime,[scriptblock]$StartRuntime,[scriptblock]$CheckRuntime,
        [scriptblock]$TestInstalled,[switch]$PlanOnly)
    $repoPath=[IO.Path]::GetFullPath($Repo)
    $lease=[Threading.Mutex]::new($false,((Get-ToolboxInstanceName (Join-Path $repoPath 'ahk\main.ahk'))+'-Deployment'))
    $owned=$false
    try {
        try{$owned=$lease.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'Another deployment is running for this checkout'}
        $work=Join-Path $repoPath ('.tmp\hud-rebuilds\'+[guid]::NewGuid().ToString('N'))
        $null=Join-ToolboxReleasePath $repoPath ('.tmp\hud-rebuilds\probe')
        [void][IO.Directory]::CreateDirectory($work)
        # All builds/tests happen while the current residents remain running.
        & $BuildCandidate $work | Out-Null
        $candidate=Assert-ToolboxHudCandidate $repoPath $work
        & $TestCandidate $work | Out-Null
        $null=Assert-ToolboxHudCandidate $repoPath $work
        $bundle=Join-Path $work 'bundle'
        $changes=@(Get-ToolboxReleaseChanges $bundle $repoPath)
        if($PlanOnly){return [pscustomobject]@{Action='plan';Work=$work;ChangedFiles=@($changes | ForEach-Object {$_.Relative})}}
        $release=Join-Path $repoPath ('.tmp\releases\hud-'+[guid]::NewGuid().ToString('N'))
        $null=Join-ToolboxReleasePath $repoPath ($release.Substring($repoPath.TrimEnd('\').Length).TrimStart('\')+'\probe')
        $manifest=New-ToolboxRelease $bundle $repoPath $release $changes ($candidate.HudSource+':'+$candidate.AnchorSource)
        try {
            $health=Invoke-ToolboxReleaseTransaction -ReleaseDirectory $release -ExpectedTarget $repoPath `
                -StopRuntime $StopRuntime -StartRuntime $StartRuntime -CheckRuntime $CheckRuntime `
                -ValidatePrepared {$null=Assert-ToolboxHudCandidate $repoPath $work} `
                -ValidateInstalled {Assert-ToolboxHudInstalled $repoPath $candidate; & $TestInstalled}
        } catch {
            $failure=$_
            $manifest.State='failed'
            Save-ToolboxReleaseManifest $release $manifest
            throw "HUD deployment failed: $($failure.Exception.Message). Release: $release"
        }
        $manifest.State='healthy'
        $manifest | Add-Member -NotePropertyName Health -NotePropertyValue $health
        Save-ToolboxReleaseManifest $release $manifest
        return [pscustomobject]@{Action='deployed';Release=$release;Work=$work;ChangedFiles=@($changes | ForEach-Object {$_.Relative});Health=$health}
    } finally {if($owned){$lease.ReleaseMutex()};$lease.Dispose()}
}
