$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'AnchorLocator.cs'
$output = Join-Path $PSScriptRoot 'anchor-locator.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf))
{
  $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf))
{
  throw 'csc.exe was not found.'
}

function Resolve-FrameworkAssembly
{
  param([Parameter(Mandatory = $true)][string]$Name)

  $root = Join-Path $env:WINDIR "Microsoft.NET\assembly\GAC_MSIL\$Name"
  $dll = Get-ChildItem -LiteralPath $root -Recurse -Filter "$Name.dll" |
    Sort-Object FullName -Descending |
    Select-Object -First 1
  if (-not $dll)
  {
    throw "Required assembly was not found: $Name"
  }
  return $dll.FullName
}

$references = @(
  (Resolve-FrameworkAssembly 'UIAutomationClient'),
  (Resolve-FrameworkAssembly 'UIAutomationTypes'),
  (Resolve-FrameworkAssembly 'WindowsBase')
)
$arguments = @(
  '/nologo',
  '/optimize+',
  '/target:exe',
  "/out:$output"
)
foreach ($reference in $references)
{
  $arguments += "/r:$reference"
}
$arguments += $source

& $compiler @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf))
{
  throw "anchor-locator.exe build failed with exit code $LASTEXITCODE"
}

Write-Host "Built $output"
