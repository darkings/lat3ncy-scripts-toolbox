# Composite HUD/anchor release. Loading this file performs no runtime operations.
. (Join-Path $PSScriptRoot 'Deployment.Core.ps1')
. (Join-Path $PSScriptRoot 'ToolboxProcess.ps1')
. (Join-Path $PSScriptRoot 'MaintenanceProgress.ps1')

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
        Write-MaintenanceProgress -Stage build -Result running -Repo $repoPath
        & $BuildCandidate $work | Out-Null
        $candidate=Assert-ToolboxHudCandidate $repoPath $work
        Write-MaintenanceProgress -Stage verify -Result running -Repo $repoPath
        & $TestCandidate $work | Out-Null
        $null=Assert-ToolboxHudCandidate $repoPath $work
        if(Test-MaintenanceCancelRequested $repoPath){
            Clear-MaintenanceCancel $repoPath
            Write-MaintenanceProgress -Stage verify -Result cancelled -Repo $repoPath
            throw 'Maintenance cancelled before deployment'
        }
        $bundle=Join-Path $work 'bundle'
        $changes=@(Get-ToolboxReleaseChanges $bundle $repoPath)
        if($PlanOnly){return [pscustomobject]@{Action='plan';Work=$work;ChangedFiles=@($changes | ForEach-Object {$_.Relative})}}
        $release=Join-Path $repoPath ('.tmp\releases\hud-'+[guid]::NewGuid().ToString('N'))
        $null=Join-ToolboxReleasePath $repoPath ($release.Substring($repoPath.TrimEnd('\').Length).TrimStart('\')+'\probe')
        $manifest=New-ToolboxRelease $bundle $repoPath $release $changes ($candidate.HudSource+':'+$candidate.AnchorSource)
        Write-MaintenanceProgress -Stage deploy -Result running -Record ([IO.Path]::GetFileName($release)) -Repo $repoPath
        try {
            $health=Invoke-ToolboxReleaseTransaction -ReleaseDirectory $release -ExpectedTarget $repoPath `
                -StopRuntime $StopRuntime -StartRuntime $StartRuntime -CheckRuntime $CheckRuntime `
                -ValidatePrepared {$null=Assert-ToolboxHudCandidate $repoPath $work} `
                -ValidateInstalled {Assert-ToolboxHudInstalled $repoPath $candidate; & $TestInstalled}
        } catch {
            $failure=$_
            $manifest.State='failed'
            Save-ToolboxReleaseManifest $release $manifest
            Write-MaintenanceProgress -Stage deploy -Result failed -Record ([IO.Path]::GetFileName($release)) -Failure 'deploy_failed' -Repo $repoPath
            throw "HUD deployment failed: $($failure.Exception.Message). Release: $release"
        }
        $manifest.State='healthy'
        $manifest | Add-Member -NotePropertyName Health -NotePropertyValue $health
        Save-ToolboxReleaseManifest $release $manifest
        Write-MaintenanceProgress -Stage deploy -Result succeeded -Record ([IO.Path]::GetFileName($release)) -Repo $repoPath
        return [pscustomobject]@{Action='deployed';Release=$release;Work=$work;ChangedFiles=@($changes | ForEach-Object {$_.Relative});Health=$health}
    } finally {if($owned){$lease.ReleaseMutex()};$lease.Dispose()}
}

function Assert-ToolboxHudRelease {
    param([string]$ReleaseDirectory,[string]$Repo)
    $manifestPath=Join-Path $ReleaseDirectory 'manifest.json'
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'HUD release manifest is missing'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.Version -ne 1){throw 'HUD release version mismatch'}
    $repoPath=[IO.Path]::GetFullPath($Repo).TrimEnd('\')
    if([IO.Path]::GetFullPath([string]$manifest.TargetRoot).TrimEnd('\') -ine $repoPath){
        throw 'HUD release belongs to another checkout'
    }
    $stamp=@([string]$manifest.SourceStamp -split ':',2)
    if($stamp.Count -ne 2 -or $stamp[0].Length -ne 64 -or $stamp[1].Length -ne 64){
        throw 'HUD release lacks a compound HUD/anchor source stamp'
    }
    $seen=@{}
    foreach($entry in $manifest.Files){
        Assert-ToolboxHudReleasePath $entry.Relative
        $key=[string]$entry.Relative
        if($seen.ContainsKey($key)){throw 'HUD release contains duplicate artifacts'}
        $seen[$key]=$true
    }
    # Historical releases only list artifacts that actually changed, so do not
    # demand a fixed file set here; validate every listed path instead.
    if($seen.Count -eq 0){throw 'HUD release has no artifacts'}
    Assert-ToolboxReleaseBackup $ReleaseDirectory $repoPath
    return $manifest
}

function Get-ToolboxHudReleases {
    param([string]$Repo)
    $repoPath=[IO.Path]::GetFullPath($Repo).TrimEnd('\')
    $root=Join-Path $repoPath '.tmp\releases'
    if(-not(Test-Path -LiteralPath $root -PathType Container)){return @()}
    $result=@()
    foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'hud-*')){
        try {
            $manifest=Assert-ToolboxHudRelease $dir.FullName $repoPath
            $stamp=@([string]$manifest.SourceStamp -split ':',2)
            $result+=[pscustomobject]@{Release=$dir.FullName;CreatedUtc=[string]$manifest.CreatedUtc;
                State=[string]$manifest.State;HudSource=$stamp[0];AnchorSource=$stamp[1];
                FileCount=@($manifest.Files).Count;BackupComplete=$true;Error=''}
        } catch {
            $result+=[pscustomobject]@{Release=$dir.FullName;CreatedUtc='';State='invalid';
                HudSource='';AnchorSource='';FileCount=0;BackupComplete=$false;Error=$_.Exception.Message}
        }
    }
    return @($result | Sort-Object -Property CreatedUtc -Descending)
}

function Get-ToolboxHudReleasePreview {
    param([string]$ReleaseDirectory,[string]$Repo)
    $repoPath=[IO.Path]::GetFullPath($Repo).TrimEnd('\')
    $manifest=Assert-ToolboxHudRelease $ReleaseDirectory $repoPath
    $plan=Get-ToolboxReleaseRestorePlan $ReleaseDirectory $repoPath
    $stamp=@([string]$manifest.SourceStamp -split ':',2)
    return [pscustomobject]@{Release=$ReleaseDirectory;State=[string]$manifest.State;
        CreatedUtc=[string]$manifest.CreatedUtc;HudSource=$stamp[0];AnchorSource=$stamp[1];
        SourceRoot=[string]$manifest.SourceRoot;Entries=@($plan.Entries);Conflicts=@($plan.Conflicts)}
}

function Invoke-ToolboxHudReleaseRollback {
    param([string]$ReleaseDirectory,[string]$Repo,[scriptblock]$StopRuntime,[scriptblock]$StartRuntime,
        [scriptblock]$CheckRuntime,[scriptblock]$TestInstalled)
    $repoPath=[IO.Path]::GetFullPath($Repo).TrimEnd('\')
    $manifest=Assert-ToolboxHudRelease $ReleaseDirectory $repoPath
    # Preflight before the lease: a conflict must never stop the resident.
    $null=Assert-ToolboxReleaseRestorable $ReleaseDirectory $repoPath
    $lease=[Threading.Mutex]::new($false,((Get-ToolboxInstanceName (Join-Path $repoPath 'ahk\main.ahk'))+'-Deployment'))
    $owned=$false
    try {
        try{$owned=$lease.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'Another deployment is running for this checkout'}
        $null=Assert-ToolboxReleaseRestorable $ReleaseDirectory $repoPath
        # Capture the exact bytes being replaced, so a failed rollback is reversible.
        $reverse=@()
        foreach($entry in $manifest.Files){
            $path=Join-ToolboxReleasePath $repoPath $entry.Relative
            $exists=Test-Path -LiteralPath $path -PathType Leaf
            $current=if($exists){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}else{''}
            $restored=if($entry.Existed){[string]$entry.BeforeHash}else{''}
            $reverse+=[pscustomobject]@{Relative=[string]$entry.Relative;Existed=$exists;
                BeforeHash=$current;AfterHash=$restored}
        }
        $safety=Join-Path $repoPath ('.tmp\releases\rollback-'+[guid]::NewGuid().ToString('N'))
        $relative=$safety.Substring($repoPath.TrimEnd('\').Length).TrimStart('\')
        $null=Join-ToolboxReleasePath $repoPath ($relative+'\probe')
        $null=New-ToolboxRelease $manifest.SourceRoot $repoPath $safety $reverse 'before-rollback'
        $mutated=$false
        try {
            & $StopRuntime
            # A later writer may have changed files while the resident was stopping.
            $null=Assert-ToolboxReleaseRestorable $ReleaseDirectory $repoPath
            $mutated=$true
            Restore-ToolboxRelease $ReleaseDirectory $repoPath
            & $TestInstalled
            & $StartRuntime
            $health=& $CheckRuntime
        } catch {
            $failure=$_
            try {
                & $StopRuntime
                # Only undo bytes we actually wrote. A pre-mutation failure
                # leaves the scene untouched; just bring the resident back.
                if($mutated){
                    $null=Assert-ToolboxReleaseRestorable $safety $repoPath
                    Restore-ToolboxRelease $safety $repoPath
                    Assert-ToolboxReleaseInstalled $safety $repoPath -VerifyBackupState
                }
                & $StartRuntime
                $null=& $CheckRuntime
            } catch {
                throw "HUD rollback failed: $($failure.Exception.Message); recovery failed: $($_.Exception.Message). Backup: $safety"
            }
            throw $failure
        }
        return [pscustomobject]@{Action='rolled-back';Release=$ReleaseDirectory;SafetyBackup=$safety;
            RestoredFiles=@($manifest.Files | ForEach-Object {$_.Relative});Health=$health}
    } finally {if($owned){$lease.ReleaseMutex()};$lease.Dispose()}
}
