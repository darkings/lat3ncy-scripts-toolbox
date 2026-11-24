"""Probe reporting and output isolation, without models, network, windows or sound."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('text_workflow_smoke', Path(__file__).with_name('text_workflow_smoke.py'))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class WorkflowSmokeTests(unittest.TestCase):
    def test_first_translation_outcome_is_fixed_and_not_the_injected_later_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder)/'translation.log'
            self.assertEqual('not-observed', smoke.translation_outcome(log))
            for content, expected in [
                ('[time] ok id=1 engine=identity\n[time] fail id=2 diagnostic=config private-secret', 'ok'),
                ('[time] fail id=1 message=private-secret diagnostic=timeout detail=private-secret', 'timeout'),
                ('[time] fail id=1 diagnostic=private-secret', 'failed')]:
                with self.subTest(expected=expected):
                    log.write_text(content, encoding='utf-8')
                    self.assertEqual(expected, smoke.translation_outcome(log))

    def test_partial_or_nonpassing_evidence_never_counts_as_all_passed(self):
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)/'checks.txt'
            for missing, value in [(None, '1'), ('cancelled', '1'), (None, 'yes'), (None, '0')]:
                with self.subTest(missing=missing, value=value):
                    evidence.write_text('\n'.join(f'{name}={value}' for name in smoke.CHECKS if name != missing)+'\nprivate=secret\n', encoding='utf-8')
                    checks = smoke.read_checks(evidence)
                    self.assertEqual(set(smoke.CHECKS), set(checks))
                    self.assertEqual(missing is None and value == '1', all(checks.values()))

    def test_configs_are_local_identity_without_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            smoke.write_configs(root)
            cfg = tomllib.loads((root/'config.toml').read_text('utf-8'))
            self.assertEqual('en', cfg['source_language'])
            self.assertEqual('en', cfg['target_language'])
            self.assertEqual('google_gtx', cfg['engine'])
            self.assertEqual({'config.toml', 'invalid.toml'}, {p.name for p in root.iterdir()})
            self.assertNotIn('secret', (root/'config.toml').read_text('utf-8'))

    @unittest.skipUnless(os.name == 'nt', 'Windows orchestration entry point')
    def test_network_mode_requires_explicit_flag(self):
        with tempfile.TemporaryDirectory() as folder:
            for online in (False, True):
                output = Path(folder)/str(online)
                args = ['--output', str(output), '--ahk', sys.executable]
                if online:
                    args.append('--online')
                with patch.object(smoke, 'run_probe', return_value={'status': 'passed'}) as run, redirect_stdout(io.StringIO()):
                    self.assertEqual(0, smoke.main(args))
                    self.assertEqual(online, run.call_args.args[2])

    @unittest.skipUnless(os.name == 'nt', 'Windows orchestration entry point')
    def test_existing_evidence_is_refused_without_loading_model_or_overwriting(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            marker = root/'config.toml'; marker.write_text('protected', encoding='utf-8')
            with patch.object(smoke, 'run_probe') as run, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    smoke.main(['--output', str(root), '--ahk', sys.executable])
                self.assertEqual(2, error.exception.code)
                run.assert_not_called()
            self.assertEqual('protected', marker.read_text('utf-8'))

    @unittest.skipUnless(os.name == 'nt', 'Windows orchestration entry point')
    def test_probe_exception_reports_type_without_private_message(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/'new-evidence'
            with patch.object(smoke, 'run_probe', side_effect=RuntimeError('private-secret')), redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(1, smoke.main(['--output', str(output), '--ahk', sys.executable]))
            report = json.loads((output/'report.json').read_text('utf-8'))
            self.assertEqual({'status': 'failed', 'errorType': 'RuntimeError'}, report)
            self.assertNotIn('private-secret', stdout.getvalue())


if __name__ == '__main__':
    unittest.main()
