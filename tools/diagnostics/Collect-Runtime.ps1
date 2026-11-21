# Read-only runtime snapshot. No starts, stops, task changes or panel commands.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repo)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $Repo 'tools\startup\Deployment.Runtime.ps1')
. (Join-Path $Repo 'tools\raycast-scripts\ocr\OcrHost.ps1')

function Resolve-GlobalPythonW {
    # Same search order as shared/python.ahk, for this command's environment.
    foreach($directory in $env:PATH.Split(';')) {
        if(-not $directory){continue}
        $candidate=Join-Path $directory.TrimEnd('\') 'pythonw.exe'
        if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
    }
    $local=$env:LOCALAPPDATA
    if(-not $local){$local=Join-Path $env:APPDATA '..\Local'}
    $candidate=Join-Path $local 'Programs\Python\Python312\pythonw.exe'
    if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
    foreach($file in @(Get-ChildItem (Join-Path $local 'Programs\Python\Python3*\pythonw.exe') -ErrorAction SilentlyContinue)) {
        return $file.FullName
    }
    foreach($root in @($env:SCOOP,(Join-Path $env:USERPROFILE 'scoop'),'D:\Applications\Scoop')) {
        if(-not $root){continue}
        foreach($relative in @('apps\python312\current\pythonw.exe','apps\python\current\pythonw.exe')) {
            $candidate=Join-Path $root $relative
            if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
        }
    }
    return $null
}

$result=@{residents=@{};globalPythonW=$null;ocr=$null}
try {$result.globalPythonW=Resolve-GlobalPythonW} catch {$result.globalError=$_.Exception.GetType().Name}
try {
    $spec=Get-OcrLaunchSpec -ModuleDirectory (Join-Path $Repo 'tools\raycast-scripts\ocr')
    if(-not $spec) {
        $command=Get-Command pythonw.exe -ErrorAction SilentlyContinue
        if(-not $command){$command=Get-Command pyw.exe -ErrorAction SilentlyContinue}
        if($command){$spec=@{Python=$command.Source;Kind='global';Prefix=@()}}
    }
    if($spec){$result.ocr=@{python=$spec.Python;kind=$spec.Kind;prefix=@($spec.Prefix)}}
} catch {$result.ocrError=$_.Exception.GetType().Name}

try {
    $processes=@(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
    $provider={ $processes }.GetNewClosure()
    $main=Join-Path $Repo 'ahk\main.ahk'
    $ahk=Get-ToolboxProcessSnapshot -MainScript $main -ProcessProvider $provider
    $matches=@($processes | Where-Object {$_.Name -like 'AutoHotkey*.exe' -and (Test-ToolboxMainScriptCommandLine $_.CommandLine $main)})
    $result.residents.ahk=@{status=$ahk.Status;pids=@($matches | ForEach-Object {[int]$_.ProcessId})}
    if($matches.Count -gt 1){$result.residents.ahk.status='ambiguous'}
    $hudPath=Join-Path $Repo 'tools\ime-hud-winui\out\ImeHudWinUi.exe'
    $hud=@($processes | Where-Object {$_.ExecutablePath -ieq $hudPath})
    Initialize-ToolboxHudProbe
    $hudStatus='query-failed'
    if($hud.Count -eq 1){$hudStatus=if([ToolboxReleaseHudProbe]::Ping([int]$hud[0].ProcessId)){'running'}else{'unresponsive'}}
    elseif($hud.Count -gt 1){$hudStatus='ambiguous'}
    elseif(-not @($processes | Where-Object {$_.Name -eq 'ImeHudWinUi.exe' -and -not $_.ExecutablePath}).Count){$hudStatus='not-running'}
    $result.residents.hud=@{status=$hudStatus;pids=@($hud | ForEach-Object {[int]$_.ProcessId})}
    $caret=@($processes | Where-Object {
        $_.Name -eq 'powershell.exe' -and
        (Test-ToolboxScriptCommandLine $_.CommandLine (Join-Path $Repo 'shared\notify\caret-uia.ps1'))
    })
    $caretStatus='query-failed'
    if($matches.Count -eq 1 -and $caret.Count -eq 1 -and $caret[0].CommandLine -match ('(?:^|\s)-OwnerPid '+$matches[0].ProcessId+'(?:\s|$)')){$caretStatus='running'}
    elseif($caret.Count -gt 1){$caretStatus='ambiguous'}
    elseif(-not $caret.Count -and -not @($processes | Where-Object {$_.Name -eq 'powershell.exe' -and -not $_.CommandLine}).Count){$caretStatus='not-running'}
    $result.residents.caret=@{status=$caretStatus;pids=@($caret | ForEach-Object {[int]$_.ProcessId})}
} catch {
    # A failed query never proves absence. Do not export exceptions/command lines.
    foreach($name in @('ahk','hud','caret')) {
        if(-not $result.residents.ContainsKey($name)){$result.residents[$name]=@{status='query-failed';errorType=$_.Exception.GetType().Name}}
    }
    if((Get-ToolboxInstanceMarkerState (Join-Path $Repo 'ahk\main.ahk')) -eq 'present') {
        $result.residents.ahk=@{status='running';pids=@();evidence='instance-marker'}
    }
}
# An injected process list disables the helper's default heartbeat. Supply it
# explicitly so inaccessible elevated command lines cannot hide a healthy beat.
$heartbeat={
    $path=Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\power-policy-status.json'
    if(Test-Path -LiteralPath $path -PathType Leaf){Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json}
}
try {
    if(-not $provider){$provider={throw 'Process query unavailable'}}
    $power=Get-ToolboxPowerPolicySnapshot -PowerScript (Join-Path $Repo 'tools\power-policy\PowerPolicy.ps1') -ProcessProvider $provider -HeartbeatProvider $heartbeat
    $result.residents.powerPolicy=@{status=$power.Status;pids=@($power.ProcessIds)}
    if($power.PSObject.Properties['Evidence']){$result.residents.powerPolicy.evidence=$power.Evidence}
} catch {$result.residents.powerPolicy=@{status='query-failed';errorType=$_.Exception.GetType().Name}}
$result | ConvertTo-Json -Depth 6 -Compress
