"""Private fixtures for credential writes and deferred reload state; no network/hardware."""
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import toolbox_configuration as config
import toolbox_controls as controls
import toolbox_credentials as credentials
import toolbox_preferences as prefs
import toolbox_reload as reload


class SettingsIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'fixture with spaces'
        for module, spec in config.MODULES.items():
            path = self.repo / spec['path']; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(config.render(b'', module, {f['key']: f['default'] for f in spec['fields']}))
        for obj in (config, controls, prefs):
            replacement = patch.object(obj, 'REPO', self.repo); replacement.start(); self.addCleanup(replacement.stop)
        replacement = patch.object(credentials, 'environment_present', return_value=False)
        replacement.start(); self.addCleanup(replacement.stop)
        (self.repo / 'ahk').mkdir(); shutil.copy(Path(__file__).resolve().parents[2] / 'ahk/shortcuts.ahk', self.repo / 'ahk')

    def test_section_defaults_preserve_other_page_and_do_not_pin_defaults(self):
        current = prefs.snapshot()
        saved = prefs.save({'translate': {'target_language': 'en'}, 'tts': {'rate': '+5%'}}, current['revision'])
        reset = prefs.save({}, saved['revision'], reset_section='translate', expected_base_revision=saved['base_revision'])
        self.assertEqual(reset['defaults']['translate'], reset['values']['translate'])
        self.assertEqual('+5%', reset['values']['tts']['rate'])
        self.assertNotIn('translate', json.loads(prefs.preference_path().read_text())['values'])
        with self.assertRaises(prefs.PreferenceError):
            prefs.save({}, reset['revision'], reset_section='tts', expected_base_revision='stale')

    def test_write_only_credentials_preserve_comments_and_configuration(self):
        path = config.module_path('translate'); raw = path.read_bytes() + b'\n# keep me\n'
        path.write_bytes(raw); initial = credentials.snapshot()
        saved = credentials.save('tencent', {'secret_id':'FIXED_PRIVATE_ID','secret_key':'FIXED_PRIVATE_SECRET'}, initial['revision'])
        metadata = json.dumps(saved)
        self.assertNotIn('FIXED_PRIVATE', metadata)
        self.assertTrue(all(f['configured'] and f['source']=='config' for f in saved['providers'][0]['fields']))
        self.assertIn(b'# keep me', path.read_bytes())
        with self.assertRaises(credentials.CredentialError):
            credentials.save('aliyun', {'access_key_id':'FIXED_OTHER_ID'}, initial['revision'])
        with self.assertRaises(credentials.CredentialError):
            credentials.save('tencent', {'endpoint':'malicious'}, saved['revision'])
        before = path.read_bytes()
        with self.assertRaises(credentials.CredentialError):
            credentials.save('tencent', {'secret_key':'bad\nvalue'}, saved['revision'])
        self.assertEqual(before, path.read_bytes())
        # Unrelated settings/defaults cannot erase private fields.
        config.save('translate', {'timeout_s':5}, saved['revision'])
        self.assertTrue(credentials.snapshot()['providers'][0]['fields'][1]['configured'])
        cleared = credentials.save('tencent', {}, credentials.snapshot()['revision'], clear=True)
        self.assertTrue(all(not f['configured'] for f in cleared['providers'][0]['fields']))

    def test_credential_replacement_is_protected_before_secret_bytes_are_written(self):
        observed=[]
        original=config.protect_temporary
        def protect(source, temporary):
            observed.append(temporary.read_bytes()); return original(source, temporary)
        with patch.object(config, 'protect_temporary', side_effect=protect):
            credentials.save('aliyun', {'access_key_id':'FIXED_ID','access_key_secret':'FIXED_SECRET'}, credentials.snapshot()['revision'])
        self.assertEqual([b''], observed)
        self.assertFalse(list(config.module_path('translate').parent.glob('.toolbox-config-*.tmp')))

    def test_explicit_ui_keys_override_stale_environment_for_both_providers(self):
        spec=importlib.util.spec_from_file_location('isolated_translation_credentials', Path(__file__).resolve().parents[1]/'translate/translate.py')
        tr=importlib.util.module_from_spec(spec); sys.modules[spec.name]=tr; spec.loader.exec_module(tr)
        with patch.dict(os.environ, {'TENCENTCLOUD_SECRET_ID':'STALE_ID','TENCENTCLOUD_SECRET_KEY':'STALE_KEY', 'ALIBABA_CLOUD_ACCESS_KEY_ID':'STALE_ID','ALIBABA_CLOUD_ACCESS_KEY_SECRET':'STALE_KEY'}), patch.object(tr,'read_user_env',return_value=''):
            self.assertEqual(('LOCAL_ID','LOCAL_KEY'), tr.resolve_tencent_keys({'tencent':{'secret_id':'LOCAL_ID','secret_key':'LOCAL_KEY','prefer_config_credentials':True}}))
            self.assertEqual(('LOCAL_ID','LOCAL_KEY'), tr.resolve_aliyun_keys({'aliyun':{'access_key_id':'LOCAL_ID','access_key_secret':'LOCAL_KEY','prefer_config_credentials':True}}))
            self.assertEqual(('STALE_ID','STALE_KEY'), tr.resolve_tencent_keys({'tencent':{}}))

    def test_reload_marking_only_for_actual_deferred_changes(self):
        for module,key,value in [('translate','timeout_s',5),('theme','general.show_notification',True)]:
            config.save(module,{key:value},config.snapshot(module)['revision'])
        self.assertFalse(reload.pending())
        config.save('theme',{'schedule.fixed_light_time':'08:32'},config.snapshot('theme')['revision'])
        config.save('power',{'wake.disable_timers':False},config.snapshot('power')['revision'])
        self.assertEqual({'theme','power'},set(reload.pending()))
        self.assertEqual(2,len(reload.snapshot()['pending']))

    def test_reload_completion_clears_only_successful_unchanged_modules(self):
        for module in ('theme','power','rgb'): reload.mark_pending(module, ['schedule.fixed_light_time'], reload.revision(module))
        request={'id':'a'*32, **{m+'_revision':reload.revision(m) for m in ('theme','power','rgb')}}
        reload.write('request',request); reload.write('result',{'id':'a'*32,'status':'completed','completed':'theme,power','failed':'rgb'})
        config.save('power',{'wake.disable_timers':False},config.snapshot('power')['revision'])
        self.assertEqual({'power','rgb'}, {item['id'] for item in reload.snapshot()['pending']})
        reload.write('result',{'id':'b'*32,'status':'completed','completed':'rgb','failed':''})
        self.assertEqual({'power','rgb'}, set(reload.pending()))

    def test_reload_request_contains_only_fixed_actions_and_rejects_busy(self):
        reload.mark_pending('power',['wake.disable_timers'],reload.revision('power'))
        with patch.object(reload,'process_ticks',return_value='123456789012345678'):
            result=reload.request_reload()
        request=reload.read('request'); self.assertEqual('power',request['actions']); self.assertEqual(32,len(result['id']))
        reload.write('result',{'id':result['id'],'status':'running'})
        with self.assertRaises(reload.ReloadError): reload.request_reload()
        reload.write('pending',{'arbitrary':'f'*64})
        with self.assertRaises(reload.ReloadError): reload.snapshot()

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell validation')
    def test_medium_worker_rejects_unsafe_requests_and_foreign_tasks_without_actions(self):
        support = Path(__file__).resolve().parents[1] / 'settings/ReloadSupport.ps1'
        script = self.repo / 'check-reload.ps1'
        script.write_text(r'''param([string]$Support)
$ErrorActionPreference='Stop'
. $Support
$r=[pscustomobject]@{version=1;id=('a'*32);actions='power';owner_pid=123;owner_ticks='123456789012345678';created_unix=1000;power_revision=('b'*64)}
$ok=@(Assert-SettingsReloadRequest $r ('a'*32) 1001)
if($ok.Count -ne 1 -or $ok[0] -ne 'power'){throw 'valid request rejected'}
foreach($bad in @('unknown','power,power','power,theme,../../other','')) {
    $r.actions=$bad;$rejected=$false
    try { Assert-SettingsReloadRequest $r ('a'*32) 1001 | Out-Null } catch {$rejected=$true}
    if(-not $rejected){throw 'unsafe action accepted'}
}
$r.actions='power';$rejected=$false
try{Assert-SettingsReloadRequest $r ('a'*32) 1200 | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'stale request accepted'}
$r | Add-Member -NotePropertyName command -NotePropertyValue ignored
$rejected=$false
try{Assert-SettingsReloadRequest $r ('a'*32) 1001 | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'command accepted'}
$script=Join-Path $PSScriptRoot 'ambient.py'
$task=[pscustomobject]@{TaskPath='\';Actions=@([pscustomobject]@{Execute='pythonw.exe';Arguments=('-u "'+$script+'"');WorkingDirectory=$PSScriptRoot})}
Assert-SettingsTaskOwner $task $script
$task.Actions[0].Arguments='-u "C:\another-checkout\ambient.py"'
$rejected=$false
try{Assert-SettingsTaskOwner $task $script}catch{$rejected=$true}
if(-not $rejected){throw 'foreign task accepted'}
Write-Output 'PASS: fixed reload request and task ownership validation; no task actions'
''',encoding='ascii')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(script),'-Support',str(support)],capture_output=True,text=True)
        self.assertEqual(0,result.returncode,result.stdout+result.stderr)
        self.assertIn('PASS:',result.stdout)

    def test_credential_cli_never_echoes_private_parser_errors(self):
        tools=self.repo/'tools'
        for name in ('toolbox_configuration.py','configuration_schema.py','toolbox_preferences.py','toolbox_credentials.py'):
            shutil.copy(Path(__file__).resolve().parents[1]/name,tools/name)
        config.module_path('translate').write_text('secret_key = "FIXED_PRIVATE_PARSE_ERROR',encoding='utf-8')
        result=subprocess.run([sys.executable,'-I','-S',str(tools/'toolbox_credentials.py')],text=True,capture_output=True)
        self.assertNotEqual(0,result.returncode); self.assertNotIn('FIXED_PRIVATE',result.stdout+result.stderr)
        self.assertEqual('credentials_not_saved',json.loads(result.stdout)['code'])


if __name__=='__main__': unittest.main()
