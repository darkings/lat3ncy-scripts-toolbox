# Manual rollback entry for composite HUD/anchor releases.
[CmdletBinding(DefaultParameterSetName='List')]
param(
    [Parameter(ParameterSetName='List')][switch]$List,
    [Parameter(Mandatory=$true,ParameterSetName='Preview')][string]$Preview,
    [Parameter(Mandatory=$true,ParameterSetName='Rollback')][string]$RollbackRelease
)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'HudRebuild.Core.ps1')
switch ($PSCmdlet.ParameterSetName) {
    'Preview' {
        Get-ToolboxHudReleasePreview ([IO.Path]::GetFullPath($Preview)) $repo | ConvertTo-Json -Depth 6
    }
    'Rollback' {
        . (Join-Path $PSScriptRoot 'HudRebuild.Runtime.ps1')
        $release=[IO.Path]::GetFullPath($RollbackRelease)
        $null=Assert-ToolboxHudRelease $release $repo
        Write-MaintenanceProgress -Stage restore -Result running -Record ([IO.Path]::GetFileName($release)) -Repo $repo
        try {
        $result=Invoke-ToolboxHudReleaseRollback -ReleaseDirectory $release -Repo $repo `
            -StopRuntime {Stop-ToolboxReleaseRuntime $repo} `
            -StartRuntime {Start-ToolboxReleaseRuntime $repo} `
            -CheckRuntime {Test-ToolboxReleaseRuntime $repo} `
            -TestInstalled {
                Assert-ToolboxReleaseInstalled $release $repo -VerifyBackupState
                if((Test-Path -LiteralPath (Join-Path $repo 'shared\notify\anchor-locator.exe')) -and
                   (Test-Path -LiteralPath (Join-Path $repo 'tools\ime-hud-winui\out\ImeHudWinUi.exe'))){
                    Test-ToolboxHudExecutables $repo
                }
            }
        $result | ConvertTo-Json -Depth 6
        Write-MaintenanceProgress -Stage restore -Result succeeded -Record ([IO.Path]::GetFileName($release)) -Repo $repo
        } catch {
            Write-MaintenanceProgress -Stage restore -Result failed -Record ([IO.Path]::GetFileName($release)) -Failure 'restore_failed' -Repo $repo
            throw
        }
    }
    default {
        Get-ToolboxHudReleases $repo | ConvertTo-Json -Depth 6
    }
}
