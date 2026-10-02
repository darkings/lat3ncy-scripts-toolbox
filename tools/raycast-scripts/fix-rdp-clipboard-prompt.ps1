#!/usr/bin/env pwsh

# @raycast.schemaVersion 1
# @raycast.title Fix RDP Clipboard Prompt (admin)
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Roll back the April 2026 RDP redirection warning / clipboard isolation
# @raycast.icon 🔐

<#
Fixes the "remote desktop connection security warning" dialog that shows up on every
connection and keeps the clipboard checkbox unchecked.

Cause: the April 2026 Windows update added a redirection warning dialog plus default
permission isolation (clipboard, WebAuth, ...) whenever an .rdp file is opened.
Microsoft ships a rollback switch - this script sets it:

    HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client
        RedirectionWarningDialogVersion = 1     (1 = old behaviour, 0 = new warnings)

Must run elevated (HKLM write). Takes effect without a reboot; if the warning still
appears, reboot once and retest.

Reference: https://www.landian.news/archives/112693.html
(verify the value before/after with: Get-ItemProperty the key above)

ASCII only on purpose (PowerShell 5.1 parses BOM-less files as ANSI).
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')

trap {
  $cmdName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { 'Fix RDP Clipboard Prompt' }
  Show-SystemToast -Title "x $cmdName failed" -Message $_.Exception.Message | Out-Null
  exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  throw 'Needs administrator rights (writes HKLM). Re-run from an elevated shell.'
}

$policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client'
$valueName = 'RedirectionWarningDialogVersion'

if (-not (Test-Path -LiteralPath $policyKey)) {
  New-Item -Path $policyKey -Force | Out-Null
}
New-ItemProperty -Path $policyKey -Name $valueName -Value 1 -PropertyType DWord -Force | Out-Null

$applied = (Get-ItemProperty -Path $policyKey -Name $valueName).$valueName
if ($applied -ne 1) {
  throw ("policy write did not stick, read back: {0}" -f $applied)
}

# Drop the guess from an earlier attempt: the clipboard prompt is not controlled by
# fPromptForClipboardRedirection on the Windows 11 client.
foreach ($stale in @('fPromptForClipboardRedirection', 'fPromptForWebAuthRedirection')) {
  try {
    Remove-ItemProperty -Path $policyKey -Name $stale -ErrorAction Stop
  } catch { }
}

Show-SystemToast -Title 'OK RDP warning rolled back' -Message (
  "RedirectionWarningDialogVersion=1 written. Reconnect; if the warning is still there, reboot once."
) | Out-Null
