param(
    [Parameter(Mandatory = $true)][string] $Destination,
    [Parameter(Mandatory = $true)][string] $ResultFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    throw 'Destination directory does not exist.'
}
if (-not [Windows.Forms.Clipboard]::ContainsImage()) {
    throw 'Clipboard does not contain an image.'
}

$image = $null
$stream = $null
$temporaryPath = $null
$outputPath = $null
$completed = $false

try {
    $image = [Windows.Forms.Clipboard]::GetImage()
    if ($null -eq $image) {
        throw 'Clipboard image could not be read.'
    }

    $temporaryPath = Join-Path $Destination ('.Clipboard-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $stream = [IO.FileStream]::new(
        $temporaryPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $image.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    if ($stream.Length -le 0) {
        throw 'Clipboard image produced an empty PNG.'
    }
    $stream.Dispose()
    $stream = $null

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    for ($index = 0; $index -le 999; $index++) {
        $suffix = if ($index -eq 0) { '' } else { "-$index" }
        $candidate = Join-Path $Destination "Clipboard-$timestamp$suffix.png"
        try {
            [IO.File]::Move($temporaryPath, $candidate)
            $temporaryPath = $null
            $outputPath = $candidate
            break
        } catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $candidate)) {
                throw
            }
        }
    }

    if (-not $outputPath) {
        throw 'Could not allocate a unique output filename.'
    }

    [IO.File]::WriteAllText($ResultFile, $outputPath, [Text.UTF8Encoding]::new($false))
    $completed = $true
} finally {
    if ($stream) {
        $stream.Dispose()
    }
    if ($image) {
        $image.Dispose()
    }
    if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $completed -and $outputPath -and (Test-Path -LiteralPath $outputPath)) {
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}
