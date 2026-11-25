# Release files/rollback; runtime operations are injected callbacks, with no defaults.
function Join-ToolboxReleasePath {
    param([string]$Root,[string]$Relative)
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)){throw 'Invalid release relative path'}
    $path=[IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
    if(-not $path.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase)){throw 'Release path escapes target directory'}
    if($Relative.Contains(':')){throw 'Release paths cannot contain alternate data streams'}
    $parent=$path
    while($parent -and $parent.Length -ge $rootPath.TrimEnd('\').Length){
        if(Test-Path -LiteralPath $parent){
            if((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Release target/backup cannot traverse reparse points'}
        }
        $parent=[IO.Path]::GetDirectoryName($parent)
    }
    return $path
}

function Copy-ToolboxReleaseFile {
    param([string]$Source,[string]$Destination)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    $temporary=$Destination+'.'+[guid]::NewGuid().ToString('N')+'.deploy-tmp'
    try {
        [IO.File]::Copy($Source,$temporary)
        if([IO.File]::Exists($Destination)){[IO.File]::Replace($temporary,$Destination,[System.Management.Automation.Language.NullString]::Value)}
        else{[IO.File]::Move($temporary,$Destination)}
    } finally {if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Get-ToolboxReleaseChanges {
    param([string]$Source,[string]$Target)
    $sourcePath=[IO.Path]::GetFullPath($Source).TrimEnd('\')
    if($sourcePath -ieq [IO.Path]::GetFullPath($Target).TrimEnd('\')){throw 'Release source equals target'}
    $entries=@(Get-ChildItem -LiteralPath $sourcePath -Recurse -Force)
    if(@($entries | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Release source cannot contain reparse points'}
    foreach($file in $entries | Where-Object {-not $_.PSIsContainer -and $_.Name -notmatch '\.log(?:\.|$)'}){
        $relative=$file.FullName.Substring($sourcePath.Length).TrimStart('\')
        $destination=Join-ToolboxReleasePath $Target $relative
        $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $exists=Test-Path -LiteralPath $destination -PathType Leaf
        $oldHash=if($exists){(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}else{''}
        if($oldHash -ne $hash){[pscustomobject]@{Relative=$relative;Existed=$exists;BeforeHash=$oldHash;AfterHash=$hash}}
    }
}

function New-ToolboxRelease {
    param([string]$Source,[string]$Target,[string]$ReleaseDirectory,[object[]]$Changes,[string]$SourceStamp)
    if(Test-Path -LiteralPath $ReleaseDirectory){throw 'Release directory already exists'}
    [void][IO.Directory]::CreateDirectory((Join-Path $ReleaseDirectory 'backup'))
    foreach($change in $Changes){
        if($change.Existed){
            $path=Join-ToolboxReleasePath $Target $change.Relative
            if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $change.BeforeHash){throw 'Production files changed during preparation'}
            $backup=Join-ToolboxReleasePath (Join-Path $ReleaseDirectory 'backup') $change.Relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup))
            [IO.File]::Copy($path,$backup)
        }
    }
    $manifest=[ordered]@{Version=1;CreatedUtc=[DateTime]::UtcNow.ToString('o');SourceRoot=[IO.Path]::GetFullPath($Source);TargetRoot=[IO.Path]::GetFullPath($Target);SourceStamp=$SourceStamp;State='prepared';Files=@($Changes)}
    Save-ToolboxReleaseManifest $ReleaseDirectory $manifest
    return [pscustomobject]$manifest
}

function Save-ToolboxReleaseManifest {
    param([string]$ReleaseDirectory,$Manifest)
    $path=Join-Path $ReleaseDirectory 'manifest.json'
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}
        else{[IO.File]::Move($temporary,$path)}
    } finally {if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Assert-ToolboxReleaseBackup {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget)
    $manifest=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.Version -ne 1 -or [IO.Path]::GetFullPath($ExpectedTarget) -ine $manifest.TargetRoot){throw 'Release target/version mismatch'}
    # Validate every backup before making any change.
    foreach($entry in $manifest.Files){
        $null=Join-ToolboxReleasePath $ExpectedTarget $entry.Relative
        if($entry.Existed){
            $backup=Join-ToolboxReleasePath (Join-Path $ReleaseDirectory 'backup') $entry.Relative
            if((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $entry.BeforeHash){throw 'Release backup hash mismatch'}
        }
    }
}

function Get-ToolboxReleaseRestorePlan {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget)
    Assert-ToolboxReleaseBackup $ReleaseDirectory $ExpectedTarget
    $manifest=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries=@();$conflicts=@()
    foreach($entry in $manifest.Files){
        $path=Join-ToolboxReleasePath $ExpectedTarget $entry.Relative
        $exists=Test-Path -LiteralPath $path -PathType Leaf
        $current=if($exists){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}else{''}
        # A committed release is at AfterHash; an already-restored one is at
        # BeforeHash. Any other bytes belong to a later writer.
        if($current -cne [string]$entry.AfterHash -and $current -cne [string]$entry.BeforeHash){
            $conflicts+=[string]$entry.Relative
            $action='conflict'
        } elseif($current -ceq [string]$entry.BeforeHash){$action='already-prior'}
        else {$action='restore'}
        $entries+=[pscustomobject]@{Relative=[string]$entry.Relative;Action=$action;CurrentHash=$current;
            InstalledHash=[string]$entry.AfterHash;BackupHash=[string]$entry.BeforeHash}
    }
    return [pscustomobject]@{Release=$ReleaseDirectory;Entries=@($entries);Conflicts=@($conflicts)}
}

function Assert-ToolboxReleaseRestorable {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget)
    $plan=Get-ToolboxReleaseRestorePlan $ReleaseDirectory $ExpectedTarget
    if($plan.Conflicts.Count){throw "Rollback conflict: $($plan.Conflicts -join ', '); scene preserved"}
    return $plan
}

function Assert-ToolboxReleaseInstalled {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget,[switch]$VerifyBackupState)
    Assert-ToolboxReleaseBackup $ReleaseDirectory $ExpectedTarget
    $manifest=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($entry in $manifest.Files){
        $path=Join-ToolboxReleasePath $ExpectedTarget $entry.Relative
        $expected=if($VerifyBackupState){[string]$entry.BeforeHash}else{[string]$entry.AfterHash}
        if($entry.Existed){
            if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or
               (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $expected){
                throw "Release installation verification failed: $($entry.Relative)"
            }
        } elseif(Test-Path -LiteralPath $path -PathType Leaf){
            throw "Release installation left an unexpected file: $($entry.Relative)"
        }
    }
}

function Restore-ToolboxRelease {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget)
    Assert-ToolboxReleaseBackup $ReleaseDirectory $ExpectedTarget
    $manifest=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($entry in $manifest.Files){
        $destination=Join-ToolboxReleasePath $ExpectedTarget $entry.Relative
        if($entry.Existed){Copy-ToolboxReleaseFile (Join-ToolboxReleasePath (Join-Path $ReleaseDirectory 'backup') $entry.Relative) $destination}
        elseif([IO.File]::Exists($destination)){[IO.File]::Delete($destination)}
    }
}

function Assert-ToolboxReleaseTargetFile {
    param([string]$Target,$Entry)
    $path=Join-ToolboxReleasePath $Target $Entry.Relative
    $exists=Test-Path -LiteralPath $path -PathType Leaf
    if($exists -ne [bool]$Entry.Existed -or
       ($exists -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Entry.BeforeHash)){
        throw "Production file changed after preparation: $($Entry.Relative)"
    }
}

function Assert-ToolboxReleaseReady {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget)
    Assert-ToolboxReleaseBackup $ReleaseDirectory $ExpectedTarget
    $manifest=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($entry in $manifest.Files){
        $source=Join-ToolboxReleasePath $manifest.SourceRoot $entry.Relative
        if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.AfterHash){throw 'Release source changed after preparation'}
        Assert-ToolboxReleaseTargetFile $ExpectedTarget $entry
    }
}

function Restore-ToolboxInstalledFiles {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget,[object[]]$InstalledFiles)
    if(-not $InstalledFiles.Count){return}
    Assert-ToolboxReleaseBackup $ReleaseDirectory $ExpectedTarget
    $restore=@()
    # Check every destination before restoring any bytes. A later writer owns
    # its update; automatic rollback must not overwrite it using our backup.
    foreach($entry in $InstalledFiles){
        $path=Join-ToolboxReleasePath $ExpectedTarget $entry.Relative
        if(Test-Path -LiteralPath $path -PathType Leaf){
            $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if($hash -eq $entry.AfterHash){$restore+=$entry}
            elseif(-not $entry.Existed -or $hash -ne $entry.BeforeHash){throw "Automatic rollback conflict: $($entry.Relative)"}
        } elseif($entry.Existed){throw "Automatic rollback conflict (file removed): $($entry.Relative)"}
    }
    foreach($entry in $restore){
        $path=Join-ToolboxReleasePath $ExpectedTarget $entry.Relative
        if($entry.Existed){Copy-ToolboxReleaseFile (Join-ToolboxReleasePath (Join-Path $ReleaseDirectory 'backup') $entry.Relative) $path}
        else{[IO.File]::Delete($path)}
    }
}

