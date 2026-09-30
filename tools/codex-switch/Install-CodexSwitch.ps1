# Prepare local Codex switch state. Raycast is the only entry point.
# Secrets stay in %LOCALAPPDATA%. This script does not edit PowerShell profiles.
$ErrorActionPreference = 'Stop'

$stateRoot = Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\codex-switch'
$relayDir = Join-Path $stateRoot 'relays'
$openAiDir = Join-Path $stateRoot 'openai'
$backupDir = Join-Path $stateRoot 'backups'
New-Item -ItemType Directory -Force -Path $relayDir, $openAiDir, $backupDir | Out-Null

$legacyRoot = Join-Path $env:USERPROFILE '.codex\switch'
$legacyRelays = Join-Path $legacyRoot 'relays'
if (Test-Path -LiteralPath $legacyRelays) {
    Get-ChildItem -LiteralPath $legacyRelays -Filter '*.toml' -File | ForEach-Object {
        $dest = Join-Path $relayDir $_.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $_.FullName -Destination $dest
            Write-Host "Copied relay: $($_.Name)"
        }
    }
}

$legacyAuth = Join-Path $legacyRoot 'openai\auth.json'
$authDest = Join-Path $openAiDir 'auth.json'
if ((Test-Path -LiteralPath $legacyAuth) -and -not (Test-Path -LiteralPath $authDest)) {
    Copy-Item -LiteralPath $legacyAuth -Destination $authDest
    Write-Host 'Copied local OpenAI auth snapshot.'
}

Write-Host "State: $stateRoot"
Write-Host 'Use the Raycast command: Codex Switch'
