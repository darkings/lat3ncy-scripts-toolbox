$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'HudRebuild.Core.ps1')
# Some sandboxed hosts deny MoveFileEx-based File.Replace. This fixture tests
# release selection/orchestration; the atomic rewrite contract itself is covered
# by Deployment.Tests.ps1. Override only the copy primitive here.
function Copy-ToolboxReleaseFile {
    param([string]$Source,[string]$Destination)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    [IO.File]::Copy($Source,$Destination,$true)
}
function Save-ToolboxReleaseManifest {
    param([string]$ReleaseDirectory,$Manifest)
    $path=Join-Path $ReleaseDirectory 'manifest.json'
    [IO.File]::WriteAllText($path,($Manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
}
function Assert($Value,$Label){if(-not $Value){throw "FAIL: $Label"}}
function ReadText($Path){[IO.File]::ReadAllText($Path)}
$root=Join-Path ([IO.Path]::GetTempPath()) ('toolbox-hud-rollback-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $root 'checkout'
$files=@('shared\notify\anchor-locator.exe','tools\ime-hud-winui\out\ImeHudWinUi.exe',
    'tools\ime-hud-winui\out\ImeHudWinUi.dll','tools\ime-hud-winui\out\.source-stamp')
$oldValues=@('anchor-old','hud-old','dll-old','stamp-old')
$newValues=@('anchor-new','hud-new','dll-new','stamp-new')
try {
    foreach($dir in @('shared\notify','tools\ime-hud-winui\out','.tmp\releases')){
        [void][IO.Directory]::CreateDirectory((Join-Path $repo $dir))
    }
    for($i=0;$i -lt $files.Count;$i++){[IO.File]::WriteAllText((Join-Path $repo $files[$i]),$oldValues[$i])}
    $bundle=Join-Path $root 'bundle'
    for($i=0;$i -lt $files.Count;$i++){
        $path=Join-Path $bundle $files[$i]
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.File]::WriteAllText($path,$newValues[$i])
    }
    $changes=@(Get-ToolboxReleaseChanges $bundle $repo)
    Assert ($changes.Count -eq 4) 'all compound artifacts are captured'
    $release=Join-Path $repo '.tmp\releases\hud-fixture'
    $stamp=('a'*64)+':'+('b'*64)
    $manifest=New-ToolboxRelease $bundle $repo $release $changes $stamp
    $manifest.State='healthy'
    Save-ToolboxReleaseManifest $release $manifest
    Install-ToolboxRelease $release $repo
    Assert ((ReadText (Join-Path $repo $files[1])) -eq 'hud-new') 'compound release installed'

    $list=@(Get-ToolboxHudReleases $repo)
    Assert ($list.Count -eq 1) 'compound release appears in backup list'
    Assert ($list[0].State -eq 'healthy') 'backup list reports release state'
    Assert ($list[0].FileCount -eq 4) 'backup list reports artifact count'
    Assert ($list[0].AnchorSource -eq ('b'*64)) 'backup list includes anchor source stamp'

    $preview=Get-ToolboxHudReleasePreview $release $repo
    Assert ($preview.Conflicts.Count -eq 0) 'clean preview has no conflicts'
    Assert ($preview.Entries.Count -eq 4) 'preview lists every artifact'
    Assert (@($preview.Entries | Where-Object {$_.Action -ne 'restore'}).Count -eq 0) 'preview marks all files restorable'

    $other=Join-Path $root 'other'
    [void][IO.Directory]::CreateDirectory($other)
    $failed=$false
    try{Assert-ToolboxHudRelease $release $other | Out-Null}catch{$failed=$true}
    Assert $failed 'foreign checkout release is rejected'

    $single=Join-Path $repo '.tmp\releases\hud-single-fixture'
    [void][IO.Directory]::CreateDirectory((Join-Path $single 'backup'))
    $singleManifest=[ordered]@{Version=1;CreatedUtc=[DateTime]::UtcNow.ToString('o');SourceRoot=$bundle;
        TargetRoot=(Join-Path $repo 'tools\ime-hud-winui\out');SourceStamp='single';State='healthy';Files=@()}
    Save-ToolboxReleaseManifest $single $singleManifest
    $failed=$false
    try{Assert-ToolboxHudRelease $single $repo | Out-Null}catch{$failed=$true}
    Assert $failed 'single HUD release is rejected by the compound entry'
    $list2=@(Get-ToolboxHudReleases $repo)
    Assert ($list2.Count -eq 2) 'invalid backup stays visible in the list'
    Assert (@($list2 | Where-Object {$_.State -eq 'invalid' -and $_.Error.Length -gt 0}).Count -eq 1) 'invalid backup explains why'

    $script:stops=0;$script:starts=0;$script:checks=0;$script:tests=0
    $result=Invoke-ToolboxHudReleaseRollback -ReleaseDirectory $release -Repo $repo `
        -StopRuntime {$script:stops++} -StartRuntime {$script:starts++} `
        -CheckRuntime {$script:checks++;return [pscustomobject]@{Ok=$true}} `
        -TestInstalled {$script:tests++;Assert-ToolboxReleaseInstalled $release $repo -VerifyBackupState}
    Assert ($result.Action -eq 'rolled-back') 'rollback reports its action'
    Assert ($script:stops -eq 1 -and $script:starts -eq 1 -and $script:checks -eq 1 -and $script:tests -eq 1) 'runtime callbacks run once'
    Assert ((ReadText (Join-Path $repo $files[1])) -eq 'hud-old') 'rollback restores prior HUD bytes'
    Assert ((ReadText (Join-Path $repo $files[0])) -eq 'anchor-old') 'rollback restores the anchor assistant'
    Assert (Test-Path -LiteralPath $result.SafetyBackup) 'reverse backup is retained'
    Assert-ToolboxReleaseInstalled $result.SafetyBackup $repo
    Assert ((ReadText (Join-Path $result.SafetyBackup 'manifest.json')) -match 'before-rollback') 'reverse backup is marked'

    $plan=Get-ToolboxReleaseRestorePlan $release $repo
    Assert (@($plan.Entries | Where-Object {$_.Action -ne 'already-prior'}).Count -eq 0) 'restored state is recognized as prior'

    Install-ToolboxRelease $release $repo
    [IO.File]::WriteAllText((Join-Path $repo $files[1]),'later-writer')
    $preview2=Get-ToolboxHudReleasePreview $release $repo
    Assert (@($preview2.Conflicts | Where-Object {$_ -eq $files[1]}).Count -eq 1) 'preview detects a later writer'
    $script:stops=0;$script:starts=0
    $failed=$false
    try {
        Invoke-ToolboxHudReleaseRollback -ReleaseDirectory $release -Repo $repo `
            -StopRuntime {$script:stops++} -StartRuntime {$script:starts++} `
            -CheckRuntime {$true} -TestInstalled {}
    } catch {$failed=$_.Exception.Message -match 'Rollback conflict'}
    Assert $failed 'rollback with a conflict is refused'
    Assert ($script:stops -eq 0 -and $script:starts -eq 0) 'conflict never touches the resident'
    Assert ((ReadText (Join-Path $repo $files[1])) -eq 'later-writer') 'conflict preserves the later writer'

    [IO.File]::WriteAllText((Join-Path $repo $files[1]),'hud-new')
    $script:stops=0;$script:starts=0
    $failed=$false
    try {
        Invoke-ToolboxHudReleaseRollback -ReleaseDirectory $release -Repo $repo `
            -StopRuntime {$script:stops++;if($script:stops -eq 1){[IO.File]::WriteAllText((Join-Path $repo $files[1]),'during-stop')}} `
            -StartRuntime {$script:starts++} -CheckRuntime {$true} -TestInstalled {}
    } catch {$failed=$_.Exception.Message -match 'Rollback conflict'}
    Assert $failed 'destination drift after stopping is detected'
    Assert ((ReadText (Join-Path $repo $files[1])) -eq 'during-stop') 'post-stop drift is preserved'
    Assert ($script:stops -eq 2 -and $script:starts -eq 1) 'post-stop failure restarts the resident without file recovery'

    [IO.File]::WriteAllText((Join-Path $repo $files[1]),'hud-new')
    $script:stops=0;$script:starts=0;$script:checks=0
    $failed=$false
    try {
        Invoke-ToolboxHudReleaseRollback -ReleaseDirectory $release -Repo $repo `
            -StopRuntime {$script:stops++} -StartRuntime {$script:starts++} `
            -CheckRuntime {$script:checks++;$true} -TestInstalled {throw 'injected verification failure'}
    } catch {$failed=$_.Exception.Message -match 'injected verification failure'}
    Assert $failed 'post-mutation failure is reported with a backup path'
    Assert ((ReadText (Join-Path $repo $files[1])) -eq 'hud-new') 'failed rollback restores pre-rollback bytes'
    Assert ($script:stops -eq 2 -and $script:starts -eq 1 -and $script:checks -eq 1) 'failed rollback restarts the resident'

    [Console]::Out.WriteLine('PASS: composite HUD release listing, preview and rollback tests')
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
       [IO.Path]::GetFileName($resolved) -like 'toolbox-hud-rollback-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
