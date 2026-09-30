#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Codex Switch
# @raycast.mode silent
# @raycast.packageName Lat3ncy Toolbox
# @raycast.platform windows
# @raycast.icon 🔁
# @raycast.description Switch Codex, show status, or save the OpenAI login. Success and failure use system toasts.
# @raycast.argument1 { "type": "dropdown", "placeholder": "Action", "optional": false, "data": [ { "title": "Status", "value": "status" }, { "title": "OpenAI", "value": "openai" }, { "title": "Relay", "value": "relay" }, { "title": "Save OpenAI Auth", "value": "save" } ] }
# @raycast.argument2 { "type": "text", "placeholder": "Relay name, e.g. cctq", "optional": true }

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')
. (Join-Path $PSScriptRoot '_lib\codex-switch.ps1')

function Show-CodexToast {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not (Show-SystemToast -Title $Title -Message $Message)) {
        throw "System notification failed: $Title"
    }
}

trap {
    Show-SystemToast -Title 'Codex Switch failed' -Message $_.Exception.Message | Out-Null
    exit 1
}

$action = if ($args.Count -ge 1) { ([string]$args[0]).Trim().ToLowerInvariant() } else { '' }
$name = if ($args.Count -ge 2) { ([string]$args[1]).Trim() } else { '' }

switch ($action) {
    'status' {
        $current = Get-CodexProvider
        $relays = @(Get-ChildItem -LiteralPath $script:CodexRelayDir -Filter '*.toml' -File -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object { $_.BaseName })
        $relayText = if ($relays.Count) { $relays -join ', ' } else { 'none' }
        $authText = if ($current.AuthPresent) { 'present' } else { 'absent' }
        $snapshotText = if ($current.OpenAiSnapshotPresent) { 'present' } else { 'absent' }
        Show-CodexToast -Title 'Codex Status' -Message ("{0} / {1}`nAuth {2}, snapshot {3}`nRelays: {4}" -f $current.Provider, $current.Model, $authText, $snapshotText, $relayText)
    }
    'openai' {
        $before = Get-CodexProvider
        $already = Test-CodexTargetActive -Target 'openai' -Current $before
        if (-not $already) { Switch-Codex -Target 'openai' }
        $current = Get-CodexProvider
        $verb = if ($already) { 'Already on OpenAI' } else { 'Switched to OpenAI' }
        Show-CodexToast -Title 'Codex switched' -Message ("{0}`n{1} / {2}`nRestart ChatGPT." -f $verb, $current.Provider, $current.Model)
    }
    'relay' {
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Relay name is required.' }
        $before = Get-CodexProvider
        $already = Test-CodexTargetActive -Target $name -Current $before
        if (-not $already) { Switch-Codex -Target $name }
        $current = Get-CodexProvider
        $verb = if ($already) { "Already on $name" } else { "Switched to $name" }
        Show-CodexToast -Title 'Codex switched' -Message ("{0}`n{1} / {2}`nRestart ChatGPT." -f $verb, $current.Provider, $current.Model)
    }
    'save' {
        Save-CodexAuth
        Show-CodexToast -Title 'Codex Auth saved' -Message 'OpenAI snapshot saved.'
    }
    default {
        throw 'Choose status, openai, relay, or save.'
    }
}