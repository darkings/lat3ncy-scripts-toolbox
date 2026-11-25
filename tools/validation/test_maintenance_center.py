"""Maintenance progress bridge: fixed tokens and safe cancellation only."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import maintenance_center as center


class MaintenanceCenterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo'
        (self.repo / '.toolbox-state').mkdir(parents=True)
        self.patcher = patch.object(center, 'REPO', self.repo)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def write(self, stage='build', result='running', record='hud-123', failure=''):
        doc = {'version': 1, 'stage': stage, 'result': result, 'updated_utc': '2026-11-25T00:00:00+00:00',
               'record': record, 'failure': failure}
        center.state_path().write_text(json.dumps(doc), encoding='utf-8')

    def test_idle_state_has_no_record_or_cancel(self):
        state = center.snapshot()
        self.assertEqual('idle', state['stage'])
        self.assertFalse(state['cancellable'])
        with self.assertRaisesRegex(center.MaintenanceError, 'stage_not_cancellable'):
            center.request_cancel()
        self.assertFalse(center.cancel_path().exists())

    def test_cancel_only_during_safe_pre_mutation_stages(self):
        for stage in ('build', 'verify'):
            self.write(stage=stage)
            self.assertTrue(center.snapshot()['cancellable'])
            center.request_cancel()
            self.assertTrue(center.cancel_path().exists())
            center.cancel_path().unlink()
        for stage in ('deploy', 'restore'):
            self.write(stage=stage)
            self.assertFalse(center.snapshot()['cancellable'])
            with self.assertRaisesRegex(center.MaintenanceError, 'stage_not_cancellable'):
                center.request_cancel()
            self.assertFalse(center.cancel_path().exists())

    def test_bridge_accepts_only_fixed_cancel_request(self):
        self.write(stage='verify')
        with patch.object(sys, 'stdin', __import__('io').StringIO('{"cancel":true}')):
            self.assertEqual(0, center.main(['--apply']))
        self.assertTrue(center.cancel_path().exists())

    def test_invalid_or_oversized_state_is_rejected(self):
        center.state_path().write_text('{"version":1,"stage":"build","result":"running","stage":"x"}', encoding='utf-8')
        with self.assertRaisesRegex(center.MaintenanceError, 'invalid_state'):
            center.snapshot()
        center.state_path().write_bytes(b'x' * (center.LIMIT + 1))
        with self.assertRaisesRegex(center.MaintenanceError, 'invalid_state'):
            center.snapshot()

    def test_fixed_failure_tokens_and_record_are_exported(self):
        self.write(result='failed', failure='deploy_failed', record='hud-abc')
        state = center.snapshot()
        self.assertEqual('deploy_failed', state['failure'])
        self.assertEqual('hud-abc', state['record'])
        self.assertFalse(state['cancellable'])


if __name__ == '__main__':
    unittest.main()
