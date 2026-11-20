# Build provenance only. Do not load or execute the assemblies being inspected.
function Resolve-ToolboxFrameworkCompiler {
    foreach($architecture in @('Framework64','Framework')){
        $path=Join-Path $env:SystemRoot "Microsoft.NET\$architecture\v4.0.30319\csc.exe"
        if(Test-Path -LiteralPath $path -PathType Leaf){return $path}
    }
    throw 'Windows .NET Framework csc.exe not found'
}

function Resolve-ToolboxFrameworkAssembly {
    param([string]$Name)
    $root=Join-Path $env:SystemRoot "Microsoft.NET\assembly\GAC_MSIL\$Name"
    $file=Get-ChildItem -LiteralPath $root -Filter "$Name.dll" -Recurse -ErrorAction Stop | Sort-Object FullName -Descending | Select-Object -First 1
    if(-not $file){throw "Framework reference not found: $Name"}
    return $file.FullName
}

function Get-ToolboxBuildFile {
    param([string]$Root,[string]$Relative)
    if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')){throw 'Invalid build manifest path'}
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $path=[IO.Path]::GetFullPath((Join-Path $prefix $Relative))
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Build manifest path escapes root'}
    return $path
}

function Test-ToolboxManagedBuild {
    param([string]$RepoRoot,[string]$ManifestPath)
    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.Version -ne 1 -or @($manifest.Components).Count -ne 2){throw 'Unsupported managed build manifest'}
    $output=Split-Path ([IO.Path]::GetFullPath($ManifestPath)) -Parent
    $expected=@{'anchor-locator'='shared\notify\AnchorLocator.cs';'audio-switcher'='tools\audio-switcher\AudioSwitcher.cs'}
    $seen=@{}
    foreach($entry in $manifest.Components){
        if(-not $expected.ContainsKey([string]$entry.Name) -or $seen.ContainsKey([string]$entry.Name) -or
           $entry.SourcePath -ine $expected[[string]$entry.Name] -or $entry.OutputPath -ine ($entry.Name+'.exe')){throw 'Unexpected/duplicate managed component'}
        $seen[[string]$entry.Name]=$true
        $source=Get-ToolboxBuildFile $RepoRoot $entry.SourcePath
        $artifact=Get-ToolboxBuildFile $output $entry.OutputPath
        if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.SourceSha256){throw "Managed source changed: $($entry.Name)"}
        if((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash -ne $entry.OutputSha256){throw "Managed artifact changed: $($entry.Name)"}
    }
    return [pscustomobject]@{Status='verified';Components=@($manifest.Components.Name);ManifestPath=[IO.Path]::GetFullPath($ManifestPath)}
}
