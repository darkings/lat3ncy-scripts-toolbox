. "$PSScriptRoot\DshRemoteUtils.ps1"
$rawHost = Get-TailscaleHostname
$rawServe = Get-TailscaleServeStatus
Write-Host "rawHost='$rawHost'"
Write-Host "rawServe='$rawServe'"
Write-Host "rawHost eq? $($rawHost -eq '__ACCESS_DENIED__')"
Write-Host "rawServe eq? $($rawServe -eq '__ACCESS_DENIED__')"
Write-Host "IsAdmin: $(Test-IsAdmin)"
Write-Host "accessDenied: $($rawHost -eq '__ACCESS_DENIED__' -or $rawServe -eq '__ACCESS_DENIED__')"
