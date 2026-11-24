# Read-only control flags. Never run commands from the per-checkout JSON file.
function Test-ToolboxModuleEnabled {
    param([Parameter(Mandatory=$true)][string]$Module,
          [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
    $modules=@('translate','tts','ocr','audio','theme','power','rgb','capture')
    if($Module -notin $modules){return $false}
    $path=Join-Path $RepoRoot '.toolbox-controls.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $true}
    try {
        $stream=[IO.File]::OpenRead($path)
        try {
            if($stream.Length -gt 16384){return $false}
            if($stream.Length -eq 0){return $true}
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
            try{
                $buffer=[char[]]::new(16385)
                $count=$reader.ReadBlock($buffer,0,16385)
                if($count -gt 16384){return $false}
                $text=[string]::new($buffer,0,$count)
            }finally{$reader.Dispose()}
        }finally{$stream.Dispose()}
        $data=ConvertFrom-Json -InputObject $text -ErrorAction Stop
        if($null -eq $data -or $data -is [Array] -or $data.version -ne 1 -or
            ($data.version -isnot [int] -and $data.version -isnot [long])){return $false}
        $features=@('CapsLockIme','SpeakSelectedText','TranslateSelectedText','ScreenshotTranslate','SearchSelectedText',
            'OpenSelectedTarget','LocateSelectedTarget','AlwaysOnTop','HideActiveWindow','ToggleHiddenFiles','ToggleDotfiles',
            'ToggleFileExtensions','AudioSwitcher','KillForegroundProcess','RestartForegroundProcess','SmartPaste',
            'SwitchAppWindowNext','SwitchAppWindowPrevious','VsCodeCopyPath','ZedCopyPath','ThinkPadBacklight','CaffeineIndicator','FindMouse')
        $allowed=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        $allowed.Add('version','number');$allowed.Add('tray_visible','bool')
        foreach($name in $modules){$allowed.Add(('module_'+$name+'_enabled'),'bool')}
        foreach($name in $features){
            $allowed.Add(('feature_'+$name+'_enabled'),'bool')
            if($name -notin @('ThinkPadBacklight','CaffeineIndicator','FindMouse')){
                $allowed.Add(('hotkey_'+$name+'_enabled'),'bool');$allowed.Add(('binding_'+$name),'string')
            }
        }
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $keyMatches=[regex]::Matches($text,'"([A-Za-z_][A-Za-z0-9_]*)"\s*:')
        foreach($match in $keyMatches){if(-not $names.Add($match.Groups[1].Value)){return $false}}
        if($keyMatches.Count -ne @($data.PSObject.Properties).Count){return $false}
        foreach($property in $data.PSObject.Properties){
            if(-not $allowed.ContainsKey($property.Name)){return $false}
            if($allowed[$property.Name] -eq 'bool' -and $property.Value -isnot [bool]){return $false}
            if($allowed[$property.Name] -eq 'string' -and ($property.Value -isnot [string] -or $property.Value.Length -gt 80 -or $property.Value -match '[\x00-\x1F]')){return $false}
        }
        $entry=@($data.PSObject.Properties | Where-Object {$_.Name -ceq ('module_'+$Module+'_enabled')})
        return ($entry.Count -eq 0 -or $entry[0].Value -eq $true)
    }catch{return $false}
}
