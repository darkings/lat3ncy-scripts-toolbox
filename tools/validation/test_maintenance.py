"""Maintenance is fixed-scope, serialized and cannot interrupt capture sessions."""
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
from datetime import datetime, timezone, timedelta

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import toolbox_reload as reload
import toolbox_status as status
import toolbox_capture_activity as activity
import toolbox_controls as controls
import toolbox_configuration as config
import toolbox_preferences as prefs


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.repo=Path(self.temp.name)/'fixture repo';(self.repo/'ahk').mkdir(parents=True)
        shutil.copy(ROOT/'ahk/shortcuts.ahk',self.repo/'ahk')
        for module,spec in config.MODULES.items():
            path=self.repo/spec['path'];path.parent.mkdir(parents=True,exist_ok=True);path.write_text('',encoding='utf-8')
        for target in (config,controls,prefs):
            p=patch.object(target,'REPO',self.repo);p.start();self.addCleanup(p.stop)
        p=patch.object(reload,'process_ticks',return_value='123456789012345678');p.start();self.addCleanup(p.stop)

    def record(self,state='waiting',*,valid=True):
        directory=self.repo/'.toolbox-state';directory.mkdir(exist_ok=True)
        session={'version':1,'id':'b'*32,'mode':'Record','deadlineUtc':(datetime.now(timezone.utc)+timedelta(minutes=5)).isoformat()}
        (directory/'capture-record.json').write_text(json.dumps(session) if valid else 'PRIVATE_BROKEN_SENTINEL',encoding='utf-8')
        result={'version':1,'id':'b'*32,'mode':'Record','state':state}
        (directory/'capture-result-record.json').write_text(json.dumps(result),encoding='utf-8')

    def test_manual_reload_does_not_fabricate_pending_or_modify_config(self):
        before={m:config.module_path(m).read_bytes() for m in reload.MODULES}
        response=reload.request_reload(['power'])
        self.assertEqual('power',reload.read('request')['actions']);self.assertTrue(response['id'])
        self.assertFalse(reload.pending())
        for module,raw in before.items():self.assertEqual(raw,config.module_path(module).read_bytes())

    def test_unconsumed_request_and_live_old_worker_are_both_busy(self):
        reload.request_reload(['power'])
        with self.assertRaisesRegex(reload.ReloadError,'reload_busy'):reload.request_reload(['theme'])
        request=reload.read('request');request['created_unix']-=300;reload.write('request',request)
        reload.write('result',{'id':request['id'],'status':'running','worker_pid':99,'worker_ticks':'123456789012345678'})
        with self.assertRaisesRegex(reload.ReloadError,'reload_busy'):reload.request_reload(['theme'])

    def test_recording_and_unknown_capture_state_block_reload_without_writing(self):
        self.record()
        with self.assertRaisesRegex(reload.ReloadError,'reload_capture_busy'):reload.request_reload(['power'])
        self.assertFalse(reload.state_path('request').exists())
        self.record(valid=False)
        with self.assertRaisesRegex(reload.ReloadError,'reload_capture_unavailable'):reload.request_reload(['power'])
        self.assertFalse(reload.state_path('request').exists())
        self.record('completed');self.assertTrue(reload.request_reload(['power'])['id'])

    def test_module_allowlist_and_disabled_policy_are_enforced(self):
        for modules in ([],['shell'],['power','theme'],['power','power'],'power',[{}]):
            with self.subTest(modules=modules),self.assertRaises(reload.ReloadError):reload.request_reload(modules)
        controls.save({'module_rgb_enabled':False},controls.snapshot()['revision'])
        with self.assertRaisesRegex(reload.ReloadError,'reload_disabled'):reload.request_reload(['rgb'])
        self.assertFalse(reload.state_path('request').exists())

    def test_reload_errors_export_only_fixed_categories(self):
        reload.write('result',{'status':'completed','errors':{'power':'PRIVATE_SENTINEL','theme':'ownership','arbitrary':'PRIVATE_SENTINEL'}})
        result=reload.snapshot()
        self.assertNotIn('PRIVATE_SENTINEL',json.dumps(result));self.assertEqual({'theme':'ownership'},result['result']['errors'])

    @unittest.skipUnless(os.name=='nt','Windows request guard and ownership')
    def test_worker_record_guard_and_owned_hud_stopper_have_no_foreign_side_effect(self):
        script=self.repo/'guard.ps1'
        script.write_text('''param([string]$Root,[string]$Repo)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'tools/settings/ReloadSupport.ps1')
if((Get-SettingsRecordingState $Repo) -ne 'idle'){throw 'empty record state wrong'}
$dir=Join-Path $Repo '.toolbox-state';[void][IO.Directory]::CreateDirectory($dir)
$s=@{version=1;id=('b'*32);mode='Record';deadlineUtc=[DateTime]::UtcNow.AddMinutes(1).ToString('o')}
$s|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $dir 'capture-record.json') -Encoding UTF8
if((Get-SettingsRecordingState $Repo) -ne 'active'){throw 'active recording not blocked'}
@{version=1;id=$s.id;mode='Record';state='completed'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $dir 'capture-result-record.json') -Encoding UTF8
if((Get-SettingsRecordingState $Repo) -ne 'idle'){throw 'completed recording not released'}
. (Join-Path $Root 'tools/startup/ToolboxProcess.ps1')
$script:stops=0;$time=[DateTime]::UtcNow
# Match the canonical process path; hosted TEMP may use an 8.3 user directory.
$own=[pscustomobject]@{Id=41;Path=[IO.Path]::GetFullPath((Join-Path $Repo 'tools/ime-hud-winui/out/ImeHudWinUi.exe'));StartTime=$time;HasExited=$false}
$foreign=[pscustomobject]@{Id=42;Path='C:\\another-checkout\\ImeHudWinUi.exe';StartTime=$time;HasExited=$false}
$rejected=$false
try{Stop-ToolboxOwnedHudProcess $Repo -ProcessProvider {@($own,$foreign)} -IdentityProvider {$own} -Stopper {$script:stops++}}catch{$rejected=$true}
if(-not $rejected -or $script:stops){throw 'foreign HUD could be stopped'}
$changed=[pscustomobject]@{Id=41;Path=$own.Path;StartTime=$time.AddSeconds(1);HasExited=$false}
$rejected=$false
try{Stop-ToolboxOwnedHudProcess $Repo -ProcessProvider {@($own)} -IdentityProvider {$changed} -Stopper {$script:stops++}}catch{$rejected=$true}
if(-not $rejected -or $script:stops){throw 'reused PID could be stopped'}
Stop-ToolboxOwnedHudProcess $Repo -ProcessProvider {@($own)} -IdentityProvider {$own} -Stopper {$script:stops++}
if($script:stops -ne 1){throw 'owned HUD not stopped by fixed operation'}
''',encoding='ascii')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(script),'-Root',str(ROOT),'-Repo',str(self.repo)],capture_output=True,timeout=10)
        self.assertEqual(0,result.returncode,result.stdout+result.stderr)


