# Builds into a fresh isolated directory; never replaces production helpers.
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'ManagedBuild.Core.ps1')
if(-not $OutputDirectory){$OutputDirectory=Join-Path $repo ('.tmp\managed-builds\'+[guid]::NewGuid().ToString('N'))}
$OutputDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $output){throw 'Build output must be a new directory (production files are never overwritten)'}
[void][IO.Directory]::CreateDirectory($output)
$compiler=Resolve-ToolboxFrameworkCompiler
$components=@()
foreach($component in @(
    @{Name='anchor-locator';Source='shared\notify\AnchorLocator.cs';References=@('UIAutomationClient','UIAutomationTypes','WindowsBase')},
    @{Name='audio-switcher';Source='tools\audio-switcher\AudioSwitcher.cs';References=@()}
)){
    $source=Join-Path $repo $component.Source
    $before=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $binary=Join-Path $output ($component.Name+'.exe')
    $references=@(foreach($name in $component.References){
        $file=Resolve-ToolboxFrameworkAssembly $name
        [pscustomobject]@{Name=$name;Path=$file;Sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
    })
    $arguments=@('/nologo','/optimize+','/target:exe',('/out:'+$binary))
    $arguments+=@($references | ForEach-Object {'/r:'+ $_.Path})
    $arguments+=$source
    & $compiler @arguments
    if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $binary -PathType Leaf)){throw "Compilation failed: $($component.Name)"}
    if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $before){throw 'Source changed while compiling; discard this build'}
    $components+=[pscustomobject]@{Name=$component.Name;SourcePath=$component.Source;SourceSha256=$before;OutputPath=[IO.Path]::GetFileName($binary);OutputSha256=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash;Arguments=$arguments;References=$references;RuntimeTest=$(if($component.Name -eq 'anchor-locator'){'geometry/protocol self-test'}else{'controls parser self-test; no device access'})}
}
# Both switches run synthetic data only: no UIA lookup or audio device access.
foreach($probe in @(
    @{Name='anchor-locator';Arguments='--self-test'},
    @{Name='audio-switcher';Arguments='--controls-self-test'}
)){
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path $output ($probe.Name+'.exe');$info.Arguments=$probe.Arguments
$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$process=[Diagnostics.Process]::Start($info)
$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
try {
    if(-not $process.WaitForExit(15000)){$process.Kill();throw "$($probe.Name) self-test timed out"}
    if($process.ExitCode -ne 0){throw "$($probe.Name) self-test failed: $($stdout.Result) $($stderr.Result)"}
} finally {$process.Dispose()}
}
$head='unavailable'
if(Get-Command git.exe -ErrorAction SilentlyContinue){$value=& git.exe -C $repo rev-parse HEAD 2>$null;if($LASTEXITCODE -eq 0){$head=[string]$value}}
$manifest=[ordered]@{Version=1;CreatedUtc=[DateTime]::UtcNow.ToString('o');GitHead=$head;SourceIdentity='exact file hashes; Git HEAD alone does not identify a dirty working tree';Compiler=@{Path=$compiler;Sha256=(Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash;Version=[Diagnostics.FileVersionInfo]::GetVersionInfo($compiler).FileVersion};Components=$components}
$manifestPath=Join-Path $output 'managed-build.json'
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
Test-ToolboxManagedBuild -RepoRoot $repo -ManifestPath $manifestPath | ConvertTo-Json -Depth 4
