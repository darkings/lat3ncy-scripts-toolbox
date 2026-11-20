"""Matching base-host isolation and launch selection, without OCR or UI access."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('ocr_host', Path(__file__).with_name('ocr_host.py'))
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class HostTests(unittest.TestCase):
    def fixture(self, root):
        module, home = Path(root)/'module with spaces', Path(root)/'base with spaces'
        packages = module/'.venv314/Lib/site-packages'
        packages.mkdir(parents=True); home.mkdir()
        (module/'.venv314/pyvenv.cfg').write_text(f'home = {home}\nversion_info = 3.14.10\n', encoding='utf-8')
        return module, home, packages

    def test_only_declared_environment_is_added_for_matching_isolated_host(self):
        with tempfile.TemporaryDirectory() as root:
            module, home, packages = self.fixture(root)
            runtime = types.SimpleNamespace(flags=types.SimpleNamespace(isolated=True, no_site=True),
                version_info=(3, 14, 10), _base_executable=str(home/'python.exe'), executable=str(home/'python.exe'), path=[])
            with patch.object(host, 'sys', runtime), patch.object(host.site, 'addsitedir') as add:
                self.assertEqual(str(packages), host.activate_environment(module)['site'])
                add.assert_called_once_with(str(packages))
                self.assertEqual(str(module), runtime.path[0])

    def test_wrong_version_or_base_never_loads_binary_dependencies(self):
        with tempfile.TemporaryDirectory() as root:
            module, home, packages = self.fixture(root)
            for version, base in [((3, 15, 0), home/'python.exe'), ((3, 14, 10), home/'other/python.exe')]:
                runtime = types.SimpleNamespace(flags=types.SimpleNamespace(isolated=True, no_site=True), version_info=version, _base_executable=str(base))
                with self.subTest(version=version, base=base), patch.object(host, 'sys', runtime), \
                     patch.object(host.site, 'addsitedir') as add:
                    with self.assertRaises(RuntimeError): host.activate_environment(module)
                    add.assert_not_called()

    def test_nonisolated_host_is_rejected(self):
        with patch.object(host, 'sys', types.SimpleNamespace(flags=types.SimpleNamespace(isolated=False, no_site=False))):
            with self.assertRaisesRegex(RuntimeError, '-I -S'): host.activate_environment()

    def test_bootstrap_failure_writes_safe_error_protocol(self):
        with tempfile.TemporaryDirectory() as root:
            result = Path(root)/'result.txt'
            with patch.object(host, 'activate_environment', side_effect=RuntimeError('private fixture detail')), \
                 patch.object(host.sys, 'argv', ['ocr_host.py', '--result-file', str(result)]), patch.object(host.sys, 'stderr', io.StringIO()):
                self.assertEqual(1, host.main())
            self.assertTrue(result.read_text('utf-8').startswith('ERROR:'))
            self.assertNotIn('private fixture', result.read_text('utf-8'))

    @unittest.skipUnless(sys.platform == 'win32', 'Windows launch selector')
    def test_powershell_prefers_base_then_legacy_then_global_fallback(self):
        with tempfile.TemporaryDirectory() as root:
            module, home, packages = self.fixture(root)
            (module/'ocr_host.py').write_text('# fixture', encoding='ascii')
            (home/'pythonw.exe').write_bytes(b'fixture')
            legacy = module/'.venv314/Scripts/pythonw.exe'
            legacy.parent.mkdir(); legacy.write_bytes(b'fixture')
            test = Path(root)/'selection.ps1'
            test.write_text('''param($Helper,$ModuleDir,$BaseDir)
. $Helper
$spec=Get-OcrLaunchSpec $ModuleDir
if($spec.Kind -ne 'base-host' -or $spec.Prefix.Count -ne 2 -or $spec.Prefix[0] -ne '-I' -or $spec.Prefix[1] -ne '-S'){throw 'base selection failed'}
if($spec.Python -ne (Join-Path $BaseDir 'pythonw.exe')){throw 'wrong base path'}
Remove-Item -LiteralPath (Join-Path $BaseDir 'pythonw.exe')
if((Get-OcrLaunchSpec $ModuleDir).Kind -ne 'legacy-venv'){throw 'legacy fallback failed'}
Remove-Item -LiteralPath (Join-Path $ModuleDir '.venv314\\Scripts\\pythonw.exe')
if($null -ne (Get-OcrLaunchSpec $ModuleDir)){throw 'global fallback failed'}
''', encoding='ascii')
            environment = os.environ.copy()
            environment['PSMODULEPATH'] = str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/Modules')
            run = subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'),
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(test), str(Path(__file__).with_name('OcrHost.ps1')), str(module), str(home)],
                capture_output=True, timeout=15, env=environment)
            self.assertEqual(0, run.returncode, run.stderr.decode('utf-8', 'replace'))


if __name__ == '__main__': unittest.main()