class FullDiagnosticsTests(unittest.TestCase):
    def test_limited_context_and_dependency_failures_remain_distinct(self):
        rows=status.diagnostic_summary({'modules':{'translate':{'status':'attention','integrity':'low'},'tts':{'status':'attention','tempWritable':False},'ocr':{'status':'attention','integrity':'low','mismatches':['package']}}})
        self.assertEqual(['limited_integrity','temp_unwritable','dependencies'],[row['runtime_reason'] for row in rows])

    def test_full_summary_never_exports_paths_logs_keys_or_free_form_status(self):
        report={'configs':{'translate':{'status':'invalid','key':'PRIVATE_SENTINEL'}},'modules':{'tts':{'status':'attention','mismatches':['PRIVATE_SENTINEL'],'path':'PRIVATE_SENTINEL'},'ocr':{'status':'PRIVATE_SENTINEL'}},'logs':{'text':'PRIVATE_SENTINEL'}}
        rows=status.diagnostic_summary(report)
        self.assertNotIn('PRIVATE_SENTINEL',json.dumps(rows));self.assertEqual(1,rows[1]['dependency_mismatches']);self.assertEqual('query-failed',rows[2]['runtime_state'])

    def test_full_read_only_collection_can_skip_all_log_reads(self):
        spec=importlib.util.spec_from_file_location('maintenance_doctor',ROOT/'tools/diagnostics/doctor.py')
        doctor=importlib.util.module_from_spec(spec);spec.loader.exec_module(doctor)
        with patch.object(doctor,'run_json',return_value={'residents':{'hud':{'status':'running'}},'ocr':{}}),patch.object(doctor,'config_summary',return_value={'status':'ok','engine':'rapidocr'}),patch.object(doctor,'select_tts_spec',return_value={}),patch.object(doctor,'inspect_runtime',return_value={'status':'ok'}),patch.object(doctor,'log_summary',side_effect=AssertionError('raw log access forbidden')):
            report=doctor.collect(include_logs=False)
        self.assertEqual({},report['logs']);self.assertEqual(3,len(status.diagnostic_summary(report)))


if __name__=='__main__':unittest.main()
