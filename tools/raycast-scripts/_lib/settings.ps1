# Fixed, read-only entry policy. No Python dependency, commands or secret values.
function Test-ToolboxRaycastCommandEnabled {
    param([Parameter(Mandatory=$true)][string]$Command,
          [string]$RepoRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))))
    $commands=@('screenshot','record-screen','screenshot-ocr','screenshot-translate','next-wallpaper','toggle-rgb')
    $maintenance=@('restart-autohotkey','reload-ime-hud','diagnose-ime-hud-anchor','fix-rdp-clipboard-prompt')
    if($Command -cnotin ($commands+$maintenance)){return $false}
    $values=@{'general.enabled'=$true}
    foreach($name in $commands){$values['commands.'+$name.Replace('-','_')]=$true}
    foreach($name in $maintenance){$values['maintenance.'+$name.Replace('-','_')]=$true}
    $path=Join-Path $RepoRoot 'tools\raycast-scripts\config.toml'
    try {
        if(Test-Path -LiteralPath $path -PathType Leaf){
            $stream=[IO.File]::OpenRead($path)
            try {
                if($stream.Length -gt 16384){return $false}
                $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
                try {
                    $buffer=[char[]]::new(16385);$count=$reader.ReadBlock($buffer,0,16385)
                    if($count -gt 16384){return $false};$text=[string]::new($buffer,0,$count)
                } finally {$reader.Dispose()}
            } finally {$stream.Dispose()}
            $section='';$seen=@{};$sections=@{}
            foreach($line in ($text -split '\r?\n')){
                if($line -match '^\s*(?:#.*)?$'){continue}
                if($line -cmatch '^\s*\[(general|commands|maintenance)\]\s*(?:#.*)?$'){
                    $section=$Matches[1];if($sections.ContainsKey($section)){return $false};$sections[$section]=$true;continue
                }
                if($line -cnotmatch '^\s*([a-z_]+)\s*=\s*(true|false)\s*(?:#.*)?$'){return $false}
                $key=$section+'.'+$Matches[1];$value=$Matches[2]
                if(-not $values.ContainsKey($key) -or $seen.ContainsKey($key)){return $false}
                $seen[$key]=$true;$values[$key]=($value -ceq 'true')
            }
        }
        $group=if($Command -cin $commands){'commands.'}else{'maintenance.'}
        if($Command -ceq 'reload-ime-hud' -and -not $values['maintenance.restart_autohotkey']){return $false}
        return ($values['general.enabled'] -and $values[$group+$Command.Replace('-','_')])
    } catch {return $false}
}
