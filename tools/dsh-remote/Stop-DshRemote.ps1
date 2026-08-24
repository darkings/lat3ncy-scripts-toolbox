# Stop-DshRemote.ps1
# 关闭 Tailscale Serve 暴露（自动 sudo 提权）

param([switch]$Json, [switch]$NoNotify)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DshRemoteUtils.ps1')
$cfg = Get-DshRemoteConfig
$httpsPort = if ($cfg.server.https_port) { [int]$cfg.server.https_port } else { 443 }
$relayEnabled = $true
if ($null -ne $cfg.relay.enabled) { $relayEnabled = [bool]$cfg.relay.enabled }
$relayPort = if ($cfg.relay.port) { [int]$cfg.relay.port } else { 3090 }

$r = Invoke-TailscaleServe -ServeArgs "--https=$httpsPort off"
$out = $r.Output
if (-not $Json) { Write-DshStep 'Disabling Tailscale Serve proxy'; $out | Out-Host; if ($out -notmatch "Access is denied") { Write-DshOK 'Serve disabled.' } else { Write-DshWarn 'Access denied - sudo elevation failed' } }
if ($relayEnabled) {
  $stoppedRelay = Stop-DshRelay -ListenPort $relayPort
  if (-not $Json -and $stoppedRelay -gt 0) { Write-DshOK "Local relay stopped ($stoppedRelay process)." }
}
if (-not $NoNotify) { Invoke-DshRemoteNotify -Type 'info' -Text 'Remote closed' }
if ($Json) {
  if ($out -match "Access is denied") { @{ ok = $false; error = 'access denied'; need_admin = $true } | ConvertTo-Json -Compress | Write-Output; exit 1 }
  @{ ok = $true; enabled = $false; relay_enabled = $relayEnabled; relay_port = $relayPort } | ConvertTo-Json -Compress | Write-Output
}
