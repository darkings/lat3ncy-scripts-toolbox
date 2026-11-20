# Pure launch selection; never invokes Python, changes ACLs, or installs packages.
function Get-OcrLaunchSpec {
    param([Parameter(Mandatory=$true)][string]$ModuleDirectory)
    $module=[IO.Path]::GetFullPath($ModuleDirectory)
    $legacy=Join-Path $module '.venv314\Scripts\pythonw.exe'
    $entry=Join-Path $module 'ocr.py'
    $hostEntry=Join-Path $module 'ocr_host.py'
    $config=Join-Path $module '.venv314\pyvenv.cfg'
    $packages=Join-Path $module '.venv314\Lib\site-packages'
    if((Test-Path -LiteralPath $config -PathType Leaf) -and
       (Test-Path -LiteralPath $hostEntry -PathType Leaf) -and
       (Test-Path -LiteralPath $packages -PathType Container)) {
        try {
            $settings=@{}
            foreach($line in [IO.File]::ReadAllLines($config)) {
                if($line -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$'){$settings[$matches[1]]=$matches[2]}
            }
            $version=if($settings.ContainsKey('version_info')){$settings['version_info']}else{$settings['version']}
            if($version -match '^3\.(1[1-4])(?:\.\d+)?$' -and
               $settings['home'] -and [IO.Path]::IsPathRooted($settings['home'])) {
                $base=Join-Path $settings['home'] 'pythonw.exe'
                if(Test-Path -LiteralPath $base -PathType Leaf) {
                    return [pscustomobject]@{Python=$base;Script=$hostEntry;Prefix=@('-I','-S');Kind='base-host'}
                }
            }
        } catch { }
    }
    if(Test-Path -LiteralPath $legacy -PathType Leaf) {
        return [pscustomobject]@{Python=$legacy;Script=$entry;Prefix=@();Kind='legacy-venv'}
    }
    return $null
}
