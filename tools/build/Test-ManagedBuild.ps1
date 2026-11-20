[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ManifestPath)
$ErrorActionPreference='Stop'
$ManifestPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ManifestPath)
. (Join-Path $PSScriptRoot 'ManagedBuild.Core.ps1')
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Test-ToolboxManagedBuild -RepoRoot $repo -ManifestPath $ManifestPath | ConvertTo-Json -Depth 4
