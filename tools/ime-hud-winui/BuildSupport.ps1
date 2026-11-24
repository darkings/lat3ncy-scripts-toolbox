# Read-only source fingerprint shared by build checks and deployment.
function Get-ImeHudSourceHash
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectDir
  )

  $ProjectDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectDir)
  $ProjectDir = [IO.Path]::GetFullPath($ProjectDir).TrimEnd('\')
  $sourceFiles = @(Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -ErrorAction Stop |
      Where-Object {
        $_.Extension -in @('.cs', '.xaml', '.csproj', '.manifest', '.png') -and
        $_.FullName -notmatch '\\(bin|obj|out|test-out)\\'
      } | Sort-Object FullName)
  if ($sourceFiles.Count -eq 0)
  {
    throw "No ImeHudWinUi source files found under $ProjectDir"
  }

  $builder = [System.Text.StringBuilder]::new()
  foreach ($file in $sourceFiles)
  {
    $relative = $file.FullName.Substring($ProjectDir.Length).TrimStart('\')
    $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    [void]$builder.Append($relative).Append('|').Append($fileHash).Append("`n")
  }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try
  {
    $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($builder.ToString()))
  }
  finally
  {
    $sha.Dispose()
  }
  return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Invoke-ImeHudBuild
{
  param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectDir,
    [Parameter(Mandatory = $true)]
    [string] $OutDir
  )

  $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
  if (-not $dotnet)
  {
    throw 'dotnet.exe not found; install the .NET SDK to build ImeHudWinUi before testing'
  }

  [Console]::Out.WriteLine('Building tools/ime-hud-winui from source ...')
  & $dotnet.Source publish (Join-Path $ProjectDir 'ImeHudWinUi.csproj') `
    -c Release `
    -r win-x64 `
    --self-contained false `
    '-p:Platform=x64' `
    -o $OutDir
  if ($LASTEXITCODE -ne 0)
  {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
  }

  $exe = Join-Path $OutDir 'ImeHudWinUi.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf))
  {
    throw "dotnet publish did not produce $exe"
  }
  $sourceHash = Get-ImeHudSourceHash -ProjectDir $ProjectDir
  $stampPath = Join-Path $OutDir '.source-stamp'
  Set-Content -LiteralPath $stampPath -Value $sourceHash -Encoding ASCII
  [Console]::Out.WriteLine("PASS: ImeHudWinUi build stamp $sourceHash")
}

