"""Non-secret settings transfer: export, preview, migration and conflicts."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import toolbox_config_transfer as transfer
import toolbox_configuration as config
import toolbox_preferences as prefs
import toolbox_controls as controls
import toolbox_reload


class ConfigTransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo with spaces'
        (self.repo / 'ahk').mkdir(parents=True)
        (self.repo / 'tools' / 'raycast-scripts').mkdir(parents=True)
        shutil.copyfile(ROOT / 'ahk' / 'shortcuts.ahk', self.repo / 'ahk' / 'shortcuts.ahk')
        for module in (config, prefs, controls):
            patcher = patch.object(module, 'REPO', self.repo)
            patcher.start()
            self.addCleanup(patcher.stop)

    def value(self, module, key):
        return next(f['value'] for f in config.snapshot(module)['fields'] if f['key'] == key)

    def test_export_is_secret_free_and_roundtrips_without_changes(self):
        bundle = transfer.export_payload()
        self.assertEqual(json.loads(json.dumps(bundle, ensure_ascii=False)), bundle)
        self.assertNotIn('credentials', bundle)
        for data in bundle['modules'].values():
            for key in data['fields']:
                self.assertFalse(any(m in key.lower() for m in transfer.SECRET_MARKERS), key)
        report = transfer.preview(bundle)
        self.assertEqual([], report['changes'])
        self.assertEqual([], report['conflicts'])

    def test_export_skips_secret_markers_even_when_a_schema_field_appears(self):
        fields = [{'key': 'tencent.secret_key', 'value': 'never-export', 'readonly': False, 'type': 'string'},
                  {'key': 'general.enabled', 'value': True, 'readonly': False, 'type': 'bool'}]
        with patch.object(config, 'snapshot', return_value={'revision': 'r', 'fields': fields}):
            bundle = transfer.export_payload()
        self.assertNotIn('tencent.secret_key', bundle['modules']['translate']['fields'])
        self.assertIn('tencent.secret_key', bundle['modules']['translate']['skipped'])

    def test_preview_shows_each_change_and_apply_restores_the_bundle(self):
        bundle = transfer.export_payload()
        revision = config.snapshot('raycast')['revision']
        config.save('raycast', {'general.enabled': False}, revision)
        self.assertFalse(self.value('raycast', 'general.enabled'))
        sync = json.loads(json.dumps(bundle))
        sync['modules']['raycast']['revision'] = config.snapshot('raycast')['revision']
