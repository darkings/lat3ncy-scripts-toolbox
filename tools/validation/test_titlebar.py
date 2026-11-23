"""Fixed one-shot titlebar scope and verified application; no user windows are changed."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import toolbox_configuration as config
import toolbox_controls as controls
import toolbox_preferences as prefs
import toolbox_reload as reload
import toolbox_titlebar as titlebar


class TitlebarTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name) / 'repo with spaces'
        path = self.repo / 'tools/theme-scheduler/config.toml'; path.parent.mkdir(parents=True)
        path.write_text('# fixture\nprivate="PRIVATE_SENTINEL"\n', encoding='utf-8')
        for module in (config, controls, prefs):
            p = patch.object(module, 'REPO', self.repo); p.start(); self.addCleanup(p.stop)

    def test_defaults_and_plan_export_only_fixed_titlebar_fields(self):
        plan = titlebar.plan()
        self.assertTrue(plan['enabled']); self.assertEqual('dark', plan['mode'])
        self.assertEqual(['Androws', 'AndrowsStore', 'AndrowsAssistant', 'AndrowsLauncher'], plan['process_names'])
        self.assertNotIn('PRIVATE_SENTINEL', json.dumps(plan))

    def test_saved_names_modes_and_empty_list_are_shared_without_pending_reload(self):
        snapshot = config.snapshot('theme')
        result = config.save('theme', {'titlebar.mode':'system','titlebar.process_names':['Fixture.exe','测试应用']}, snapshot['revision'])
        self.assertEqual(['Fixture', '测试应用'], titlebar.plan()['process_names'])
        self.assertEqual('system', titlebar.plan()['mode']); self.assertFalse(reload.pending())
        config.save('theme', {'titlebar.process_names':[]}, result['revision'])
        self.assertEqual([], titlebar.plan()['process_names'])

    def test_wildcards_paths_flags_duplicates_and_wrong_types_are_rejected(self):
        for names in (['*'],['app?'],['C:/app.exe'],['-File'],['app','APP.exe'],[7],['app;exit'],[' app']):
            with self.subTest(names=names), self.assertRaises(config.ConfigurationError): config.validate('theme', {'titlebar.process_names':names})
        with self.assertRaises(config.ConfigurationError): config.validate('theme', {'titlebar.mode':'follow'})

    def test_both_feature_gates_and_request_revision_are_enforced(self):
        snapshot = config.snapshot('theme')
        config.save('theme', {'titlebar.enabled':False}, snapshot['revision'])
        self.assertFalse(titlebar.plan()['enabled'])
        with self.assertRaisesRegex(reload.ReloadError,'reload_disabled'): reload.request_reload(['titlebar'])
        snapshot = config.snapshot('theme'); config.save('theme', {'titlebar.enabled':True}, snapshot['revision'])
        with patch.object(reload, 'process_ticks', return_value='123456789012345678'):
            result = reload.request_reload(['titlebar'])
        self.assertTrue(result['id']); self.assertEqual(reload.revision('theme'), reload.read('request')['titlebar_revision'])
        self.assertFalse(reload.pending())
        (self.repo/'.toolbox-controls.json').write_text(json.dumps({'version':1,'module_theme_enabled':False}), encoding='utf-8')
        self.assertFalse(titlebar.plan()['enabled'])

    def test_titlebar_details_do_not_export_free_form_metadata(self):
        reload.write('result', {'status':'completed','details':{'titlebar':{'matched':2,'applied':1,'failed':1,'title':'PRIVATE_SENTINEL'},'unknown':{'path':'PRIVATE_SENTINEL'}},'errors':{'titlebar':'no_windows'}})
        result=reload.snapshot()['result']
        self.assertNotIn('PRIVATE_SENTINEL',json.dumps(result)); self.assertEqual(1,result['details']['titlebar']['applied'])

    def test_displayed_revision_cannot_apply_external_target_changes(self):
        displayed=reload.revision('theme')
        path=config.module_path('theme');path.write_text('[titlebar]\nprocess_names=["AnotherApp"]\n',encoding='utf-8')
        with self.assertRaisesRegex(reload.ReloadError,'reload_config_changed'):reload.request_reload(['titlebar'],displayed)
        self.assertFalse(reload.state_path('request').exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell operation contract')
    def test_owned_process_window_identity_fallback_and_readback_without_real_actions(self):
        script = self.repo/'titlebar-probe.ps1'
        script.write_text('''param([string]$Root)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'tools/raycast-scripts/_lib/TitlebarSupport.ps1')
$time=[DateTime]::UtcNow
$own=[pscustomobject]@{Id=41;ProcessName='Fixture';StartTime=$time;HasExited=$false}
$reused=[pscustomobject]@{Id=41;ProcessName='Fixture';StartTime=$time.AddSeconds(1);HasExited=$false}
$plan=[pscustomobject]@{enabled=$true;mode='dark';process_names=@('Fixture')}
$script:sets=0;$script:attribute=0
$parameters=@{Plan=$plan;ProcessProvider={@($own)};WindowProvider={@([IntPtr]1,[IntPtr]2)};OwnerProvider={param($Handle) if($Handle -eq 1){41}else{99}};IdentityProvider={$own};Setter={param($Handle,$Attribute,$Value) $script:sets++;$script:attribute=$Attribute;if($Attribute -eq 20){-1}else{0}};Reader={param($Handle,$Attribute) @{Hr=0;Value=1}}}
$result=Invoke-ToolboxTitlebarPlan @parameters
if($result.applied -ne 1 -or $result.matched -ne 1 -or $script:sets -ne 2 -or $script:attribute -ne 19){throw 'fallback did not verify same attribute or changed foreign window'}
$parameters.IdentityProvider={$reused};$script:sets=0
$result=Invoke-ToolboxTitlebarPlan @parameters
if($result.failed -ne 1 -or $script:sets){throw 'reused PID was changed'}
$parameters.IdentityProvider={$own};$parameters.Reader={@{Hr=0;Value=0}}
$result=Invoke-ToolboxTitlebarPlan @parameters
if($result.applied -or $result.failed -ne 1){throw 'readback mismatch counted as success'}
$plan.enabled=$false;$script:sets=0
$result=Invoke-ToolboxTitlebarPlan @parameters
if($result.status -ne 'disabled' -or $script:sets){throw 'disabled plan made calls'}
$plan.enabled=$true;$plan.process_names=@()
$result=Invoke-ToolboxTitlebarPlan @parameters
if($result.status -ne 'no_windows' -or $script:sets){throw 'empty names restored defaults'}
$plan.process_names=@('Fixture');$plan.mode='system';$parameters.SystemThemeProvider={0};$parameters.Reader={@{Hr=0;Value=1}}
$result=Invoke-ToolboxTitlebarPlan @parameters
if($result.applied -ne 1){throw 'system snapshot failed'}
''', encoding='ascii')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(script),'-Root',str(ROOT)],capture_output=True,timeout=15)
        self.assertEqual(0,result.returncode,result.stdout+result.stderr)


if __name__ == '__main__': unittest.main()
