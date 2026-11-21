$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ManagedBuild.Core.ps1')
function Assert($Value,$Label){if(-not $Value){throw "FAIL: $Label"}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('toolbox-build-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $root 'repo';$out=Join-Path $root 'out'
[void][IO.Directory]::CreateDirectory($out)
$components=@()
foreach($item in @(@{Name='anchor-locator';Path='shared\notify\AnchorLocator.cs'},@{Name='audio-switcher';Path='tools\audio-switcher\AudioSwitcher.cs'})){
    $source=Join-Path $repo $item.Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($source))
    [IO.File]::WriteAllText($source,'source fixture')
    $binary=Join-Path $out ($item.Name+'.exe')
    [IO.File]::WriteAllText($binary,'artifact fixture; never executed')
    $components+=[pscustomobject]@{Name=$item.Name;SourcePath=$item.Path;SourceSha256=(Get-FileHash $source).Hash;OutputPath=$item.Name+'.exe';OutputSha256=(Get-FileHash $binary).Hash}
}
$manifest=[pscustomobject]@{Version=1;Components=$components}
$path=Join-Path $out 'managed-build.json'
function Save-Fixture {[IO.File]::WriteAllText($path,($manifest | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))}
try {
    Save-Fixture
    Assert ((Test-ToolboxManagedBuild $repo $path).Status -eq 'verified') 'valid exact source/artifact pair verifies'
    $source=Join-Path $repo 'shared\notify\AnchorLocator.cs'
    [IO.File]::WriteAllText($source,'changed source')
    $failed=$false;try{Test-ToolboxManagedBuild $repo $path | Out-Null}catch{$failed=$_.Exception.Message -match 'source changed'}
    Assert $failed 'source drift invalidates provenance'
    [IO.File]::WriteAllText($source,'source fixture')
    $binary=Join-Path $out 'audio-switcher.exe'
    [IO.File]::WriteAllText($binary,'modified artifact')
    $failed=$false;try{Test-ToolboxManagedBuild $repo $path | Out-Null}catch{$failed=$_.Exception.Message -match 'artifact changed'}
    Assert $failed 'artifact drift invalidates provenance'
    [IO.File]::WriteAllText($binary,'artifact fixture; never executed')
    $manifest.Components=@($components[0],$components[0]);Save-Fixture
    $failed=$false;try{Test-ToolboxManagedBuild $repo $path | Out-Null}catch{$failed=$_.Exception.Message -match 'duplicate'}
    Assert $failed 'duplicate components cannot hide missing helper'
    $manifest.Components=$components;$manifest.Components[0].OutputPath='..\anchor-locator.exe';Save-Fixture
    $failed=$false;try{Test-ToolboxManagedBuild $repo $path | Out-Null}catch{$failed=$true}
    Assert $failed 'foreign artifact path is rejected'
    [Console]::Out.WriteLine('PASS: managed build provenance tests')
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
       [IO.Path]::GetFileName($resolved) -like 'toolbox-build-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
