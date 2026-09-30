# Local Codex provider switch. Does not read or write CC Switch.
$ErrorActionPreference = 'Stop'

$script:CodexHome = Join-Path $env:USERPROFILE '.codex'
$script:CodexSwitchState = Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\codex-switch'
$script:CodexConfigPath = Join-Path $script:CodexHome 'config.toml'
$script:CodexAuthPath = Join-Path $script:CodexHome 'auth.json'
$script:CodexStatePath = Join-Path $script:CodexHome 'state_5.sqlite'
$script:CodexOpenAiAuthSnapshot = Join-Path $script:CodexSwitchState 'openai\auth.json'
$script:CodexOpenAiAuthHold = Join-Path $script:CodexHome 'auth.json.openai-hold'
$script:CodexRelayDir = Join-Path $script:CodexSwitchState 'relays'
$script:CodexBackupDir = Join-Path $script:CodexSwitchState 'backups'

function Get-CodexProvider {
    [CmdletBinding()]
    param()

    $configText = Get-CodexConfigText
    $provider = Get-CodexTomlValue -Text $configText -Key 'model_provider'
    $model = Get-CodexTomlValue -Text $configText -Key 'model'
    $threads = @(Get-CodexThreadSummary)

    [pscustomobject]@{
        Provider = $provider
        Model = $model
        AuthPresent = Test-Path -LiteralPath $script:CodexAuthPath
        OpenAiSnapshotPresent = Test-Path -LiteralPath $script:CodexOpenAiAuthSnapshot
        Threads = ($threads | ForEach-Object { '{0}/{1}={2}' -f $_.Provider, $_.Model, $_.Count }) -join ', '
    }
}

function Save-CodexAuth {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:CodexAuthPath)) {
        throw "No auth.json to save: $($script:CodexAuthPath)"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:CodexOpenAiAuthSnapshot) | Out-Null
    Copy-Item -LiteralPath $script:CodexAuthPath -Destination $script:CodexOpenAiAuthSnapshot -Force
    Write-Host "Saved OpenAI auth snapshot: $($script:CodexOpenAiAuthSnapshot)"
}

function Switch-Codex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [switch]$Force
    )

    if ($Target -ne 'openai') {
        $relayPath = Join-Path $script:CodexRelayDir ($Target + '.toml')
        if (-not (Test-Path -LiteralPath $relayPath)) {
            throw "Missing relay config: $relayPath"
        }
    }

    $current = Get-CodexProvider
    if (Test-CodexTargetActive -Target $Target -Current $current) {
        Write-Host "Already on $Target. Provider=$($current.Provider) Model=$($current.Model)"
        return
    }

    Stop-CodexDesktop

    $backupDir = New-CodexSwitchBackup
    try {
        if ($Target -eq 'openai') {
            Switch-CodexToOpenAi
        }
        else {
            Switch-CodexToRelay -RelayName $Target
        }
        Assert-CodexTomlValid -Path $script:CodexConfigPath
    }
    catch {
        Restore-CodexSwitchBackup -BackupDir $backupDir
        throw
    }

    Get-CodexProvider | Format-List
    Write-Host "Backup: $backupDir"
    Write-Host 'Restart ChatGPT desktop before opening a thread.'
}

function Switch-CodexToOpenAi {
    if (-not (Test-Path -LiteralPath $script:CodexOpenAiAuthSnapshot)) {
        if (Test-Path -LiteralPath $script:CodexAuthPath) {
            Save-CodexAuth
        }
        else {
            throw 'Missing OpenAI auth snapshot. Sign in once, then run Save-CodexAuth.'
        }
    }

    Set-CodexTopLevel -Provider 'openai' -Model 'gpt-6-astra'
    Copy-Item -LiteralPath $script:CodexOpenAiAuthSnapshot -Destination $script:CodexAuthPath -Force
    if (Test-Path -LiteralPath $script:CodexOpenAiAuthHold) {
        Remove-Item -LiteralPath $script:CodexOpenAiAuthHold -Force
    }
    Set-CodexThreadProvider -Provider 'openai'
}

