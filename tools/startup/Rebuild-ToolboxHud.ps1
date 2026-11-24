# Formal composite rebuild. Same deployment lease and transaction as HUD releases.
[CmdletBinding()]
param([switch]$PlanOnly)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'HudRebuild.Core.ps1')
. (Join-Path $PSScriptRoot 'HudRebuild.Runtime.ps1')
$result=Invoke-ToolboxHudRebuild -Repo $repo -PlanOnly:$PlanOnly `
    -BuildCandidate {param($work) New-ToolboxHudCandidate $repo $work} `
    -TestCandidate {param($work) Test-ToolboxHudExecutables (Join-Path $work 'bundle')} `
    -StopRuntime {Stop-ToolboxReleaseRuntime $repo} `
    -StartRuntime {Start-ToolboxReleaseRuntime $repo} `
    -CheckRuntime {Test-ToolboxReleaseRuntime $repo} `
    -TestInstalled {Test-ToolboxHudExecutables $repo}
$result | ConvertTo-Json -Depth 6
