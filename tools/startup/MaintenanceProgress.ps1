# Fixed maintenance progress writer. No free-form text, paths or secrets are exported.
$script:MaintenanceStages=@('build','verify','deploy','restore')
$script:MaintenanceResults=@('running','succeeded','failed','cancelled')

function Get-MaintenanceStateDirectory {
    param([string]$Repo)
    return (Join-Path ([IO.Path]::GetFullPath($Repo)) '.toolbox-state')
}

function Write-MaintenanceProgress {
    param([string]$Stage,[string]$Result,[string]$Record='',[string]$Failure='',
          [string]$Repo=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
    if($Stage -cnotin $script:MaintenanceStages -or $Result -cnotin $script:MaintenanceResults){throw 'Invalid maintenance progress'}
    if($Record.Length -gt 128 -or $Failure.Length -gt 128){throw 'Invalid maintenance progress'}
    $dir=Get-MaintenanceStateDirectory $Repo
    [void][IO.Directory]::CreateDirectory($dir)
    $path=Join-Path $dir 'maintenance-progress.json'
    $doc=[ordered]@{version=1;stage=$Stage;result=$Result;updated_utc=[DateTime]::UtcNow.ToString('o');record=$Record;failure=$Failure}
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($doc|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}
        else{[IO.File]::Move($temporary,$path)}
    } finally {if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Test-MaintenanceCancelRequested {
    param([string]$Repo=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
    return (Test-Path -LiteralPath (Join-Path (Get-MaintenanceStateDirectory $Repo) 'maintenance-cancel.flag') -PathType Leaf)
}

function Clear-MaintenanceCancel {
    param([string]$Repo=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
    $path=Join-Path (Get-MaintenanceStateDirectory $Repo) 'maintenance-cancel.flag'
    if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force}
}
