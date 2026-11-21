"""Offline diagnostics contracts: privacy, bounded probes and runtime ownership."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('doctor', ROOT/'tools/diagnostics/doctor.py')
doctor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doctor)


class DiagnosticsTests(unittest.TestCase):
    def test_attention_probe_keeps_its_structured_findings_across_process_boundary(self):
        query = '''import importlib.util,json,sys
spec=importlib.util.spec_from_file_location('fixture_doctor',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
module.probe=lambda *args: {'status':'attention','mismatches':['edge-tts'],'integrity':'low'}
sys.argv=['doctor.py','--probe','tts']
raise SystemExit(module.main())
'''
        result = doctor.run_json([sys.executable, '-I', '-S', '-c', query, str(ROOT/'tools/diagnostics/doctor.py')])
        self.assertEqual('attention', result['status'])
        self.assertEqual(['edge-tts'], result['mismatches'])
        self.assertEqual('low', result['integrity'])

    def test_config_export_has_no_credentials_or_arbitrary_engine_values(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config.toml'
            config.write_text('engine="TMT"\nsecret_key="private-secret"\n', encoding='utf-8')
            self.assertEqual({'status': 'ok', 'engine': 'tencent', 'source_language': 'auto', 'target_language': 'auto'}, doctor.config_summary(config, 'translate'))
            for text in ('engine="private-secret"', 'engine=["private-secret"]', 'engine="broken-private-secret'):
                config.write_text(text, encoding='utf-8')
                result = doctor.config_summary(config, 'translate')
                self.assertEqual('invalid', result['status'])
                self.assertNotIn('private-secret', json.dumps(result))
            config.unlink()
            self.assertEqual({'status': 'default', 'engine': 'system'}, doctor.config_summary(config, 'ocr'))

    def test_translation_languages_export_only_canonical_enums(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config.toml'
            config.write_text('source_language=" EN "\ntarget_language="ZH-Hans"\nsecret_key="private-secret"\n', encoding='utf-8')
            self.assertEqual({'status': 'ok', 'engine': 'tencent', 'source_language': 'en', 'target_language': 'zh'}, doctor.config_summary(config, 'translate'))

    def test_invalid_translation_language_exports_field_but_never_raw_value(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config.toml'
            for field in ('source_language', 'target_language'):
                for value in ('"private-secret"', '"ja"', 'true', '[]', '42'):
                    with self.subTest(field=field, value=value):
                        config.write_text(f'{field}={value}\n', encoding='utf-8')
                        result = doctor.config_summary(config, 'translate')
                        self.assertEqual({'status': 'invalid', 'reason': 'unsupported-language', 'field': field}, result)
                        self.assertNotIn('private-secret', json.dumps(result))

    def test_log_exports_fixed_events_and_keeps_failure_separate_from_latest_success(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder)/'log.txt'
            log.write_text('[2026-11-21 08:00:00] fail id=1 message=private-source diagnostic=config detail=private-token\n'
                           '[2026-11-21 08:01:00] ok id=2 engine=google_gtx cached=0 chars=4\n'
                           'private-source diagnostic=timeout\n', encoding='utf-8')
            result = doctor.log_summary(log, 'translate')
            self.assertEqual('ok', result['lastTerminalEvent']['status'])
            self.assertEqual('config', result['lastFailure']['kind'])
            self.assertNotIn('private-', json.dumps(result))
            log.write_text('[2026-11-21 08:00:00] [AHK] 朗读结束 request=1-2 status=failed kind=synthesis exit=1\n'
                           '[2026-11-21 08:01:00] [AHK] 朗读结束 request=1-3 status=success kind=none exit=0\n', encoding='utf-8')
            result = doctor.log_summary(log, 'tts')
            self.assertEqual('success', result['lastTerminalEvent']['status'])
            self.assertEqual('synthesis', result['lastFailure']['kind'])
            log.write_text('08:00:00 py error exit=1 private-source\n08:01:00 py done exit=0\n', encoding='utf-8')
            result = doctor.log_summary(log, 'ocr')
            self.assertEqual('completed', result['lastTerminalEvent']['status'])
            self.assertEqual('failed', result['lastFailure']['status'])
            self.assertNotIn('private-source', json.dumps(result))

    def test_log_scan_is_bounded_and_absent_or_unreadable_is_safe(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'log'
            self.assertEqual('missing', doctor.log_summary(path, 'tts')['status'])
            path.write_bytes(b'[2026-11-21 08:00:00] [AHK] '+
                             '\u6717\u8bfb\u7ed3\u675f'.encode('utf-8')+
                             b' request=1 status=failed kind=synthesis exit=1\n'+b'x'*100000)
            report = doctor.log_summary(path, 'tts')
            self.assertGreater(report['bytes'], 100000)
            self.assertNotIn('lastFailure', report)
            with patch.object(Path, 'open', side_effect=PermissionError('private secret')):
                report = doctor.log_summary(path, 'tts')
            self.assertEqual('unreadable', report['status'])
            self.assertNotIn('private secret', json.dumps(report))

    def test_process_failure_timeout_and_invalid_json_never_export_child_payload(self):
        cases = [(subprocess.CompletedProcess([], 9, b'private-source', b'private-secret'), 'probe-exit'),
                 (subprocess.CompletedProcess([], 0, b'private-source', b''), None),
                 (subprocess.CompletedProcess([], 0, b'[]', b''), None)]
        for process, reason in cases:
            with patch.object(doctor.subprocess, 'run', return_value=process):
                report = doctor.run_json(['unused'])
            self.assertEqual('query-failed', report['status'])
            self.assertNotIn('private-', json.dumps(report))
            if reason:
                self.assertEqual(reason, report['reason'])
        with patch.object(doctor.subprocess, 'run', side_effect=subprocess.TimeoutExpired('private', 1)):
            self.assertEqual({'status': 'query-failed', 'reason': 'probe-timeout'}, doctor.run_json(['unused']))
        report = doctor.run_json([sys.executable, '-I', '-S', '-c', 'import time; time.sleep(10)'], timeout=.1)
        self.assertEqual('probe-timeout', report['reason'])

    def test_tts_selection_requires_ready_owner_and_keeps_legacy_and_global_fallback(self):
        with tempfile.TemporaryDirectory(prefix='doctor paths ') as folder:
            module = Path(folder)/'module'; module.mkdir()
            shutil.copyfile(ROOT/'tools/tts/tts_runtime.py', module/'tts_runtime.py')
            runtime = doctor.load_file('fixture_runtime', module/'tts_runtime.py')
            profile = runtime.profile_directory(module, folder)
            profile.mkdir(parents=True)
            selected = profile/'Scripts/pythonw.exe'; selected.parent.mkdir(); selected.touch()
            marker = profile/'.ready.txt'; marker.write_text('foreign owner', encoding='utf-8')
            global_spec = {'python': 'global', 'kind': 'global'}
            self.assertEqual(global_spec, doctor.select_tts_spec(module, folder, global_spec))
            legacy = module/'.venv/Scripts/pythonw.exe'; legacy.parent.mkdir(parents=True); legacy.touch()
            self.assertEqual('legacy-venv', doctor.select_tts_spec(module, folder, global_spec)['kind'])
            marker.write_text(runtime.owner_name(module), encoding='utf-8')
            self.assertEqual(str(selected), doctor.select_tts_spec(module, folder, global_spec)['python'])
            self.assertEqual('legacy-venv', doctor.select_tts_spec(module, None, global_spec)['kind'])

    def test_runtime_probe_uses_console_sibling_and_isolated_ocr_flags(self):
        with tempfile.TemporaryDirectory() as folder:
            console = Path(folder)/'python.exe'; console.touch()
            windowless = console.with_name('pythonw.exe')
            with patch.object(doctor, 'run_json', return_value={'status': 'ok'}) as run:
                result = doctor.inspect_runtime('ocr', {'python': str(windowless), 'kind': 'base-host'})
            self.assertEqual(str(windowless), result['selectedPythonW'])
            self.assertEqual([str(console), '-I', '-S'], run.call_args.args[0][:3])
            self.assertEqual(str(console), result['diagnosticPython'])
            console.unlink()
            with patch.object(doctor, 'run_json') as run:
                self.assertEqual('query-failed', doctor.inspect_runtime('ocr', {'python': str(windowless), 'kind': 'base-host'})['status'])
                run.assert_not_called()

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell orchestration')
    def test_resident_snapshot_uses_heartbeat_and_does_not_treat_query_failure_as_absence(self):
        with tempfile.TemporaryDirectory(prefix='doctor snapshot ') as folder:
            repo = Path(folder)
            helper = repo/'tools/startup/Deployment.Runtime.ps1'
            helper.parent.mkdir(parents=True)
            # Isolated providers: no real CIM, mutex, heartbeat, HUD or device.
            helper.write_text(r'''
function Get-CimInstance {
    if($env:TOOLBOX_DOCTOR_TEST_MODE -eq 'denied'){throw 'private-payload'}
    @(
        [pscustomobject]@{Name='AutoHotkey64.exe';CommandLine='main';ProcessId=11;ExecutablePath='ahk.exe'},
        [pscustomobject]@{Name='ImeHudWinUi.exe';CommandLine='hud';ProcessId=12;ExecutablePath=(Join-Path $Repo 'tools\ime-hud-winui\out\ImeHudWinUi.exe')},
        [pscustomobject]@{Name='powershell.exe';CommandLine='caret -OwnerPid 11';ProcessId=13;ExecutablePath='ps.exe'}
    )
}
function Get-ToolboxProcessSnapshot { [pscustomobject]@{Status='running'} }
function Get-ToolboxInstanceMarkerState { 'present' }
function Test-ToolboxMainScriptCommandLine($CommandLine,$MainScript) { $CommandLine -eq 'main' }
function Test-ToolboxScriptCommandLine($CommandLine,$ScriptPath) { $CommandLine -like 'caret *' }
function Get-ToolboxPowerPolicySnapshot {
    param($PowerScript,$ProcessProvider,$HeartbeatProvider)
    if(-not $HeartbeatProvider){throw 'heartbeat disabled'}
    [pscustomobject]@{Status='running';ProcessIds=@(14);Evidence='heartbeat'}
}
function Initialize-ToolboxHudProbe { }
Add-Type 'public static class ToolboxReleaseHudProbe { public static bool Ping(int pid) { return true; } }'
''', encoding='ascii')
            ocr = repo/'tools/raycast-scripts/ocr/OcrHost.ps1'
            ocr.parent.mkdir(parents=True)
            ocr.write_text('function Get-OcrLaunchSpec { return $null }', encoding='ascii')
            ps = Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
            command = [str(ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                       str(ROOT/'tools/diagnostics/Collect-Runtime.ps1'), '-Repo', str(repo)]
            for mode in ('normal', 'denied'):
                environment = os.environ.copy()
                environment['PSModulePath'] = str(ps.parent/'Modules')
                environment['TOOLBOX_DOCTOR_TEST_MODE'] = mode
                result = doctor.run_json(command, env=environment)
                self.assertNotIn('private-payload', json.dumps(result))
                self.assertEqual('heartbeat', result['residents']['powerPolicy']['evidence'])
                self.assertEqual('running', result['residents']['ahk']['status'])
                for component in ('caret', 'hud'):
                    self.assertEqual('running' if mode == 'normal' else 'query-failed', result['residents'][component]['status'])


if __name__ == '__main__':
    unittest.main()
