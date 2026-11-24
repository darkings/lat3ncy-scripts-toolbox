"""Last capture receipts and caret ownership proof. No screen or clipboard access."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timezone, timedelta

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import toolbox_capture_activity as activity
import toolbox_status as status
import test_capture as fixtures


@unittest.skipUnless(os.name=='nt','Windows capture publication')
class CaptureReceiptTests(unittest.TestCase):
    setUp=fixtures.CaptureTests.setUp
    ps=fixtures.CaptureTests.ps

    def test_session_receipt_tracks_processing_options_without_private_values(self):
        self.ps('''$options=Get-ToolboxCaptureOptions Screenshot $Repo
$options.ExtraDirectory='PRIVATE_DIRECTORY_SENTINEL'
$s=New-ToolboxCaptureSession Screenshot $options $Repo
$path=Join-Path $Repo '.toolbox-state/capture-result-screenshot.json'
$r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if($r.state -ne 'waiting' -or $r.id -ne $s.id){throw 'initial receipt missing'}
if([IO.File]::ReadAllText($path).Contains('PRIVATE_DIRECTORY_SENTINEL')){throw 'directory leaked'}
$options.CopyToClipboard=$false;$options.ExtraDirectory=''
$s=New-ToolboxCaptureSession Screenshot $options $Repo
$r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if($r.state -ne 'processing_disabled' -or $r.clipboard -ne 'off' -or $r.extra_copy -ne 'off'){throw 'disabled receipt wrong'}
''')

    def test_old_worker_cannot_overwrite_new_session_and_timeout_can_be_recorded(self):
        self.ps('''$options=Get-ToolboxCaptureOptions Record $Repo
$a=New-ToolboxCaptureSession Record $options $Repo
$b=New-ToolboxCaptureSession Record $options $Repo
Set-ToolboxCaptureResult $Repo Record $a.id completed none success success
$path=Join-Path $Repo '.toolbox-state/capture-result-record.json'
$r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if($r.id -ne $b.id -or $r.state -ne 'waiting'){throw 'old worker replaced receipt'}
$b.deadlineUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')
$b|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Get-ToolboxCaptureSessionPath $Repo Record) -Encoding UTF8
Set-ToolboxCaptureResult $Repo Record $b.id timeout no_file
$r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if($r.state -ne 'timeout' -or $r.reason -ne 'no_file'){throw 'expired session could not report timeout'}
''')

    def test_partial_result_preserves_independent_success_and_safe_failure(self):
        self.ps('''function Copy-CaptureFileToClipboard {param($Path,$Mode) throw 'PRIVATE_FAILURE_SENTINEL'}
$options=Get-ToolboxCaptureOptions Screenshot $Repo;$options.ExtraDirectory='copies'
$s=New-ToolboxCaptureSession Screenshot $options $Repo
$source=Join-Path $Repo 'PRIVATE_FILENAME_SENTINEL.png';[IO.File]::WriteAllText($source,'fixed fixture')
$r=Complete-ToolboxCapture $source $options $Repo Screenshot {$true}
if($r.state -ne 'partial' -or $r.clipboard -ne 'failed' -or $r.extra_copy -ne 'success'){throw 'partial result lost'}
Set-ToolboxCaptureResult $Repo Screenshot $s.id $r.state none $r.clipboard $r.extra_copy
$text=[IO.File]::ReadAllText((Join-Path $Repo '.toolbox-state/capture-result-screenshot.json'))
if($text -match 'PRIVATE_|fixed fixture'){throw 'receipt leaked private data'}
''')

    def test_real_observer_finishes_private_fixture_and_records_result(self):
        # Override only the private copy's directory lookup. Never inspect a system capture folder.
        with (self.capture/'CaptureRuntime.ps1').open('a',encoding='utf-8') as stream:
            stream.write("\nfunction Get-ToolboxKnownFolderPath { param($FolderId,$FallbackPath) return (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'fixed-captures') }\n")
        self.ps('''$options=Get-ToolboxCaptureOptions Record $Repo
$options.CopyToClipboard=$false;$options.ExtraDirectory='copies';$options.WaitTimeoutSeconds=10
$s=New-ToolboxCaptureSession Record $options $Repo
$dir=Join-Path $Repo 'fixed-captures';[void][IO.Directory]::CreateDirectory($dir)
[IO.File]::WriteAllText((Join-Path $dir 'fixed-record.mp4'),'fixed fixture bytes')
& (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $Repo 'tools/raycast-scripts/capture/watch-save.ps1') -Mode Record -SessionId $s.id
$r=Get-Content -LiteralPath (Join-Path $Repo '.toolbox-state/capture-result-record.json') -Raw | ConvertFrom-Json
if($r.state -ne 'completed' -or $r.extra_copy -ne 'success' -or $r.clipboard -ne 'off'){throw 'observer did not finish'}
if(@(Get-ChildItem (Join-Path $Repo 'copies') -Filter '*.mp4').Count -ne 1){throw 'private copy missing'}
''')


class CaptureActivityPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.state=self.root/'.toolbox-state';self.state.mkdir()
        self.now=datetime(2026,11,23,tzinfo=timezone.utc)
        self.session={'version':1,'id':'a'*32,'mode':'Screenshot','deadlineUtc':(self.now+timedelta(seconds=30)).isoformat(),'options':{'ExtraDirectory':'PRIVATE_SENTINEL'}}
        self.result={'version':1,'id':'a'*32,'mode':'Screenshot','state':'completed','reason':'none','clipboard':'success','extra_copy':'off','updated_utc':self.now.isoformat(),'file':'PRIVATE_SENTINEL'}
        p=patch.object(activity,'ROOT',self.root);p.start();self.addCleanup(p.stop)

    def write(self):
        (self.state/'capture-screenshot.json').write_text(json.dumps(self.session),encoding='utf-8')
        (self.state/'capture-result-screenshot.json').write_text(json.dumps(self.result),encoding='utf-8')

    def test_export_is_bounded_correlated_and_redacted(self):
        self.write();result=activity.snapshot(self.now)
        self.assertEqual('completed',result['items'][0]['state']);self.assertEqual('none',result['items'][1]['state'])
        self.assertNotIn('PRIVATE_SENTINEL',json.dumps(result));self.assertNotIn('a'*32,json.dumps(result))
        self.result['state']='PRIVATE_SENTINEL';self.write()
        self.assertEqual('unavailable',activity.snapshot(self.now)['items'][0]['state'])
        (self.state/'capture-result-screenshot.json').write_bytes(b' '*8193)
        self.assertEqual('unavailable',activity.snapshot(self.now)['items'][0]['state'])

    def test_stale_running_receipt_is_not_presented_as_completed(self):
        self.result['state']='waiting';self.session['deadlineUtc']=(self.now-timedelta(seconds=1)).isoformat();self.write()
        self.assertEqual('interrupted',activity.snapshot(self.now)['items'][0]['state'])
        self.result['state']='timeout';self.result['reason']='no_file';self.write()
        self.assertEqual('timeout',activity.snapshot(self.now)['items'][0]['state'])
        self.session['id']='b'*32;self.write()
        self.assertNotEqual('timeout',activity.snapshot(self.now)['items'][0]['state'])

    def test_caret_proof_requires_checkout_owner_child_and_freshness(self):
        digest=2166136261
        for value in str(self.root.resolve()).rstrip('\\/').lower().encode():digest=((digest^value)*16777619)&0xffffffff
        beat={'version':1,'repo_hash':format(digest,'08x'),'owner_pid':11,'owner_ticks':'111','pid':22,'start_ticks':'222','updated_unix':int(self.now.timestamp())}
        path=self.state/'caret-status.json';path.write_text(json.dumps(beat),encoding='utf-8')
        with patch.object(status,'ROOT',self.root),patch.object(status,'process_identity',side_effect=lambda pid: ('AutoHotkey64.exe','111') if pid==11 else ('powershell.exe','222')):
            self.assertTrue(status.verified_caret(self.now))
            beat['start_ticks']='reused';path.write_text(json.dumps(beat),encoding='utf-8');self.assertFalse(status.verified_caret(self.now))
            beat['start_ticks']='222';beat['updated_unix']-=30;path.write_text(json.dumps(beat),encoding='utf-8');self.assertFalse(status.verified_caret(self.now))
            beat['updated_unix']=int(self.now.timestamp());beat['repo_hash']='00000000';path.write_text(json.dumps(beat),encoding='utf-8');self.assertFalse(status.verified_caret(self.now))


if __name__=='__main__':unittest.main()