function Install-ToolboxRelease {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget,[Collections.Generic.List[object]]$AppliedFiles)
    # Outside the mutation catch: a preflight failure must not restore anything.
    Assert-ToolboxReleaseReady $ReleaseDirectory $ExpectedTarget
    $manifest=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($null -eq $AppliedFiles){$AppliedFiles=[Collections.Generic.List[object]]::new()}
    try {
        foreach($entry in $manifest.Files){
            $source=Join-ToolboxReleasePath $manifest.SourceRoot $entry.Relative
            if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.AfterHash){throw 'Release source changed after preparation'}
            $destination=Join-ToolboxReleasePath $ExpectedTarget $entry.Relative
            Assert-ToolboxReleaseTargetFile $ExpectedTarget $entry
            $AppliedFiles.Add($entry)
            Copy-ToolboxReleaseFile $source $destination
            if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $entry.AfterHash){throw 'Release readback mismatch'}
        }
    } catch {
        Restore-ToolboxInstalledFiles $ReleaseDirectory $ExpectedTarget @($AppliedFiles.ToArray())
        $AppliedFiles.Clear()
        throw
    }
}

function Invoke-ToolboxReleaseTransaction {
    param([string]$ReleaseDirectory,[string]$ExpectedTarget,
        [scriptblock]$StopRuntime,[scriptblock]$StartRuntime,[scriptblock]$CheckRuntime,[scriptblock]$ValidateInstalled,
        [scriptblock]$ValidatePrepared)
    Assert-ToolboxReleaseReady $ReleaseDirectory $ExpectedTarget
    if($ValidatePrepared){& $ValidatePrepared}
    $applied=[Collections.Generic.List[object]]::new()
    try {
        & $StopRuntime
        if($ValidatePrepared){& $ValidatePrepared}
        Install-ToolboxRelease $ReleaseDirectory $ExpectedTarget $applied
        & $ValidateInstalled
        & $StartRuntime
        return (& $CheckRuntime)
    } catch {
        $failure=$_
        try {
            & $StopRuntime
            Restore-ToolboxInstalledFiles $ReleaseDirectory $ExpectedTarget @($applied.ToArray())
            & $StartRuntime
            $null=& $CheckRuntime
        } catch {throw "Deployment failed: $($failure.Exception.Message); recovery failed: $($_.Exception.Message). Backup: $ReleaseDirectory"}
        throw $failure
    }
}
