"""Offline diagnostics contracts: privacy, bounded probes and runtime ownership."""
import importlib.util
from contextlib import redirect_stdout
import io
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
            self.assertEqual({'status': 'ok', 'engine': 'tencent', 'source_language': 'auto', 'target_language': 'auto',
                              'fallback_without_credentials': False, 'fallback_on_auth_error': False, 'long_text_enabled': False}, doctor.config_summary(config, 'translate'))
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
            self.assertEqual({'status': 'ok', 'engine': 'tencent', 'source_language': 'en', 'target_language': 'zh',
                              'fallback_without_credentials': False, 'fallback_on_auth_error': False, 'long_text_enabled': False}, doctor.config_summary(config, 'translate'))

    def test_translation_fallback_policy_is_boolean_and_never_exports_invalid_values(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config.toml'
            config.write_text('fallback_without_credentials=true\nfallback_on_auth_error=true\n', encoding='utf-8')
            report = doctor.config_summary(config, 'translate')
            self.assertIs(True, report['fallback_without_credentials'])
            self.assertIs(True, report['fallback_on_auth_error'])
            for field in ('fallback_without_credentials', 'fallback_on_auth_error'):
                for value in ('"private-secret"', '1', '[]'):
                    with self.subTest(field=field, value=value):
                        config.write_text(f'{field}={value}\n', encoding='utf-8')
                        report = doctor.config_summary(config, 'translate')
                        self.assertEqual({'status': 'invalid', 'reason': 'invalid-fallback-policy', 'field': field}, report)
                        self.assertNotIn('private-secret', json.dumps(report))

    def test_fallback_history_is_separate_from_delivery_and_only_accepts_fixed_enums(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder)/'log'
            log.write_text('[2026-11-22 08:00:00] fallback preferred=tencent engine=google_gtx reason=credentials\n', encoding='utf-8')
            report = doctor.log_summary(log, 'translate')
            self.assertEqual({'atLocal': '2026-11-22 08:00:00', 'preferredEngine': 'tencent', 'engine': 'google_gtx', 'reason': 'credentials'}, report['lastFallbackEvent'])
            self.assertNotIn('lastTerminalEvent', report)
            self.assertNotIn('lastFailure', report)
            with log.open('a', encoding='utf-8') as stream:
                stream.write('[2026-11-22 08:00:01] ok id=1 engine=google_gtx cached=0 chars=12\n'
                             '[2026-11-22 08:00:02] fail id=2 message=private-source diagnostic=auth detail=private-secret\n'
                             '[2026-11-22 08:00:03] fallback preferred=private-secret engine=google_gtx reason=auth\n'
                             '[2026-11-22 08:00:04] fallback preferred=tencent engine=google_gtx reason=private-source\n'
                             '[2026-11-22 08:00:05] fallback preferred=google_gtx engine=google_gtx reason=timeout\n'
                             '[2026-11-22 08:00:06] fallback preferred=tencent engine=google_gtx reason=auth detail=private-secret\n')
            report = doctor.log_summary(log, 'translate')
            self.assertEqual('2026-11-22 08:00:00', report['lastFallbackEvent']['atLocal'])
            self.assertEqual('auth', report['lastFailure']['kind'])
            self.assertEqual('fail', report['lastTerminalEvent']['status'])
            self.assertNotIn('private-', json.dumps(report))

    def test_delivery_and_launch_failures_keep_the_stage_without_exporting_exception_text(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder)/'log'
            for line, stage in [('delivery-failed id=1 diagnostic=internal', 'delivery'),
                                ('start-failed id=2 error=private-secret', 'launch')]:
                with self.subTest(stage=stage):
                    log.write_text('[2026-11-22 08:00:00] ok id=1 engine=identity cached=0 chars=4\n'
                                   '[2026-11-22 08:01:00] '+line+'\n', encoding='utf-8')
                    report = doctor.log_summary(log, 'translate')
                    expected = {'atLocal': '2026-11-22 08:01:00', 'status': 'fail', 'kind': 'internal', 'stage': stage}
                    self.assertEqual(expected, report['lastTerminalEvent'])
                    self.assertEqual(expected, report['lastFailure'])
                    self.assertNotIn('private-secret', json.dumps(report))

    def test_success_records_report_engine_cache_and_presentation_without_partial_token_matches(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder)/'log'
            for status, suffix, presentation in [('ok', ' chars=8', 'panel'), ('ok-popup', '', 'popup')]:
                with self.subTest(status=status):
                    log.write_text(f'[2026-11-22 08:00:00] {status} id=1 engine=google_gtx cached=1{suffix}\n'
                                   '[2026-11-22 08:01:00] ok id=2 engine=google_gtx-private-secret cached=0 chars=3\n'
                                   '[2026-11-22 08:02:00] ok id=3 engine=google_gtx cached=private-secret chars=3\n', encoding='utf-8')
                    report = doctor.log_summary(log, 'translate')
                    self.assertEqual({'atLocal': '2026-11-22 08:00:00', 'status': 'ok', 'engine': 'google_gtx', 'cached': True,
                                      'presentation': presentation}, report['lastTerminalEvent'])
                    self.assertNotIn('lastFailure', report)
                    self.assertNotIn('private-secret', json.dumps(report))

    @unittest.skipUnless(os.name == 'nt', 'Windows diagnostic entry point')
    def test_plain_summary_displays_fallback_policy_and_history(self):
        report = {'status': 'ok', 'residents': {},
                  'modules': {'translate': {'status': 'ok'}},
                  'configs': {'translate': {'status': 'ok', 'engine': 'tencent', 'fallback_without_credentials': True, 'fallback_on_auth_error': True}},
                  'logs': {'translate': {'path': 'fixture.log', 'status': 'available',
                      'lastTerminalEvent': {'atLocal': '2026-11-22 08:01:00', 'status': 'fail', 'stage': 'delivery'},
                      'lastFallbackEvent': {'atLocal': '2026-11-22 08:00:00', 'preferredEngine': 'tencent', 'engine': 'google_gtx', 'reason': 'credentials'}}}}
        with patch.object(doctor, 'collect', return_value=report), patch.object(sys, 'argv', ['doctor.py']), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(0, doctor.main())
        self.assertIn('missing credentials=True; auth error=True', output.getvalue())
        self.assertIn('tencent -> google_gtx (credentials)', output.getvalue())
        self.assertIn('stage=delivery', output.getvalue())

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
