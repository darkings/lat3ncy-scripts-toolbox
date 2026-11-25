"""Capture naming templates, after-action policy and recent-result actions."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import toolbox_capture_activity as activity


class CaptureRecentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo'
        (self.repo / '.toolbox-state').mkdir(parents=True)
        self.patcher = patch.object(activity, 'ROOT', self.repo)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def write_result(self, state='completed', path_value=None):
        if path_value is None:
            path_value = self.repo / 'result.png'
            path_value.write_bytes(b'fixed')
        doc = {'version': 1, 'id': 'a' * 32, 'mode': 'Screenshot', 'state': state,
               'reason': 'none', 'clipboard': 'success', 'extra_copy': 'off',
               'updated_utc': '2026-11-25T00:00:00+00:00', 'file_path': str(path_value), 'extra_path': ''}
        (self.repo / '.toolbox-state/capture-result-screenshot.json').write_text(json.dumps(doc), encoding='utf-8')
        session = {'version': 1, 'id': 'a' * 32, 'mode': 'Screenshot',
                   'startedUtc': '2026-11-25T00:00:00+00:00', 'deadlineUtc': '2099-01-01T00:00:00+00:00'}
        (self.repo / '.toolbox-state/capture-screenshot.json').write_text(json.dumps(session), encoding='utf-8')
        return doc

    def test_snapshot_exposes_has_file_but_never_paths(self):
        self.write_result()
        item = next(i for i in activity.snapshot()['items'] if i['mode'] == 'Screenshot')
        self.assertTrue(item['has_file'])
        self.assertNotIn('file_path', item)
        self.assertNotIn('extra_path', item)

    def test_actions_require_delivered_state_and_existing_file(self):
        self.write_result(state='timeout')
        with self.assertRaisesRegex(ValueError, 'result_not_delivered'):
            activity.apply_action('Screenshot', 'open')
        self.write_result(path_value=self.repo / 'missing.png')
        with self.assertRaisesRegex(ValueError, 'recent_file_missing'):
            activity.apply_action('Screenshot', 'reveal')

    def test_unknown_mode_or_action_is_rejected(self):
        for mode, action in (('Shell', 'open'), ('Screenshot', 'launch')):
            with self.assertRaisesRegex(ValueError, 'invalid_request'):
                activity.apply_action(mode, action)


class CaptureScriptTests(unittest.TestCase):
    def test_runtime_exposes_name_template_after_action_and_path_separation(self):
        support = (ROOT / 'tools/raycast-scripts/capture/CaptureSupport.ps1').read_text('utf-8-sig')
        runtime = (ROOT / 'tools/raycast-scripts/capture/CaptureRuntime.ps1').read_text('utf-8-sig')
        watcher = (ROOT / 'tools/raycast-scripts/capture/watch-save.ps1').read_text('utf-8-sig')
        self.assertIn('name_template', support)
        self.assertIn('after_action', support)
        self.assertIn("{guid8}", support)
        self.assertIn('Copy-ToolboxCaptureExtra $Path $Options.ExtraDirectory $Repo $IsCurrent -Mode $Mode -NameTemplate $Options.NameTemplate', runtime)
        self.assertIn('Invoke-ToolboxCaptureAfterAction', watcher)
        self.assertIn("-FilePath $file.FullName -ExtraPath $outcome.extra_path", watcher)
        self.assertIn('Windows keeps its original save location', (ROOT / 'tools/raycast-scripts/capture/config.toml').read_text('utf-8-sig'))


if __name__ == '__main__':
    unittest.main()
