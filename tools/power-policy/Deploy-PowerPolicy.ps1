# Installs from an elevated process and writes a reviewable completion record.
$ErrorActionPreference='Stop'
$directory=Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox'
$null=New-Item -ItemType Directory -Path $directory -Force
$resultPath=Join-Path $directory 'power-policy-deploy-result.json'
$transcriptPath=Join-Path $directory 'power-policy-deploy.log'
$transcribing=$false
try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    $transcribing=$true
    & (Join-Path $PSScriptRoot 'Install-PowerPolicy.ps1')
    if ($LASTEXITCODE -ne 0) { throw "安装失败，退出码 $LASTEXITCODE" }
    @{success=$true;updatedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding utf8
} catch {
    @{success=$false;error=$_.Exception.Message;updatedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding utf8
    throw
} finally { if ($transcribing) { Stop-Transcript | Out-Null } }
