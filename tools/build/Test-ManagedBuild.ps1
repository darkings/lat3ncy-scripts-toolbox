[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ManifestPath,
    [ValidateSet('anchor-locator','audio-switcher')]
    [string[]]$ExpectedComponents=@('anchor-locator','audio-switcher'))
$ErrorActionPreference='Stop'
$ManifestPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ManifestPath)
. (Join-Path $PSScriptRoot 'ManagedBuild.Core.ps1')
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Test-ToolboxManagedBuild -RepoRoot $repo -ManifestPath $ManifestPath -ExpectedComponents $ExpectedComponents | ConvertTo-Json -Depth 4
