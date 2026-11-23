"""Native center configuration IO: private fixtures, real CAS and exact consumers."""
import codecs
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import toolbox_configuration as config
import toolbox_preferences as prefs


class ConfigurationTests(unittest.TestCase):
    def test_every_editable_field_saves_and_reads_back_and_readonly_fields_reject_writes(self):
        count = 0
        for module, spec in config.MODULES.items():
            for definition in spec['fields']:
                key, original, kind = definition['key'], definition['default'], definition['type']
                snap = config.snapshot(module)
                if definition['readonly']:
                    with self.subTest(module=module, key=key), self.assertRaises(config.ConfigurationError):
                        config.save(module, {key: original}, snap['revision'])
                    continue
                if definition['choices']:
                    value = next(item for item in definition['choices'] if item != original)
                elif kind == 'bool': value = not original
                elif kind in ('int', 'number'):
                    value = original + (1 if kind == 'int' else .125)
                    if definition['maximum'] is not None and value > definition['maximum']: value = original - (1 if kind == 'int' else .125)
                elif kind == 'list': value = ['IsolatedProbeKeyword']
                elif kind == 'map': value = {'IsolatedZone': 17}
                elif key.startswith('schedule.fixed_'): value = '08:32'
                elif key in ('schedule.latitude', 'schedule.longitude'): value = '31.25'
                elif key.endswith('.endpoint'): value = 'probe.example.test'
                elif key == 'capture.region': value = '1,2,32,16'
                else: value = 'IsolatedProbeValue'
                with self.subTest(module=module, key=key):
                    saved = config.save(module, {key: value}, snap['revision'])
                    actual = next(field['value'] for field in saved['fields'] if field['key'] == key)
                    self.assertEqual(value, actual)
                    self.assertEqual(value, config.entries(config.module_path(module).read_text('utf-8-sig'), module)[0][key])
                    config.save(module, {key: original}, saved['revision'])
                    count += 1
        self.assertEqual(114, count)

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.repo = self.root / 'repo with spaces'
        for module, spec in config.MODULES.items():
            path = self.repo / spec['path']; path.parent.mkdir(parents=True, exist_ok=True)
            raw = config.render(b'', module, {f['key']: f['default'] for f in spec['fields']})
            if module != 'power':
                raw = raw.replace(b'\n', b'\r\n')
            path.write_bytes(codecs.BOM_UTF8 + raw)
        self.patches = [patch.object(config, 'REPO', self.repo), patch.object(prefs, 'REPO', self.repo),
                        patch.dict(os.environ, {'LOCALAPPDATA': str(self.root / 'local')})]
        for replacement in self.patches:
            replacement.start(); self.addCleanup(replacement.stop)

    def test_all_seven_modules_have_allowlisted_typed_fields_and_no_read_side_effect(self):
        for module, spec in config.MODULES.items():
            with self.subTest(module=module):
                before = config.module_path(module).read_bytes()
                result = config.snapshot(module)
                self.assertEqual(len(spec['fields']), len(result['fields']))
                self.assertEqual(spec['path'], result['config'])
                self.assertTrue(all(f['source'] == 'config' for f in result['fields']))
                self.assertEqual(before, config.module_path(module).read_bytes())
        self.assertFalse(prefs.preference_path().exists())
        self.assertFalse(prefs.preference_path().parent.exists())

    def test_translation_edits_preserve_secret_and_comments_byte_for_byte(self):
        path = config.module_path('translate')
        raw = (codecs.BOM_UTF8 + b'# private fixture\r\ntimeout_s = 4 # keep comment\r\n'
               b'[tencent]\r\nsecret_id = "SENSITIVE_ID"\r\nsecret_key = "SENSITIVE_SECRET"\r\n'
               b'region = "ap-guangzhou"\r\n')
        path.write_bytes(raw)
        snap = config.snapshot('translate')
        self.assertNotIn('SENSITIVE', json.dumps(snap))
        self.assertFalse(any('secret' in f['key'] for f in snap['fields']))
        config.save('translate', {'timeout_s': 5.5}, snap['revision'])
        self.assertEqual(raw.replace(b'timeout_s = 4 #', b'timeout_s = 5.5  #'), path.read_bytes())

    def test_multiline_secret_and_array_cannot_impersonate_editable_fields(self):
        path = config.module_path('translate')
        raw = b'unknown = """\ntimeout_s = 88\n[cache]\nmax_files = 999\n"""\ntimeout_s = 4\n'
        path.write_bytes(raw)
        snap = config.snapshot('translate')
        config.save('translate', {'timeout_s': 6}, snap['revision'])
        self.assertEqual(raw.rsplit(b'timeout_s = 4', 1)[0] + b'timeout_s = 6\n', path.read_bytes())
        audio = config.module_path('audio')
        audio.write_text('[preferred]\nheadset_keywords = [\n "first",\n "second",\n] # end\n', encoding='utf-8')
        config.save('audio', {'preferred.headset_keywords': ['third']}, config.snapshot('audio')['revision'])
        self.assertEqual(['third'], config.entries(audio.read_text(), 'audio')[0]['preferred.headset_keywords'])

    def test_power_literal_windows_path_bom_and_unknown_keys_are_preserved(self):
        path = config.module_path('power')
        raw = codecs.BOM_UTF8 + b'[caffeine]\r\ncoffee_dir = "%LOCALAPPDATA%\\coffee"\r\n[general]\r\ninterval_seconds = 1\r\nfuture = 23\r\n'
        path.write_bytes(raw)
        snap = config.snapshot('power')
        self.assertEqual(r'%LOCALAPPDATA%\coffee', next(f['value'] for f in snap['fields'] if f['key'] == 'caffeine.coffee_dir'))
        config.save('power', {'general.interval_seconds': 2}, snap['revision'])
        self.assertEqual(raw.replace(b'interval_seconds = 1', b'interval_seconds = 2'), path.read_bytes())

    def test_missing_keys_insert_in_the_correct_section_and_round_trip(self):
        path = config.module_path('ocr')
        path.write_bytes(b'# preserved\nocr = "system"\n[models.default]\ndet = ""\n')
        changes = {'model': 'mobile', 'models.mobile.det': 'models/new.onnx', 'models.default.rec': 'rec.onnx'}
        saved = config.save('ocr', changes, config.snapshot('ocr')['revision'])
        actual = {f['key']: f['value'] for f in saved['fields']}
        self.assertTrue(all(actual[key] == value for key, value in changes.items()))
        self.assertTrue(path.read_bytes().startswith(b'# preserved\nocr = "system"\nmodel = "mobile"\n'))

    def test_noop_save_keeps_exact_bytes_and_does_not_create_atomic_residue(self):
        for module in config.MODULES:
            path = config.module_path(module); before = path.read_bytes()
            config.save(module, {}, config.snapshot(module)['revision'])
            self.assertEqual(before, path.read_bytes())
            self.assertEqual([], list(path.parent.glob('.toolbox-config-*.tmp')))

    def test_invalid_values_unknown_fields_and_readonly_keys_are_rejected(self):
        cases = [('translate', {'tencent.secret_key': 'SENSITIVE'}), ('translate', {'timeout_s': True}),
                 ('translate', {'timeout_s': float('nan')}), ('translate', {'max_chars': 10**400}),
                 ('translate', {'tencent.endpoint': 'https://other/path?secret'}),
                 ('tts', {'concurrency': 11}), ('power', {'general.interval_seconds': 0}),
                 ('power', {'general.task_name': ''}), ('power', {'general.task_name': 'bad/name'}),
                 ('power', {'caffeine.coffee_dir': '   '}),
                 ('power', {'power.lenovo_ac_hibernate_minutes': 3}),
                 ('theme', {'schedule.fixed_dark_time': '29:01'}), ('theme', {'schedule.latitude': 'nan'}),
                 ('theme', {'schedule.longitude': '181'}), ('theme', {'cursor.light_dir': 'bad"path'}),
                 ('rgb', {'capture.region': '0,0,0,0'}), ('rgb', {'openrgb.zone_sizes': {'x': True}}),
                 ('audio', {'preferred.speaker_keywords': []}), ('ocr', {'ocr': 'unknown'})]
        for module, changes in cases:
            with self.subTest(module=module, changes=list(changes)):
                path = config.module_path(module); before = path.read_bytes()
                with self.assertRaises(config.ConfigurationError):
                    config.save(module, changes, config.snapshot(module)['revision'])
                self.assertEqual(before, path.read_bytes())

    def test_invalid_or_unsupported_layout_never_writes_or_exposes_values(self):
        path = config.module_path('translate')
        for raw in (b'timeout_s = "SENSITIVE', b'[cache]\nmax_files=1\nmax_files=2\n', b'x' * (config.LIMIT + 1)):
            path.write_bytes(raw)
            with self.assertRaises((config.ConfigurationError, ValueError)):
                config.save('translate', {'timeout_s': 5}, config.revision(raw))
            self.assertEqual(raw, path.read_bytes())

    def test_stale_save_and_atomic_write_failure_preserve_original(self):
        path = config.module_path('tts'); snap = config.snapshot('tts')
        config.save('tts', {'concurrency': 3}, snap['revision']); newer = path.read_bytes()
        with self.assertRaisesRegex(config.ConfigurationError, 'settings_changed_reload'):
            config.save('tts', {'concurrency': 4}, snap['revision'])
        with patch.object(config.os, 'replace', side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                config.save('tts', {'concurrency': 4}, config.revision(newer))
        self.assertEqual(newer, path.read_bytes())
        self.assertEqual([], list(path.parent.glob('.toolbox-config-*.tmp')))

    def test_failed_permission_preservation_happens_before_private_bytes_are_written(self):
        path = config.module_path('translate'); before = path.read_bytes()
        def refuse(source, temporary):
            self.assertEqual(path, source)
            self.assertEqual(b'', temporary.read_bytes())
            raise PermissionError()
        with patch.object(config, 'protect_temporary', side_effect=refuse):
            with self.assertRaises(PermissionError):
                config.save('translate', {'timeout_s': 5}, config.snapshot('translate')['revision'])
        self.assertEqual(before, path.read_bytes())
        self.assertEqual([], list(path.parent.glob('.toolbox-config-*.tmp')))

    @unittest.skipUnless(os.name == 'nt', 'Windows protected DACL preservation')
    def test_atomic_save_preserves_a_private_protected_dacl(self):
        import ctypes
        from ctypes import wintypes
        security = ctypes.WinDLL('advapi32', use_last_error=True)
        descriptor = ctypes.c_void_p()
        security.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)]
        security.ConvertStringSecurityDescriptorToSecurityDescriptorW.restype = wintypes.BOOL
        self.assertTrue(security.ConvertStringSecurityDescriptorToSecurityDescriptorW(
            'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;OW)', 1, ctypes.byref(descriptor), None))
        security.SetFileSecurityW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p]
        security.SetFileSecurityW.restype = wintypes.BOOL
        path = config.module_path('translate')
        try:
            self.assertTrue(security.SetFileSecurityW(str(path), 4 | 0x80000000, descriptor))
        finally:
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.LocalFree.argtypes = [ctypes.c_void_p]
            kernel.LocalFree(descriptor)
        def dacl():
            needed = wintypes.DWORD()
            security.GetFileSecurityW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p,
                wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
            security.GetFileSecurityW.restype = wintypes.BOOL
            security.GetFileSecurityW(str(path), 4, None, 0, ctypes.byref(needed))
            raw = ctypes.create_string_buffer(needed.value)
            self.assertTrue(security.GetFileSecurityW(str(path), 4, raw, needed, ctypes.byref(needed)))
            return bytes(raw)
        before = dacl()
        config.save('translate', {'timeout_s': 5}, config.snapshot('translate')['revision'])
        self.assertEqual(before, dacl())

    def test_external_edit_during_preparation_is_preserved(self):
        path = config.module_path('tts'); old = path.read_bytes()
        native = config.render
        def edit(*args):
            result = native(*args)
            path.write_bytes(old + b'\n# external edit\n')
            return result
        with patch.object(config, 'render', side_effect=edit):
            with self.assertRaisesRegex(config.ConfigurationError, 'settings_changed_reload'):
                config.save('tts', {'concurrency': 3}, config.revision(old))
        self.assertEqual(old + b'\n# external edit\n', path.read_bytes())

    def test_cli_fixed_errors_and_isolated_round_trip(self):
        for filename in ('toolbox_configuration.py', 'configuration_schema.py', 'toolbox_preferences.py', 'toolbox_reload.py', 'toolbox_controls.py', 'toolbox_capture_activity.py'):
            shutil.copyfile(Path(config.__file__).parent / filename, self.repo / 'tools' / filename)
        helper = self.repo / 'tools/toolbox_configuration.py'
        snap = config.snapshot('ocr')
        result = subprocess.run([sys.executable, '-I', '-S', str(helper), '--module', 'ocr', '--apply'],
                                input=json.dumps({'revision': snap['revision'], 'changes': {'ocr': 'system'}}),
                                capture_output=True, text=True, encoding='utf-8', timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('system', config.entries(config.module_path('ocr').read_text('utf-8-sig'), 'ocr')[0]['ocr'])
        config.module_path('translate').write_bytes(b'timeout_s = "SENSITIVE_BROKEN')
        result = subprocess.run([sys.executable, '-I', '-S', str(helper), '--module', 'translate'],
                                capture_output=True, text=True, encoding='utf-8', timeout=10)
        self.assertEqual(1, result.returncode)
        self.assertNotIn('SENSITIVE', result.stdout + result.stderr)
        self.assertEqual('error', json.loads(result.stdout)['status'])

    def test_real_two_writers_have_one_winner_and_no_lost_update(self):
        snap = config.snapshot('tts')
        code = '''import sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]);import toolbox_configuration as c;import toolbox_preferences as p
c.REPO=p.REPO=Path(sys.argv[2])
try:c.save('tts',{'concurrency':int(sys.argv[3])},sys.argv[4]);print('ok')
except c.ConfigurationError as e:print(str(e))
'''
        processes = [subprocess.Popen([sys.executable, '-I', '-S', '-c', code, str(Path(config.__file__).parent),
                                      str(self.repo), str(value), snap['revision']], stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True) for value in (3, 4)]
        results = [process.communicate(timeout=10) for process in processes]
        self.assertEqual([0, 0], [process.returncode for process in processes], str(results))
        self.assertEqual(['ok', 'settings_changed_reload'], sorted(stdout.strip() for stdout, _ in results))
        self.assertTrue(all(not stderr for _, stderr in results))

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell module consumers')
    def test_existing_power_and_theme_loaders_read_saved_values_without_applying_them(self):
        source = Path(config.__file__).parent
        for name in ('PowerPolicy.ps1', 'PowerPolicy.Core.ps1', 'PowerPolicy.Identity.ps1'):
            shutil.copyfile(source / 'power-policy' / name, self.repo / 'tools/power-policy' / name)
        shutil.copyfile(source / 'theme-scheduler/ThemeUtils.ps1', self.repo / 'tools/theme-scheduler/ThemeUtils.ps1')
        shutil.copyfile(source / 'ToolboxControls.ps1', self.repo / 'tools/ToolboxControls.ps1')
        config.save('power', {'general.interval_seconds': 7, 'power.dc_standby_seconds': 2345}, config.snapshot('power')['revision'])
        config.save('theme', {'schedule.fixed_light_time': '08:32', 'wallpaper.directory': r'C:\fixed path\图片'}, config.snapshot('theme')['revision'])
        script = self.root / 'read-only-consumers.ps1'
        script.write_text('''param([string]$Repo)
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'tools/power-policy/PowerPolicy.ps1') -LibraryOnly
if($IntervalSeconds -ne 7 -or $DcStandbySeconds -ne 2345){throw 'power_config_mismatch'}
. (Join-Path $Repo 'tools/theme-scheduler/ThemeUtils.ps1')
$theme=Get-ThemeConfig
if($theme.schedule.fixed_light_time -ne '08:32' -or $theme.wallpaper.directory -ne 'C:\\fixed path\\图片'){throw 'theme_config_mismatch'}
Write-Output 'read_only_consumers_ok'
''', encoding='utf-8-sig')
        environment = os.environ.copy()
        environment['PSModulePath'] = str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/Modules')
        result = subprocess.run([str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'),
                                 '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), str(self.repo)],
                                capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=20, env=environment)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('read_only_consumers_ok', result.stdout)


if __name__ == '__main__':
    unittest.main()
