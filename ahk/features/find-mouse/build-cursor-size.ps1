$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'cursor-size.cs'
$output = Join-Path $PSScriptRoot 'cursor-size.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf))
{
  $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf))
{
  throw 'csc.exe was not found.'
}

& $compiler /nologo /optimize+ /target:exe "/out:$output" $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf))
{
  throw "cursor-size.exe build failed with exit code $LASTEXITCODE"
}

Write-Host "Built $output"
