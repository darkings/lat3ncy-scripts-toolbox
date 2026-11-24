"""Control policy defaults, active conflicts, disabled gates and concurrent saves."""
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
import toolbox_controls as controls
import toolbox_preferences as prefs


class ControlsTests(unittest.TestCase):
    def test_all_module_feature_shortcut_flags_and_custom_bindings_round_trip(self):
        initial = controls.snapshot()
        disabled = {f'feature_{name}_enabled': False for name, *_ in controls.FEATURES}
        controls.save(disabled, initial['revision'])
        for key, original in controls.snapshot()['values'].items():
            if not isinstance(original, bool): continue
            with self.subTest(key=key):
                saved = controls.save({key: not original}, controls.snapshot()['revision'])
                self.assertEqual(not original, saved['values'][key])
                self.assertEqual(not original, controls.snapshot()['values'][key])
                controls.save({key: original}, saved['revision'])
        for name, _, _, kind in controls.FEATURES:
            if kind in ('leader', 'resident'): continue
            key = f'binding_{name}'
            original = controls.snapshot()['values'][key]
            with self.subTest(key=key):
                saved = controls.save({key: '^!F24'}, controls.snapshot()['revision'])
                self.assertEqual('^!F24', controls.snapshot()['values'][key])
                controls.save({key: original}, saved['revision'])

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(); self.addCleanup(self.folder.cleanup)
        self.repo = Path(self.folder.name) / 'repo with spaces'
        (self.repo / 'ahk').mkdir(parents=True)
        self.source = Path(controls.__file__).parents[1]
        shutil.copyfile(self.source / 'ahk/shortcuts.ahk', self.repo / 'ahk/shortcuts.ahk')
        for target, name in ((controls, 'REPO'), (prefs, 'REPO')):
            replacement = patch.object(target, name, self.repo); replacement.start(); self.addCleanup(replacement.stop)
        replacement = patch.dict(os.environ, {'LOCALAPPDATA': str(self.repo.parent / 'local')})
        replacement.start(); self.addCleanup(replacement.stop)

    def test_defaults_match_current_shortcuts_and_do_not_write(self):
        snapshot = controls.snapshot()
        defaults = controls.shortcut_defaults()
        self.assertEqual(defaults['SpeakSelectedText'], snapshot['values']['binding_SpeakSelectedText'])
        self.assertEqual(defaults['SmartPaste'], snapshot['values']['binding_SmartPaste'])
        self.assertTrue(snapshot['values']['feature_FindMouse_enabled'])
        self.assertTrue(snapshot['values']['tray_visible'])
        self.assertFalse(controls.profile_path().exists())
        self.assertFalse(prefs.preference_path().parent.exists())

    def test_module_and_feature_hotkey_switches_are_independent(self):
        initial = controls.snapshot()
        result = controls.save({'module_translate_enabled': False, 'feature_SpeakSelectedText_enabled': False,
                                'hotkey_AlwaysOnTop_enabled': False, 'tray_visible': False}, initial['revision'])
        self.assertFalse(controls.module_enabled('translate'))
        self.assertTrue(controls.module_enabled('tts'))
        self.assertTrue(result['values']['feature_AlwaysOnTop_enabled'])
        self.assertFalse(result['values']['hotkey_AlwaysOnTop_enabled'])
        self.assertTrue(result['values']['hotkey_SpeakSelectedText_enabled'])
        self.assertFalse(result['values']['tray_visible'])

    def test_custom_binding_and_reset_preserve_function_and_module_choices(self):
        saved = controls.save({'binding_SpeakSelectedText': '^!F9', 'hotkey_SpeakSelectedText_enabled': False,
                               'feature_SpeakSelectedText_enabled': False, 'module_ocr_enabled': False}, controls.snapshot()['revision'])
        reset = controls.save({}, saved['revision'], reset_shortcuts=True)
        self.assertEqual(controls.shortcut_defaults()['SpeakSelectedText'], reset['values']['binding_SpeakSelectedText'])
        self.assertTrue(reset['values']['hotkey_SpeakSelectedText_enabled'])
        self.assertFalse(reset['values']['feature_SpeakSelectedText_enabled'])
        self.assertFalse(reset['values']['module_ocr_enabled'])

    def test_normalization_equivalent_modifiers_and_caps_spacing(self):
        self.assertEqual(controls.normalize_binding('!^f'), controls.normalize_binding('$^!F'))
        self.assertEqual(controls.normalize_binding('~CapsLock & f'), controls.normalize_binding('CapsLock&F'))
        self.assertEqual(controls.normalize_binding('^Escape'), controls.normalize_binding('^Esc'))
        for value in ('^!F1', 'F24', '+!sc029', '^Numpad0', '#Home', '~CapsLock & .', 'ScrollLock'):
            self.assertTrue(controls.normalize_binding(value))

    def test_invalid_bindings_and_fixed_capslock_are_rejected_without_writing(self):
        revision = controls.snapshot()['revision']
        for changes in ({'binding_SpeakSelectedText': 'Run notepad.exe'}, {'binding_SpeakSelectedText': '^!'},
                        {'binding_SpeakSelectedText': 'f\nSend'}, {'binding_SpeakSelectedText': '^' * 2 + 'f'},
                        {'binding_SpeakSelectedText': 'F25'}, {'binding_CapsLockIme': 'F12'},
                        {'binding_SpeakSelectedText': 'CapsLock & scFFF'}, {'binding_SpeakSelectedText': 'vk00'},
                        {'tray_visible': 1}, {'unknown': True}):
            with self.subTest(keys=list(changes)), self.assertRaises(controls.ControlsError):
                controls.save(changes, revision)
            self.assertFalse(controls.profile_path().exists())

    def test_conflicts_rejected_but_disabling_binding_releases_it(self):
        snapshot = controls.snapshot()
        with self.assertRaisesRegex(controls.ControlsError, 'hotkey_conflict'):
            controls.save({'binding_TranslateSelectedText': snapshot['values']['binding_SpeakSelectedText']}, snapshot['revision'])
        saved = controls.save({'hotkey_SpeakSelectedText_enabled': False,
                               'binding_TranslateSelectedText': snapshot['values']['binding_SpeakSelectedText']}, snapshot['revision'])
        with self.assertRaisesRegex(controls.ControlsError, 'hotkey_conflict'):
            controls.save({'hotkey_SpeakSelectedText_enabled': True}, saved['revision'])

    def test_inactive_module_bindings_can_be_reused_but_reenable_checks_conflicts(self):
        saved = controls.save({'module_tts_enabled': False, 'binding_TranslateSelectedText': '~CapsLock & s'}, controls.snapshot()['revision'])
        with self.assertRaisesRegex(controls.ControlsError, 'hotkey_conflict'):
            controls.save({'module_tts_enabled': True}, saved['revision'])

    def test_editor_forwarding_defaults_share_keys_only_across_distinct_editors(self):
        current = controls.snapshot()
        self.assertEqual(current['values']['binding_VsCodeCopyPath'], current['values']['binding_ZedCopyPath'])
        with self.assertRaisesRegex(controls.ControlsError, 'hotkey_conflict'):
            controls.save({'binding_SpeakSelectedText': current['values']['binding_VsCodeCopyPath']}, current['revision'])

    def test_explicit_standalone_config_is_not_disabled_by_main_profile(self):
        controls.save({'module_tts_enabled': False}, controls.snapshot()['revision'])
        self.assertFalse(controls.module_enabled('tts', self.repo / 'tools/tts/config.toml'))
        self.assertTrue(controls.module_enabled('tts', self.repo / 'standalone.toml'))

    def test_corrupt_oversized_duplicate_or_unknown_profile_fails_closed(self):
        for data in (b'{', b'x' * (controls.LIMIT + 1), b'{"version":true}',
                     b'{"version":1,"tray_visible":true,"tray_visible":false}', b'{"version":1,"secret":"private"}'):
            controls.profile_path().write_bytes(data)
            with self.assertRaises(controls.ControlsError): controls.snapshot()
            self.assertFalse(controls.module_enabled('translate'))
            self.assertEqual(data, controls.profile_path().read_bytes())

    def test_stale_save_and_write_failure_preserve_current_policy(self):
        first = controls.snapshot()
        saved = controls.save({'tray_visible': False}, first['revision']); before = controls.profile_path().read_bytes()
        with self.assertRaisesRegex(controls.ControlsError, 'settings_changed_reload'):
            controls.save({'module_tts_enabled': False}, first['revision'])
        with patch.object(controls.os, 'replace', side_effect=PermissionError):
            with self.assertRaises(PermissionError): controls.save({'module_tts_enabled': False}, saved['revision'])
        self.assertEqual(before, controls.profile_path().read_bytes())
        self.assertEqual([], list(self.repo.glob('.toolbox-controls-*.tmp')))

    def test_two_real_writers_have_one_winner(self):
        revision = controls.snapshot()['revision']
        code = '''import sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]);import toolbox_controls as c;import toolbox_preferences as p
c.REPO=p.REPO=Path(sys.argv[2])
try:c.save({sys.argv[3]:False},sys.argv[4]);print('ok')
except c.ControlsError as e:print(str(e))
'''
        processes = [subprocess.Popen([sys.executable, '-I', '-S', '-c', code, str(self.source / 'tools'),
                                      str(self.repo), key, revision], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for key in ('tray_visible', 'module_translate_enabled')]
        results = [process.communicate(timeout=10) for process in processes]
        self.assertEqual([0, 0], [process.returncode for process in processes], str(results))
        self.assertEqual(['ok', 'settings_changed_reload'], sorted(stdout.strip() for stdout, _ in results))
        self.assertTrue(all(not stderr for _, stderr in results))

    def test_disabled_real_backends_do_not_read_input_or_load_synthesis_and_ocr_dependencies(self):
        controls.save({'module_translate_enabled': False, 'module_tts_enabled': False, 'module_ocr_enabled': False},
                      controls.snapshot()['revision'])
        tools = self.repo / 'tools'; tools.mkdir(exist_ok=True)
        for name in ('toolbox_controls.py', 'toolbox_preferences.py'):
            shutil.copyfile(self.source / 'tools' / name, tools / name)
        for module, names in {'translate': ('translate.py', 'engine_trace.py', 'auth_cooldown.py', 'long_translation.py'),
                              'tts': ('tts_player.py', 'task_protocol.py'),
                              'raycast-scripts/ocr': ('ocr_workflow.py',)}.items():
            directory = tools / module; directory.mkdir(parents=True)
            for name in names: shutil.copyfile(self.source / 'tools' / module / name, directory / name)
        secret = self.repo / 'input.txt'; secret.write_bytes(b'UNREAD_PRIVATE_SENTINEL\xff')
        output = self.repo / 'translation.txt'
        run = subprocess.run([sys.executable, '-I', '-S', str(tools / 'translate/translate.py'), '--input-file', str(secret),
                              '--output-file', str(output)], capture_output=True, timeout=10)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertIn('code=disabled', output.read_text('utf-8'))
        self.assertNotIn('UNREAD_PRIVATE_SENTINEL', output.read_text('utf-8'))
        code = '''import sys,asyncio
from types import SimpleNamespace
sys.path.insert(0,sys.argv[1]);import tts_player as t
try:asyncio.run(t.run_pipeline(SimpleNamespace(config=None,input_file=sys.argv[2])));raise AssertionError()
except t.TaskFailure as e:assert e.kind=='cancelled';assert 'edge_tts' not in sys.modules;print('cancelled_before_input')
'''
        run = subprocess.run([sys.executable, '-I', '-S', '-c', code, str(tools / 'tts'), str(secret)],
                             capture_output=True, text=True, encoding='utf-8', timeout=10)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertIn('cancelled_before_input', run.stdout)
        ocr_result = self.repo / 'ocr.txt'
        run = subprocess.run([sys.executable, '-I', '-S', str(tools / 'raycast-scripts/ocr/ocr_workflow.py'),
                              '--request-id', 'disabled-ocr', '--baseline-sequence', '0', '--image-file', str(secret),
                              '--result-file', str(ocr_result)], capture_output=True, timeout=10)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertIn('status=cancelled', ocr_result.read_text('utf-8'))
        self.assertEqual(b'UNREAD_PRIVATE_SENTINEL\xff', secret.read_bytes())

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell policy reader')
    def test_powershell_reads_the_same_profile_and_rejects_bad_flags(self):
        saved = controls.save({'module_power_enabled': False, 'module_theme_enabled': False}, controls.snapshot()['revision'])
        probe = self.repo / 'policy-check.ps1'
        helper = self.source / 'tools/ToolboxControls.ps1'
        probe.write_text('''param([string]$Helper,[string]$Repo)
$ErrorActionPreference='Stop'
. $Helper
if(Test-ToolboxModuleEnabled -Module power -RepoRoot $Repo){throw 'power_should_be_disabled'}
if(Test-ToolboxModuleEnabled -Module theme -RepoRoot $Repo){throw 'theme_should_be_disabled'}
if(-not(Test-ToolboxModuleEnabled -Module ocr -RepoRoot $Repo)){throw 'ocr_should_be_enabled'}
Write-Output 'policy_read_ok'
''', encoding='utf-8-sig')
        host = str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
        result = subprocess.run([host, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(probe), str(helper), str(self.repo)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('policy_read_ok', result.stdout)


if __name__ == '__main__': unittest.main()
