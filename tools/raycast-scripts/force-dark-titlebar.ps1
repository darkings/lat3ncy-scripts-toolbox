#!/usr/bin/env pwsh
# @raycast.schemaVersion 1
# @raycast.title Force Dark Titlebar (configured windows)
# @raycast.mode silent
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Apply the configured titlebar style once to matching visible windows

# Defaults come from theme-scheduler/config.toml [titlebar].
# -Light/-Reset and -ProcessNames remain explicit one-shot overrides.
# Reset applies the current system color once; it does not establish a watcher.
# ASCII only for Windows PowerShell 5.1.
[CmdletBinding()]
param([switch]$Light,[switch]$Reset,[switch]$Silent,[string[]]$ProcessNames)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '_lib\notify.ps1')
. (Join-Path $PSScriptRoot '_lib\TitlebarSupport.ps1')
try {
    $arguments=@{Repo=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)}
    if($Reset){$arguments.Mode='system'}elseif($Light){$arguments.Mode='light'}
    if($PSBoundParameters.ContainsKey('ProcessNames')){$arguments.ProcessNames=$ProcessNames}
    $result=Invoke-ToolboxTitlebar @arguments
    if($Silent){return}
    $message=switch($result.status){
        applied { 'Applied and verified on '+$result.applied+' window(s).' }
        disabled { 'Titlebar styling or the theme module is disabled.' }
        no_windows { 'No matching visible window. Open the configured app and retry.' }
        default { 'Some windows could not be applied or verified. Applied='+$result.applied+'; failed='+$result.failed }
    }
    Show-SystemToast -Title 'Toolbox titlebar style' -Message $message | Out-Null
    if($result.status -notin @('applied','disabled')){exit 1}
} catch {
    if($Silent){exit 0}
    Show-SystemToast -Title 'Toolbox titlebar style' -Message 'Unable to apply. Check the configured process names and app permissions.' | Out-Null
    exit 1
}
