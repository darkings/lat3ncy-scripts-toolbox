# Execute production entries with isolated providers; never writes Windows state.
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('toolbox-theme-entry-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert($Value,$Label){if(-not $Value){throw "FAIL: $Label"}}
try {
    foreach($leaf in @('Light','Dark')) {
        Copy-Item -LiteralPath (Join-Path $source "Set-Theme-$leaf.ps1") -Destination $fixture
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'ThemeUtils.ps1'),@'
function Get-ThemeConfig {
    @{general=@{switch_type='mode';show_notification=$global:ThemeEntryState.Show}}
}
function Test-ThemeFeatureEnabled { return $global:ThemeEntryState.Enabled }
function Get-ThemePersonalizeState {
    $value=if($global:ThemeEntryState.Reads++ -eq 0){$global:ThemeEntryState.Before}else{$global:ThemeEntryState.After}
    @{AppsUseLightTheme=$value;SystemUsesLightTheme=$value}
}
function Set-WindowsColorMode { param($Mode,$Config) $global:ThemeEntryState.Writes++ }
function Invoke-ThemeNotify {
    param($Type,$Icon,$Text)
    $global:ThemeEntryState.Notifications+=@([pscustomobject]@{Icon=$Icon;Text=$Text})
}
function Start-ThemeTail { param($Mode) $global:ThemeEntryState.Tails++; return $true }
function Write-ThemeLog { param($Text) }
'@,[Text.Encoding]::ASCII)
    foreach($mode in @('Light','Dark')) {
        $after=if($mode -eq 'Light'){1}else{0}
        foreach($show in @($true,$false)) {
            foreach($changed in @($true,$false)) {
                $global:ThemeEntryState=[pscustomobject]@{
                    Before=$(if($changed){1-$after}else{$after});After=$after;Reads=0
                    Show=$show;Notifications=@();Tails=0;Enabled=$true;Writes=0
                }
                $output=@(& (Join-Path $fixture "Set-Theme-$mode.ps1") -Force 2>&1)
                Assert (@($output | Where-Object {$_ -is [Management.Automation.ErrorRecord]}).Count -eq 0) "$mode entry has no errors"
                Assert ($global:ThemeEntryState.Tails -eq [int]$changed) "$mode tail only runs after change"
                $expected=if($changed -and $show){1}else{0}
                Assert ($global:ThemeEntryState.Notifications.Count -eq $expected) "$mode notification respects setting/change"
                if($expected) {
                    $icon=$global:ThemeEntryState.Notifications[0].Icon
                    $wanted=if($mode -eq 'Dark'){[char]::ConvertFromUtf32(0x1F319)}else{[string][char]0x2600+[string][char]0xFE0F}
                    Assert ($icon -ceq $wanted) "$mode complete Unicode icon"
                }
            }
        }
    }
    $global:ThemeEntryState=[pscustomobject]@{Before=0;After=1;Reads=0;Writes=0;Show=$true;Notifications=@();Tails=0;Enabled=$false}
    $null=& (Join-Path $fixture 'Set-Theme-Light.ps1') -Force
    Assert ($global:ThemeEntryState.Reads -eq 0 -and $global:ThemeEntryState.Writes -eq 0 -and $global:ThemeEntryState.Tails -eq 0) 'disabled theme performs no color reads/writes or tail launch'
    [Console]::Out.WriteLine('PASS: isolated light/dark notification, disabled policy and tail entries')
} finally {
    # Only remove this test's verified, randomly named temp directory.
    $full=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($full.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and
       [IO.Path]::GetFileName($full) -match '^toolbox-theme-entry-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
    Remove-Variable ThemeEntryState -Scope Global -ErrorAction SilentlyContinue
}
