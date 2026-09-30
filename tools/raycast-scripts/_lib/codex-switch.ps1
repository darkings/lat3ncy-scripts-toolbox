# Shared loader for Codex Raycast commands. Does not switch by itself.
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$provider = Join-Path $repositoryRoot 'tools\codex-switch\Switch-CodexProvider.ps1'
if (-not (Test-Path -LiteralPath $provider -PathType Leaf)) {
    throw "Missing switcher: $provider"
}

. $provider