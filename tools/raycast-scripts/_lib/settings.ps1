# Fixed, read-only entry policy and shared script options. No Python dependency, commands or secret values.
$script:RaycastCommands=@('screenshot','record-screen','screenshot-ocr','screenshot-translate','next-wallpaper','toggle-rgb')
$script:RaycastMaintenance=@('restart-autohotkey','reload-ime-hud','diagnose-ime-hud-anchor','fix-rdp-clipboard-prompt')
# Choice keys keep their defaults here and in configuration_schema.py in sync.
$script:RaycastChoices=@{
    'notify.mode'=@('success','failure','silent')
    'diagnostics.scope'=@('brief','full')
}
$script:RaycastDefaults=@{'notify.mode'='success';'diagnostics.scope'='full'}

function Get-ToolboxRaycastSettings {
    param([string]$RepoRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))))
    $values=@{'general.enabled'=$true}
    foreach($name in $script:RaycastCommands){$values['commands.'+$name.Replace('-','_')]=$true}
    foreach($name in $script:RaycastMaintenance){$values['maintenance.'+$name.Replace('-','_')]=$true}
    foreach($key in $script:RaycastDefaults.Keys){$values[$key]=$script:RaycastDefaults[$key]}
    $path=Join-Path $RepoRoot 'tools\raycast-scripts\config.toml'
    try {
        if(Test-Path -LiteralPath $path -PathType Leaf){
            $stream=[IO.File]::OpenRead($path)
            try {
                if($stream.Length -gt 16384){return $null}
                $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
                try {
                    $buffer=[char[]]::new(16385);$count=$reader.ReadBlock($buffer,0,16385)
                    if($count -gt 16384){return $null};$text=[string]::new($buffer,0,$count)
                } finally {$reader.Dispose()}
            } finally {$stream.Dispose()}
            $section='';$seen=@{};$sections=@{}
            foreach($line in ($text -split '\r?\n')){
                if($line -match '^\s*(?:#.*)?$'){continue}
                if($line -cmatch '^\s*\[(general|commands|maintenance|notify|diagnostics)\]\s*(?:#.*)?$'){
                    $section=$Matches[1]
                    if($sections.ContainsKey($section)){return $null}
                    $sections[$section]=$true;continue
                }
                if($line -cnotmatch '^\s*([a-z_]+)\s*=\s*(true|false|"[^"]*")\s*(?:#.*)?$'){return $null}
                $key=$section+'.'+$Matches[1];$raw=$Matches[2]
                if(-not $values.ContainsKey($key) -or $seen.ContainsKey($key)){return $null}
                if($script:RaycastChoices.ContainsKey($key)){
                    if($raw -cnotmatch '^"([^"]*)"$'){return $null}
                    $choice=$Matches[1]
                    if($choice -cnotin $script:RaycastChoices[$key]){return $null}
                    $values[$key]=$choice
                } else {
                    if($raw -cnotin @('true','false')){return $null}
                    $values[$key]=($raw -ceq 'true')
                }
                $seen[$key]=$true
            }
        }
        return $values
    } catch {return $null}
}

function Test-ToolboxRaycastCommandEnabled {
    param([Parameter(Mandatory=$true)][string]$Command,
          [string]$RepoRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))))
    if($Command -cnotin ($script:RaycastCommands+$script:RaycastMaintenance)){return $false}
    $settings=Get-ToolboxRaycastSettings -RepoRoot $RepoRoot
    if($null -eq $settings){return $false}
    if($Command -ceq 'reload-ime-hud' -and -not $settings['maintenance.restart_autohotkey']){return $false}
    $group=if($Command -cin $script:RaycastCommands){'commands.'}else{'maintenance.'}
    return ($settings['general.enabled'] -and $settings[$group+$Command.Replace('-','_')])
}

function Get-ToolboxRaycastNotifyMode {
    param([string]$RepoRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))))
    $settings=Get-ToolboxRaycastSettings -RepoRoot $RepoRoot
    if($null -eq $settings){return 'success'}
    return [string]$settings['notify.mode']
}

function Get-ToolboxRaycastDiagnosticScope {
    param([string]$RepoRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))))
    $settings=Get-ToolboxRaycastSettings -RepoRoot $RepoRoot
    if($null -eq $settings){return 'full'}
    return [string]$settings['diagnostics.scope']
}
