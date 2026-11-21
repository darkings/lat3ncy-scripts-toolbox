$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ToolboxProcess.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('toolbox-lease-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null
try {
    $main=Join-Path $root 'checkout\ahk\main.ahk'
    $other=Join-Path $root 'other\ahk\main.ahk'
    $name=(Get-ToolboxInstanceName $main)+'-Deployment'
    $ready=Join-Path $root 'ready'
    $script=Join-Path $root 'holder.ps1'
    [IO.File]::WriteAllText($script,@'
param($Name,$Ready)
$mutex=[Threading.Mutex]::new($true,$Name)
try {[IO.File]::WriteAllText($Ready,'ready');Start-Sleep -Seconds 30}
finally {$mutex.ReleaseMutex();$mutex.Dispose()}
'@)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,$name,$ready) |
        ForEach-Object {ConvertTo-ToolboxCommandLineArgument $_}) -join ' '
    $child=[Diagnostics.Process]::Start($info)
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    while(-not(Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    if(-not(Test-Path $ready)){throw 'Lease holder did not start'}
    if((Get-ToolboxDeploymentState $main) -ne 'active'){throw 'Active deployment lease not detected'}
    if((Get-ToolboxDeploymentState $other) -ne 'idle'){throw 'Lease leaked across checkouts'}
    $child.Kill();$null=$child.WaitForExit(5000)
    if((Get-ToolboxDeploymentState $main) -ne 'idle'){throw 'Crashed deployer left a stale lease'}
    [Console]::Out.WriteLine('PASS: deployment lease isolation and crash cleanup')
} finally {
    if($child){if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
       [IO.Path]::GetFileName($resolved) -like 'toolbox-lease-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
