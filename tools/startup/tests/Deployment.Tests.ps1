$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Deployment.Core.ps1')
function Assert($Value,$Label){if(-not $Value){throw "FAIL: $Label"}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('toolbox-release-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $root 'source';$target=Join-Path $root 'target';$release=Join-Path $root 'release'
[void][IO.Directory]::CreateDirectory($source);[void][IO.Directory]::CreateDirectory($target)
try {
    [IO.File]::WriteAllText((Join-Path $target 'app.dll'),'old')
    [IO.File]::WriteAllText((Join-Path $source 'app.dll'),'new')
    [IO.File]::WriteAllText((Join-Path $source 'added.dll'),'added')
    [IO.File]::WriteAllText((Join-Path $source 'runtime.log'),'never deployed')
    $changes=@(Get-ToolboxReleaseChanges $source $target)
    Assert ($changes.Count -eq 2) 'logs excluded from release'
    $null=New-ToolboxRelease $source $target $release $changes 'fixture'
    Install-ToolboxRelease $release $target
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'new') 'changed file installed'
    Assert (@(Get-ToolboxReleaseChanges $source $target).Count -eq 0) 'same release is idempotent'
    Restore-ToolboxRelease $release $target
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'old') 'rollback restores prior bytes'
    Assert (-not(Test-Path (Join-Path $target 'added.dll'))) 'rollback removes newly introduced file'
    # Exercise the production orchestration with a failing health probe. Runtime
    # callbacks are fixtures, but file mutation/backup/restore are the real code.
    $script:starts=0;$script:stops=0
    $failed=$false
    try {
        Invoke-ToolboxReleaseTransaction -ReleaseDirectory $release -ExpectedTarget $target `
            -StopRuntime {$script:stops++} -StartRuntime {$script:starts++} -ValidateInstalled {} `
            -CheckRuntime {
                if([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'new'){throw 'injected health failure'}
                return $true
            } | Out-Null
    } catch {$failed=$_.Exception.Message -match 'injected health failure'}
    Assert $failed 'health failure is reported'
    Assert ($script:starts -eq 2 -and $script:stops -eq 2) 'health failure restarts previous runtime'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'old') 'health failure restores prior bytes'
    Assert (-not(Test-Path (Join-Path $target 'added.dll'))) 'health rollback removes introduced files'
    # Preflight rejects stale candidates before touching the resident or files.
    [IO.File]::WriteAllText((Join-Path $source 'app.dll'),'changed after snapshot')
    $script:stops=0
    $failed=$false
    try {
        Invoke-ToolboxReleaseTransaction $release $target -StopRuntime {$script:stops++} -StartRuntime {} -CheckRuntime {} -ValidateInstalled {}
    } catch {$failed=$true}
    Assert ($failed -and $script:stops -eq 0) 'stale candidate never stops the resident'
    $failed=$false
    try{Install-ToolboxRelease $release $target}catch{$failed=$true}
    Assert $failed 'changed staging input rejects deployment'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'old') 'failed install rolls back'
    Assert (-not(Test-Path (Join-Path $target 'added.dll'))) 'failed preflight introduces no files'
    [IO.File]::WriteAllText((Join-Path $source 'app.dll'),'new')
    [IO.File]::WriteAllText((Join-Path $target 'app.dll'),'concurrent-update')
    $failed=$false
    try{Install-ToolboxRelease $release $target}catch{$failed=$_.Exception.Message -match 'Production file changed'}
    Assert $failed 'destination drift is detected before deployment'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'concurrent-update') 'preflight failure preserves later update'
    [IO.File]::WriteAllText((Join-Path $target 'app.dll'),'old')
    [IO.File]::WriteAllText((Join-Path $target 'added.dll'),'another-writer')
    $failed=$false
    try{Install-ToolboxRelease $release $target}catch{$failed=$true}
    Assert $failed 'new file collision is rejected'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'added.dll')) -eq 'another-writer') 'new file collision is never deleted by rollback'
    [IO.File]::Delete((Join-Path $target 'added.dll'))
    $script:stops=0;$script:starts=0
    $failed=$false
    try {
        Invoke-ToolboxReleaseTransaction $release $target -StopRuntime {
            $script:stops++
            if($script:stops -eq 1){[IO.File]::WriteAllText((Join-Path $target 'app.dll'),'updated during stop')}
        } -StartRuntime {$script:starts++} -ValidateInstalled {} -CheckRuntime {$true}
    } catch {$failed=$_.Exception.Message -match 'Production file changed'}
    Assert $failed 'destination is revalidated after stopping the resident'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'updated during stop') 'post-stop preflight cannot roll back an unapplied change'
    Assert ($script:starts -eq 1) 'pre-mutation failure restarts the prior runtime'
    [IO.File]::WriteAllText((Join-Path $target 'app.dll'),'old')
    # A source changes after the first atomic write, exercising partial recovery.
    $script:originalCopy=${function:Copy-ToolboxReleaseFile}
    $script:injected=$false
    $script:fixtureSource=$source
    function Copy-ToolboxReleaseFile {
        param([string]$Source,[string]$Destination)
        & $script:originalCopy $Source $Destination
        if(-not $script:injected){
            $script:injected=$true
            [IO.File]::WriteAllText((Join-Path $script:fixtureSource 'app.dll'),'late staging change')
        }
    }
    $failed=$false
    try{Install-ToolboxRelease $release $target}catch{$failed=$_.Exception.Message -match 'Release source changed'}
    finally{Set-Item -LiteralPath Function:\Copy-ToolboxReleaseFile -Value $script:originalCopy}
    Assert ($failed -and $script:injected) 'late staging failure happens after one write'
    Assert (-not(Test-Path (Join-Path $target 'added.dll'))) 'partial write is removed on failure'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'old') 'unwritten file remains intact'
    [IO.File]::WriteAllText((Join-Path $source 'app.dll'),'new')
    $failed=$false
    try {
        Invoke-ToolboxReleaseTransaction $release $target -StopRuntime {} -StartRuntime {} -ValidateInstalled {} -CheckRuntime {
            [IO.File]::WriteAllText((Join-Path $target 'app.dll'),'post-install-update')
            throw 'injected post-install failure'
        }
    } catch {$failed=$_.Exception.Message -match 'Automatic rollback conflict'}
    Assert $failed 'rollback refuses a later writer with an explicit diagnostic'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'app.dll')) -eq 'post-install-update') 'rollback conflict preserves later bytes'
    Assert (Test-Path (Join-Path $target 'added.dll')) 'conflict is checked before restoring any other file'
    # An explicit operator rollback is still allowed after reviewing the conflict.
    Restore-ToolboxRelease $release $target
    $failed=$false
    try{Restore-ToolboxRelease $release $source}catch{$failed=$true}
    Assert $failed 'rollback cannot target another checkout'
    $failed=$false
    try{Join-ToolboxReleasePath $target '..\escape.dll' | Out-Null}catch{$failed=$true}
    Assert $failed 'path traversal is rejected'
    $failed=$false
    try{Join-ToolboxReleasePath $target 'app.dll:stream' | Out-Null}catch{$failed=$true}
    Assert $failed 'alternate data streams are rejected'
    [IO.File]::WriteAllText((Join-Path $release 'backup\app.dll'),'corrupt')
    $failed=$false
    try{Restore-ToolboxRelease $release $target}catch{$failed=$true}
    Assert $failed 'corrupt rollback data is rejected before mutation'
    [Console]::Out.WriteLine('PASS: release transaction tests')
} finally {
    # Verify our unique absolute workspace before recursive cleanup.
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
       [IO.Path]::GetFileName($resolved) -like 'toolbox-release-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
