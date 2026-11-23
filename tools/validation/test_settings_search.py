"""Search uses static public descriptors, even with broken/private configuration."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import toolbox_settings_search as search
import toolbox_configuration as config
import toolbox_controls as controls
import toolbox_preferences as prefs


class SettingsSearchTests(unittest.TestCase):
    def test_all_module_fields_basics_and_features_have_unique_fixed_targets(self):
        items=search.catalog()['items']
        self.assertEqual(len(items),len({item['id'] for item in items}))
        self.assertEqual({(page,field['key']) for page,spec in config.MODULES.items() for field in spec['fields']},
                         {(item['page'],item['target']) for item in items if item['kind']=='field'})
        self.assertEqual({(page,key) for page,values in prefs.DEFAULTS.items() for key in values},
                         {(item['page'],item['target']) for item in items if item['kind']=='preference'})
        self.assertEqual({'feature_'+name+'_enabled' for name,_,_,_ in controls.FEATURES},
                         {item['target'] for item in items if item['kind']=='control' and item['target'].startswith('feature_')})

    def test_catalog_never_reads_settings_credentials_or_hotkey_values(self):
        with patch.object(config,'read_bytes',side_effect=AssertionError('config read')), patch.object(prefs,'read_overlay',side_effect=AssertionError('preference read')), patch.object(controls,'read_raw',side_effect=AssertionError('control read')):
            result=search.catalog()
        self.assertTrue(result['items'])

    def test_default_values_paths_and_unknown_fields_cannot_enter_index(self):
        modules=copy.deepcopy(search.MODULES)
        for spec in modules.values():
            spec['path']='PRIVATE_SENTINEL'
            for field in spec['fields']: field['default']='PRIVATE_SENTINEL';field['value']='PRIVATE_SENTINEL'
        with patch.object(search,'MODULES',modules): result=search.catalog()
        self.assertNotIn('PRIVATE_SENTINEL',json.dumps(result))
        for item in result['items']:
            self.assertEqual({'id','page','page_label','kind','target','label','keywords'},set(item))

    def test_removed_feature_is_absent_and_credentials_have_labels_only(self):
        items=search.catalog()['items']
        self.assertNotIn('titlebar',json.dumps(items))
        credentials=[item for item in items if item['kind']=='credential']
        self.assertEqual({'tencent','aliyun'},{item['target'] for item in credentials})
        self.assertTrue(all(item['page']=='translate' for item in credentials))

    def test_cli_is_bounded_unicode_json_with_no_action_side_effect(self):
        run=subprocess.run([sys.executable,'-I','-S',str(ROOT/'tools/toolbox_settings_search.py')],capture_output=True,timeout=10)
        self.assertEqual(0,run.returncode);self.assertLess(len(run.stdout),131072)
        data=json.loads(run.stdout.decode('utf-8'));self.assertEqual('ok',data['status'])
        self.assertEqual(search.catalog()['items'],data['items'])


if __name__=='__main__':unittest.main()
