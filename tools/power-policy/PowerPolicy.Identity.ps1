# Read-only identity contract shared by the resident and unelevated watchdog.
# ASCII only for Windows PowerShell 5.1.
function Get-ToolboxPowerFingerprint {
    param([Parameter(Mandatory=$true)][string]$PowerScript)
    $root=Split-Path ([IO.Path]::GetFullPath($PowerScript)) -Parent
    $names=@([IO.Path]::GetFileName($PowerScript),'PowerPolicy.Core.ps1','PowerNative.cs','PowerPolicy.Identity.ps1','Repair-TaskHost.ps1','Run-PowerPolicy.vbs','config.toml','..\ToolboxControls.ps1')
    $lines=foreach($name in $names){
        $path=Join-Path $root $name
        if(Test-Path -LiteralPath $path -PathType Leaf){$digest=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash}
        else{$digest='missing'}
        "$name|$digest"
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$bytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))}finally{$sha.Dispose()}
    return (($bytes | ForEach-Object {$_.ToString('x2')}) -join '')
}

function Get-ToolboxPowerIdentity {
    param([Parameter(Mandatory=$true)][string]$PowerScript)
    $path=[IO.Path]::GetFullPath($PowerScript)
    $process=Get-Process -Id $PID -ErrorAction Stop
    try {
        return [ordered]@{
            identityVersion=1
            scriptPath=$path
            repoRoot=(Split-Path (Split-Path (Split-Path $path -Parent) -Parent) -Parent)
            startTicks=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
            sourceFingerprint=(Get-ToolboxPowerFingerprint -PowerScript $path)
            hostPath=$process.MainModule.FileName
        }
    } finally {$process.Dispose()}
}

function Get-ToolboxProcessStartIdentity {
    param([Parameter(Mandatory=$true)][int]$ProcessId)
    $errors=@()
    $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue -ErrorVariable errors
    if(-not $process){
        if($errors.Count -eq 0 -or $errors[0].CategoryInfo.Category -eq 'ObjectNotFound'){return [pscustomobject]@{Status='absent'}}
        return [pscustomobject]@{Status='unknown'}
    }
    try {
        if($process.HasExited){return [pscustomobject]@{Status='absent'}}
        return [pscustomobject]@{Status='present';Name=$process.ProcessName;StartTicks=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()}
    } catch {return [pscustomobject]@{Status='unknown'}}
    finally {$process.Dispose()}
}
