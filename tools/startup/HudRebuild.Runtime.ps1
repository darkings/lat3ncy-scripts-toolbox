# Build into a unique work directory; no production writes happen here.
. (Join-Path $PSScriptRoot '..\ime-hud-winui\BuildSupport.ps1')
. (Join-Path $PSScriptRoot '..\build\ManagedBuild.Core.ps1')
. (Join-Path $PSScriptRoot 'Deployment.Runtime.ps1')

function New-ToolboxHudCandidate {
    param([string]$Repo,[string]$Work)
    $project=Join-Path $Repo 'tools\ime-hud-winui'
    $hudSource=Get-ImeHudSourceHash $project
    $anchorSource=(Get-FileHash -LiteralPath (Join-Path $Repo 'shared\notify\AnchorLocator.cs') -Algorithm SHA256).Hash
    $managed=Join-Path $Work 'managed'
    & (Join-Path $Repo 'tools\build\Build-ManagedHelpers.ps1') -OutputDirectory $managed -Component anchor-locator | Out-Null
    $null=Test-ToolboxManagedBuild -RepoRoot $Repo -ManifestPath (Join-Path $managed 'managed-build.json') -ExpectedComponents anchor-locator
    $bundle=Join-Path $Work 'bundle'
    $hud=Join-Path $bundle 'tools\ime-hud-winui\out'
    [void][IO.Directory]::CreateDirectory($hud)
    Invoke-ImeHudBuild -ProjectDir $project -OutDir $hud | Out-Null
    if($hudSource -cne (Get-ImeHudSourceHash $project) -or
        $anchorSource -cne (Get-FileHash -LiteralPath (Join-Path $Repo 'shared\notify\AnchorLocator.cs') -Algorithm SHA256).Hash){
        throw 'HUD/anchor source changed during build'
    }
    $anchor=Join-Path $bundle 'shared\notify\anchor-locator.exe'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($anchor))
    [IO.File]::Copy((Join-Path $managed 'anchor-locator.exe'),$anchor)
    # Recheck provenance after copying, including the source/helper pair.
    $null=Test-ToolboxManagedBuild -RepoRoot $Repo -ManifestPath (Join-Path $managed 'managed-build.json') -ExpectedComponents anchor-locator
    $provenance=Get-Content -LiteralPath (Join-Path $managed 'managed-build.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if((Get-FileHash -LiteralPath $anchor -Algorithm SHA256).Hash -cne $provenance.Components[0].OutputSha256){
        throw 'Copied anchor differs from managed provenance'
    }
    $candidate=[ordered]@{Version=1;Repo=[IO.Path]::GetFullPath($Repo);HudSource=$hudSource;
        AnchorSource=$anchorSource;Files=@(Get-ToolboxHudBundleFiles $bundle)}
    [IO.File]::WriteAllText((Join-Path $Work 'candidate.json'),($candidate | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
}

function Test-ToolboxHudExecutables {
    param([string]$Root)
    Invoke-ToolboxReleaseProcess (Join-Path $Root 'shared\notify\anchor-locator.exe') @('--self-test')
    Invoke-ToolboxReleaseProcess (Join-Path $Root 'tools\ime-hud-winui\out\ImeHudWinUi.exe') @('--self-test')
}
