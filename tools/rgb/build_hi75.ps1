#Requires -Version 5.1
# Build hi75.py as --onedir (single process).
# --onefile always shows two hi75.exe on Windows (bootloader + worker).
# --onedir keeps one hi75.exe; deps live in _internal next to it.
# 必须 --noconsole：--console 会把 PE 打成 WINDOWS_CUI，Win11 默认终端
# 会给它分配 conhost / Windows Terminal，Ambient 后台 spawn 时弹窗。
# --serve 只走 stdin/stdout 管道，不需要控制台。
# Switch keyboard: change config.exe, or put another hi75_data next to the exe.
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$outDir = Join-Path $root "dist"
$workDir = Join-Path $root "build"
$script = Join-Path $root "hi75.py"
$hidDir = Join-Path $root "lib_hid"
$hidPyd = Join-Path $hidDir "hid.pyd"
$dataDir = Join-Path $root "hi75_data"
# leftover --onefile output; delete after --onedir so Start/Stop cannot pick it up
$legacyOnefile = Join-Path $outDir "hi75.exe"

if (-not (Test-Path -LiteralPath $script)) {
    Write-Error "missing $script"
}
if (-not (Test-Path -LiteralPath $hidPyd)) {
    Write-Error "missing $hidPyd"
}

Write-Host "1/2 pip install pyinstaller (user)..." -ForegroundColor Cyan
python -m pip install --user --quiet "pyinstaller>=6.0"
if ($LASTEXITCODE -ne 0) {
    Write-Error "pip install pyinstaller failed"
}

# Analysis must see lib_hid/hid.pyd first, not lib/hid (missing hidapi.dll).
$env:PYTHONPATH = $hidDir

$sep = ";"
$pyArgs = @(
    "-m", "PyInstaller",
    "--noconfirm",
    "--clean",
    "--onedir",
    "--noconsole",
    "--name", "hi75",
    "--distpath", $outDir,
    "--workpath", $workDir,
    "--specpath", $workDir,
    "--paths", $hidDir,
    "--hidden-import", "hid",
    "--add-binary", "$hidPyd${sep}."
)
if (Test-Path -LiteralPath $dataDir) {
    $pyArgs += @("--add-data", "$dataDir${sep}hi75_data")
}
$pyArgs += $script

Write-Host "2/2 pyinstaller hi75.py --onedir..." -ForegroundColor Cyan
python @pyArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "pyinstaller failed"
}

$exe = Join-Path $outDir "hi75\hi75.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Error "not produced $exe"
}

if (Test-Path -LiteralPath $legacyOnefile) {
    Remove-Item -LiteralPath $legacyOnefile -Force
    Write-Host "removed leftover onefile $legacyOnefile" -ForegroundColor DarkGray
}

Write-Host "OK $exe" -ForegroundColor Green
Write-Host "config.toml: exe = dist/hi75/hi75.exe" -ForegroundColor DarkGray
Write-Host "switch keyboard: change exe path, or drop hi75_data next to the exe" -ForegroundColor DarkGray
