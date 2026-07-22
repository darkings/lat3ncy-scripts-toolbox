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
$image = $null
$ownedPngStream = $null
$stream = $null
$temporaryPath = $null
$outputPath = $null

try {
    $dataObject = [Windows.Forms.Clipboard]::GetDataObject()
    if ([Windows.Forms.Clipboard]::ContainsImage()) {
        $image = [Windows.Forms.Clipboard]::GetImage()
    } elseif ($dataObject -and $dataObject.GetDataPresent('PNG')) {
        $pngData = $dataObject.GetData('PNG')
        if ($pngData -is [byte[]]) {
            $ownedPngStream = [IO.MemoryStream]::new($pngData, $false)
        } elseif ($pngData -is [IO.Stream]) {
            $ownedPngStream = [IO.MemoryStream]::new()
            $originalPosition = $null
            if ($pngData.CanSeek) {
                $originalPosition = $pngData.Position
                $pngData.Position = 0
            }
            try {
                $pngData.CopyTo($ownedPngStream)
            } finally {
                if ($null -ne $originalPosition) {
                    $pngData.Position = $originalPosition
                }
            }
            $ownedPngStream.Position = 0
        }

        if ($ownedPngStream) {
            $image = [Drawing.Image]::FromStream($ownedPngStream)
        }
    }

    if ($null -eq $image) {
        throw 'Clipboard does not contain a readable image.'
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
} finally {
    if ($stream) {
        $stream.Dispose()
    }
    if ($image) {
        $image.Dispose()
    }
    if ($ownedPngStream) {
        $ownedPngStream.Dispose()
    }
    if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}