function Switch-CodexToRelay {
    param([Parameter(Mandatory = $true)][string]$RelayName)

    $relayPath = Join-Path $script:CodexRelayDir "$RelayName.toml"
    if (-not (Test-Path -LiteralPath $relayPath)) {
        throw "Missing relay snapshot: $relayPath"
    }

    $relay = Read-CodexRelaySnapshot -Path $relayPath
    Set-CodexCustomProvider -Relay $relay
    Set-CodexTopLevel -Provider 'custom' -Model $relay.Model
    if (Test-Path -LiteralPath $script:CodexAuthPath) {
        Move-Item -LiteralPath $script:CodexAuthPath -Destination $script:CodexOpenAiAuthHold -Force
    }
    Set-CodexThreadProvider -Provider 'custom' -Model $relay.Model
}

function Set-CodexTopLevel {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Model
    )

    $text = Get-CodexConfigText
    $text = Set-CodexTomlAssignment -Text $text -Key 'model_provider' -Value $Provider
    $text = Set-CodexTomlAssignment -Text $text -Key 'model' -Value $Model
    Set-CodexConfigText -Text $text
}

function Set-CodexCustomProvider {
    param([Parameter(Mandatory = $true)]$Relay)

    $text = Get-CodexConfigText
    $block = @(
        '[model_providers.custom]'
        'name = "custom"'
        "base_url = `"$($Relay.BaseUrl)`""
        "wire_api = `"$($Relay.WireApi)`""
        'requires_openai_auth = false'
        "experimental_bearer_token = `"$($Relay.Token)`""
    ) -join "`r`n"

    $pattern = '(?ms)^\[model_providers\.custom\]\r?\n.*?(?=^\[|\z)'
    if ([regex]::IsMatch($text, $pattern)) {
        $text = [regex]::Replace($text, $pattern, ($block + "`r`n`r`n"), 1)
    }
    else {
        $text = $text.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    }
    Set-CodexConfigText -Text $text
}

function Set-CodexTomlAssignment {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $pattern = "(?m)^$([regex]::Escape($Key))\s*=\s*`"[^`"]*`""
    $replacement = "$Key = `"$Value`""
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, $replacement, 1)
    }
    return "$replacement`r`n$Text"
}

function Read-CodexRelaySnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $relay = [pscustomobject]@{
        Model = Get-CodexTomlValue -Text $text -Key 'model'
        BaseUrl = Get-CodexTomlValue -Text $text -Key 'base_url'
        WireApi = Get-CodexTomlValue -Text $text -Key 'wire_api'
        Token = Get-CodexTomlValue -Text $text -Key 'experimental_bearer_token'
    }
    foreach ($name in @('Model', 'BaseUrl', 'WireApi', 'Token')) {
        if (-not $relay.$name) { throw "Relay snapshot missing ${name}: $Path" }
    }
    $relay
}

function Get-CodexTomlValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $match = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key))\s*=\s*`"([^`"]*)`"")
    if (-not $match.Success) { return '' }
    $match.Groups[1].Value
}

function Set-CodexThreadProvider {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [string]$Model
    )

    if (-not (Test-Path -LiteralPath $script:CodexStatePath)) {
        Write-Warning "Thread database not found: $($script:CodexStatePath)"
        return
    }

    $python = Get-Command python -ErrorAction Stop
    $tempScript = Join-Path $env:TEMP ("codex-switch-threads-{0}.py" -f ([guid]::NewGuid().ToString('N')))
    $py = @'
import sqlite3, sys
db, provider, model, now_ms = sys.argv[1:]
con = sqlite3.connect(db, timeout=30)
cur = con.cursor()
if model:
    cur.execute("update threads set model_provider=?, model=?, updated_at_ms=?", (provider, model, int(now_ms)))
else:
    cur.execute("update threads set model_provider=?, updated_at_ms=?", (provider, int(now_ms)))
print(cur.rowcount)
con.commit()
con.close()
'@
    Set-Content -LiteralPath $tempScript -Value $py -Encoding utf8
    try {
        $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        $modelArg = if ($Model) { $Model } else { '' }
        & $python.Source $tempScript $script:CodexStatePath $Provider $modelArg $nowMs
        if ($LASTEXITCODE -ne 0) { throw "Thread update failed with exit code $LASTEXITCODE." }
    }
    finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Get-CodexThreadSummary {
    if (-not (Test-Path -LiteralPath $script:CodexStatePath)) { return }
    $python = Get-Command python -ErrorAction Stop
    $tempScript = Join-Path $env:TEMP ("codex-switch-summary-{0}.py" -f ([guid]::NewGuid().ToString('N')))
    @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1], timeout=30)
for provider, model, count in con.execute("select model_provider, model, count(*) from threads group by 1, 2"):
    print(f"{provider}\t{model}\t{count}")
