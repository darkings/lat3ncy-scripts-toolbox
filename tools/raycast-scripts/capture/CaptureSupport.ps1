# Shared, bounded configuration and per-mode capture sessions. No capture/UI work.
function Get-ToolboxCaptureOptions {
    param([ValidateSet('Screenshot','Record')][string]$Mode,
          [string]$Repo=(Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent))
    $sections=@{screenshot=@{enabled=$true;copy_to_clipboard=$true;wait_timeout_s=180;extra_directory=''};record=@{enabled=$true;copy_to_clipboard=$true;wait_timeout_s=1800;extra_directory=''}}
    $result=@{Valid=$true;Enabled=$false;CopyToClipboard=$true;WaitTimeoutSeconds=180;ExtraDirectory=''}
    try {
        $path=Join-Path $Repo 'tools\raycast-scripts\capture\config.toml'
        if(Test-Path -LiteralPath $path){
            if((Get-Item -LiteralPath $path).Length -gt 32768){throw 'capture-config-size'}
            $section='';$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($line in [IO.File]::ReadAllLines($path,[Text.Encoding]::UTF8)){
                if($line -match '^\s*(?:#.*)?$'){continue}
                if($line -cmatch '^\s*\[(screenshot|record)\]\s*(?:#.*)?$'){
                    $section=$Matches[1];if(-not $seen.Add('['+$section+']')){throw 'capture-duplicate'};continue
                }
                if(-not $section -or $line -cnotmatch '^\s*(enabled|copy_to_clipboard|wait_timeout_s|extra_directory)\s*=\s*(true|false|\d+|"(?:[^"\\]|\\.)*"|''[^'']*'')\s*(?:#.*)?$'){throw 'capture-config-syntax'}
                $key=$Matches[1];$literal=$Matches[2]
                if(-not $seen.Add($section+'.'+$key)){throw 'capture-duplicate'}
                if($literal.StartsWith("'")){$value=$literal.Substring(1,$literal.Length-2)}
                else{$value=ConvertFrom-Json -InputObject $literal -ErrorAction Stop}
                if($key -in @('enabled','copy_to_clipboard')){if($value -isnot [bool]){throw 'capture-config-type'}}
                elseif($key -eq 'wait_timeout_s'){
                    $minimum=if($section -eq 'record'){30}else{5};$maximum=if($section -eq 'record'){86400}else{3600}
                    if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $minimum -or $value -gt $maximum){throw 'capture-config-range'}
                }elseif($value -isnot [string] -or $value.Length -gt 2048 -or $value -match '[\x00-\x1F]'){throw 'capture-config-path'}
                $sections[$section][$key]=$value
            }
        }
        $options=$sections[$Mode.ToLowerInvariant()]
        . (Join-Path $Repo 'tools\ToolboxControls.ps1')
        $result.Enabled=$options.enabled -and (Test-ToolboxModuleEnabled -Module capture -RepoRoot $Repo)
        $result.CopyToClipboard=$options.copy_to_clipboard;$result.WaitTimeoutSeconds=$options.wait_timeout_s;$result.ExtraDirectory=$options.extra_directory
    }catch{$result.Valid=$false;$result.Enabled=$false}
    return $result
}
function Get-ToolboxCaptureSessionPath {
    param([string]$Repo,[ValidateSet('Screenshot','Record')][string]$Mode)
    return (Join-Path $Repo ('.toolbox-state\capture-'+$Mode.ToLowerInvariant()+'.json'))
}
function Invoke-ToolboxCaptureCommit {
    param([string]$Repo,[scriptblock]$Operation)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Repo).ToLowerInvariant()))}finally{$sha.Dispose()}
    $name='Local\ToolboxCaptureCommit-'+[BitConverter]::ToString($digest).Replace('-','')
    $mutex=[Threading.Mutex]::new($false,$name);$owned=$false
    try{
        try{$owned=$mutex.WaitOne(2000)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'capture-commit-busy'}
        return (& $Operation)
    }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function New-ToolboxCaptureSession {
    param([ValidateSet('Screenshot','Record')][string]$Mode,$Options,[string]$Repo)
    if(-not $Options.Valid -or -not $Options.Enabled){throw 'capture-disabled'}
    $now=[DateTime]::UtcNow
    $session=@{version=1;id=[guid]::NewGuid().ToString('N');mode=$Mode;startedUtc=$now.ToString('o');deadlineUtc=$now.AddSeconds($Options.WaitTimeoutSeconds).ToString('o');options=$Options}
    $path=Get-ToolboxCaptureSessionPath $Repo $Mode;$directory=Split-Path $path -Parent
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary=$path+'.'+$session.id+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,($session|ConvertTo-Json -Depth 4 -Compress),[Text.UTF8Encoding]::new($false))
        Invoke-ToolboxCaptureCommit $Repo {Move-Item -LiteralPath $temporary -Destination $path -Force}
    }
    finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    return $session
}
function Read-ToolboxCaptureSession {
    param([string]$Repo,[ValidateSet('Screenshot','Record')][string]$Mode,[string]$SessionId)
    try{
        $path=Get-ToolboxCaptureSessionPath $Repo $Mode
        if((Get-Item -LiteralPath $path -ErrorAction Stop).Length -gt 16384){return $null}
        $session=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if($session.version -ne 1 -or $session.id -cne $SessionId -or $SessionId -cnotmatch '^[0-9a-f]{32}$' -or $session.mode -cne $Mode){return $null}
        $start=[DateTime]::Parse($session.startedUtc).ToUniversalTime();$deadline=[DateTime]::Parse($session.deadlineUtc).ToUniversalTime()
        if($start -gt [DateTime]::UtcNow.AddSeconds(5) -or $deadline -le [DateTime]::UtcNow -or $deadline -gt $start.AddSeconds(86400)){return $null}
        $o=$session.options
        if($o.CopyToClipboard -isnot [bool] -or $o.ExtraDirectory -isnot [string] -or $o.ExtraDirectory.Length -gt 2048 -or $o.ExtraDirectory -match '[\x00-\x1F]'){return $null}
        return $session
    }catch{return $null}
}
function Test-ToolboxCaptureSession {
    param([string]$Repo,[ValidateSet('Screenshot','Record')][string]$Mode,[string]$SessionId)
    if($null -eq (Read-ToolboxCaptureSession $Repo $Mode $SessionId)){return $false}
    return (Get-ToolboxCaptureOptions $Mode $Repo).Enabled
}
function Start-ToolboxCaptureWatcher {
    param([string]$Repo,[ValidateSet('Screenshot','Record')][string]$Mode,[string]$SessionId)
    $watcher=Join-Path $Repo 'tools\raycast-scripts\capture\watch-save.ps1'
    # Only fixed script/mode and a validated GUID enter the command line.
    if($SessionId -cnotmatch '^[0-9a-f]{32}$'){throw 'capture-session-id'}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$watcher+'" -Mode '+$Mode+' -SessionId '+$SessionId
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info);$process.Dispose()
}