con.close()
'@ | Set-Content -LiteralPath $tempScript -Encoding utf8
    try {
        & $python.Source $tempScript $script:CodexStatePath | ForEach-Object {
            $parts = $_ -split "`t"
            if ($parts.Count -ge 3) {
                [pscustomobject]@{ Provider = $parts[0]; Model = $parts[1]; Count = [int]$parts[2] }
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Stop-CodexDesktop {
    $namePattern = '^(ChatGPT|codex|codex-code-mode-host|codex-computer-use-swift)$'
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $namePattern })
    if ($procs.Count -eq 0) { return }
    $names = ($procs | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
    Write-Host "Closing running Codex processes: $names"
    $procs | Stop-Process -Force
    Start-Sleep -Seconds 1
}

function Assert-CodexTomlValid {
    param([Parameter(Mandatory = $true)][string]$Path)

    $python = Get-Command python -ErrorAction Stop
    $code = "import pathlib,tomllib; tomllib.loads(pathlib.Path(r'$Path').read_text(encoding='utf-8'))"
    & $python.Source -c $code
    if ($LASTEXITCODE -ne 0) { throw "Invalid TOML: $Path" }
}

function Get-CodexConfigText {
    if (-not (Test-Path -LiteralPath $script:CodexConfigPath)) {
        throw "Missing config: $($script:CodexConfigPath)"
    }
    Get-Content -LiteralPath $script:CodexConfigPath -Raw -Encoding utf8
}

function Set-CodexConfigText {
    param([Parameter(Mandatory = $true)][string]$Text)
    Set-Content -LiteralPath $script:CodexConfigPath -Value $Text -Encoding utf8NoBOM
}

function New-CodexSwitchBackup {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $script:CodexBackupDir $stamp
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -LiteralPath $script:CodexConfigPath -Destination (Join-Path $backupDir 'config.toml') -Force
    if (Test-Path -LiteralPath $script:CodexAuthPath) {
        Copy-Item -LiteralPath $script:CodexAuthPath -Destination (Join-Path $backupDir 'auth.json') -Force
    }
    if (Test-Path -LiteralPath $script:CodexStatePath) {
        Copy-Item -LiteralPath $script:CodexStatePath -Destination (Join-Path $backupDir 'state_5.sqlite') -Force
    }
    $backupDir
}

function Restore-CodexSwitchBackup {
    param([Parameter(Mandatory = $true)][string]$BackupDir)

    Copy-Item -LiteralPath (Join-Path $BackupDir 'config.toml') -Destination $script:CodexConfigPath -Force
    $backupAuth = Join-Path $BackupDir 'auth.json'
    if (Test-Path -LiteralPath $backupAuth) {
        Copy-Item -LiteralPath $backupAuth -Destination $script:CodexAuthPath -Force
    }
    elseif (Test-Path -LiteralPath $script:CodexAuthPath) {
        Remove-Item -LiteralPath $script:CodexAuthPath -Force
    }
}






function Test-CodexTargetActive {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Current
    )

    if ($Target -eq 'openai') {
        return $Current.Provider -eq 'openai'
    }

    $relay = Read-CodexRelaySnapshot -Path (Join-Path $script:CodexRelayDir ($Target + '.toml'))
    $text = Get-Content -LiteralPath $script:CodexConfigPath -Raw -Encoding utf8
    $baseUrl = Get-CodexTomlValue -Text $text -Key 'base_url'
    return $Current.Provider -eq 'custom' -and $Current.Model -eq $relay.Model -and $baseUrl -eq $relay.BaseUrl
}

function codex-switch {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )

    $tokens = @($Args | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tokens.Count -eq 0 -or $tokens[0] -in @('status', '--status', '--satus', '-Status', '-satus')) {
        Get-CodexProvider | Format-List
        Write-Host 'Relays:'
        Get-ChildItem -LiteralPath $script:CodexRelayDir -Filter '*.toml' -ErrorAction SilentlyContinue |
            ForEach-Object { '  ' + $_.BaseName }
        return
    }

    if ($tokens.Count -ge 2 -and $tokens[0] -eq 'auth' -and $tokens[1] -eq 'save') {
        Save-CodexAuth
        return
    }

    if ($tokens.Count -ne 1) {
        throw 'Usage: cxs [--status] | cxs openai | cxs <relay> | cxs auth save'
    }

    Switch-Codex -Target $tokens[0]
}

Set-Alias -Name cxs -Value codex-switch -Scope Global -Force
