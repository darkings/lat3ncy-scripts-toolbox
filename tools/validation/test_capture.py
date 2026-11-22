"""Capture settings and completion contracts with private files and fake clipboard."""
import json
import hashlib
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
import toolbox_configuration as config
import toolbox_preferences as prefs
import toolbox_status as status


@unittest.skipUnless(os.name=='nt','Windows capture helpers')
class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.repo=Path(self.temp.name)/'repo with spaces';self.capture=self.repo/'tools/raycast-scripts/capture';self.capture.mkdir(parents=True)
        for name in ('CaptureSupport.ps1','CaptureRuntime.ps1','watch-save.ps1','config.toml'):
            shutil.copy(ROOT/'tools/raycast-scripts/capture'/name,self.capture/name)
        shutil.copy(ROOT/'tools/ToolboxControls.ps1',self.repo/'tools/ToolboxControls.ps1')
        for module in (config,prefs):
            replacement=patch.object(module,'REPO',self.repo);replacement.start();self.addCleanup(replacement.stop)

    def ps(self,body):
        script=self.repo/'fixture.ps1'
        script.write_text("param([string]$Repo)\n$ErrorActionPreference='Stop'\n[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n. (Join-Path $Repo 'tools/raycast-scripts/capture/CaptureSupport.ps1')\n. (Join-Path $Repo 'tools/raycast-scripts/capture/CaptureRuntime.ps1')\n"+body,encoding='utf-8-sig')
        result=subprocess.run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',str(script),'-Repo',str(self.repo)],capture_output=True,timeout=15)
        self.assertEqual(0,result.returncode,result.stdout.decode('utf-8-sig',errors='replace')+result.stderr.decode('utf-8-sig',errors='replace'))
        return result.stdout.decode('utf-8-sig')

    def test_default_and_native_changes_reach_the_actual_consumer(self):
        before=json.loads(self.ps("Get-ToolboxCaptureOptions Screenshot $Repo | ConvertTo-Json -Compress"))
        self.assertTrue(before['Enabled']);self.assertTrue(before['CopyToClipboard']);self.assertEqual(180,before['WaitTimeoutSeconds'])
        config.save('capture',{'record.copy_to_clipboard':False,'record.wait_timeout_s':3600,'record.extra_directory':r'copies/中文 # [video]'},config.snapshot('capture')['revision'])
        result=json.loads(self.ps("Get-ToolboxCaptureOptions Record $Repo | ConvertTo-Json -Compress"))
        self.assertTrue(result['Enabled']);self.assertFalse(result['CopyToClipboard']);self.assertEqual(3600,result['WaitTimeoutSeconds']);self.assertEqual('copies/中文 # [video]',result['ExtraDirectory'])

    def test_invalid_configuration_and_policy_fail_closed(self):
        path=self.capture/'config.toml'
        for text in ('[record]\nenabled="true"','[record]\nwait_timeout_s=1','[record]\nenabled=true\nenabled=false','[unknown]\nenabled=true','[record]\nextra_directory=$(Get-Process)','[record]\nextra_directory="bad\\npath"'):
            path.write_text(text,encoding='utf-8')
            result=json.loads(self.ps("Get-ToolboxCaptureOptions Record $Repo | ConvertTo-Json -Compress"))
            self.assertFalse(result['Valid']);self.assertFalse(result['Enabled'])
        path.unlink()
        (self.repo/'.toolbox-controls.json').write_text('{"version":1,"module_capture_enabled":false}',encoding='utf-8')
        result=json.loads(self.ps("Get-ToolboxCaptureOptions Screenshot $Repo | ConvertTo-Json -Compress"))
        self.assertFalse(result['Enabled'])

    def test_latest_same_mode_session_wins_and_expired_sessions_stop(self):
        self.ps('''$options=Get-ToolboxCaptureOptions Screenshot $Repo
$a=New-ToolboxCaptureSession Screenshot $options $Repo
$b=New-ToolboxCaptureSession Screenshot $options $Repo
$c=New-ToolboxCaptureSession Record (Get-ToolboxCaptureOptions Record $Repo) $Repo
if(Test-ToolboxCaptureSession $Repo Screenshot $a.id){throw 'old session retained'}
if(-not (Test-ToolboxCaptureSession $Repo Screenshot $b.id)){throw 'new session missing'}
if(-not (Test-ToolboxCaptureSession $Repo Record $c.id)){throw 'record session interrupted'}
$b.deadlineUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')
$b | ConvertTo-Json -Depth 4 | Set-Content (Get-ToolboxCaptureSessionPath $Repo Screenshot) -Encoding UTF8
if(Test-ToolboxCaptureSession $Repo Screenshot $b.id){throw 'expired session retained'}
''')

    def test_cancel_does_not_reselect_an_old_file_or_an_edited_file(self):
        self.ps('''$dir=Join-Path $Repo 'captures';[void][IO.Directory]::CreateDirectory($dir)
$since=[DateTime]::Parse('2020-01-01T00:00:00Z').ToUniversalTime()
$path=Join-Path $dir 'old.png';[IO.File]::WriteAllText($path,'fixed fixture')
[IO.File]::SetCreationTimeUtc($path,$since.AddMinutes(-5));[IO.File]::SetLastWriteTimeUtc($path,$since.AddSeconds(1))
if(Find-ToolboxCaptureFile $dir @('.png') $since){throw 'edited old file selected'}
$new=Join-Path $dir 'new.png';[IO.File]::WriteAllText($new,'new fixture')
[IO.File]::SetCreationTimeUtc($new,$since.AddSeconds(1));[IO.File]::SetLastWriteTimeUtc($new,$since.AddSeconds(1))
$selected=Find-ToolboxCaptureFile $dir @('.png') $since
if(-not $selected -or $selected.Name -ne 'new.png' -or [IO.File]::ReadAllText($selected.FullName) -ne 'new fixture'){
    Write-Output ('threshold='+$since.ToString('o')+' kind='+$since.Kind)
    Get-ChildItem -LiteralPath $dir | Select-Object Name,CreationTimeUtc,LastWriteTimeUtc | Format-List | Out-String | Write-Output
    Write-Output ('selected='+$selected.Name)
    throw 'new file not selected'
}
''')

    def test_recording_must_release_writer_and_be_stable(self):
        self.ps('''$path=Join-Path $Repo 'record.mp4'
$writer=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try{$writer.WriteByte(42);$writer.Flush();if(Wait-ToolboxCaptureStable $path ([DateTime]::UtcNow.AddMilliseconds(100)) {$true} 10){throw 'open recording completed'}}finally{$writer.Dispose()}
if(-not (Wait-ToolboxCaptureStable $path ([DateTime]::UtcNow.AddSeconds(1)) {$true} 10)){throw 'closed recording never stable'}
if(Wait-ToolboxCaptureStable $path ([DateTime]::UtcNow.AddSeconds(1)) {$false} 10){throw 'superseded recording completed'}
''')

    def test_extra_copy_is_unique_atomic_and_keeps_existing_files(self):
        self.ps('''$source=Join-Path $Repo 'capture.png';[IO.File]::WriteAllText($source,'fixed bytes')
$dir=Join-Path $Repo 'copies 中文';[void][IO.Directory]::CreateDirectory($dir)
$existing=Join-Path $dir 'capture.png';[IO.File]::WriteAllText($existing,'keep me')
$a=Copy-ToolboxCaptureExtra $source $dir $Repo {$true}
$b=Copy-ToolboxCaptureExtra $source $dir $Repo {$true}
if($a -eq $b -or [IO.File]::ReadAllText($a) -ne 'fixed bytes' -or [IO.File]::ReadAllText($existing) -ne 'keep me'){throw 'extra copy overwritten'}
if(@(Get-ChildItem -LiteralPath $dir -Filter '*.tmp').Count){throw 'unfinished copy retained'}
if((Copy-ToolboxCaptureExtra $source $Repo $Repo {$true}) -ne $source){throw 'same folder duplicated'}
''')

    def test_clipboard_option_and_optional_directory_failure_are_independent(self):
        self.ps('''$script:copies=0
function Copy-CaptureFileToClipboard {param($Path,$Mode) $script:copies++}
$source=Join-Path $Repo 'capture.png';[IO.File]::WriteAllText($source,'fixed bytes')
$options=@{ExtraDirectory='';CopyToClipboard=$false}
Complete-ToolboxCapture $source $options $Repo Screenshot {$true}
if($script:copies){throw 'clipboard option ignored'}
$options.CopyToClipboard=$true;$options.ExtraDirectory=$source
Complete-ToolboxCapture $source $options $Repo Screenshot {$true}
if($script:copies -ne 1){throw 'copy failure blocked clipboard'}
Complete-ToolboxCapture $source $options $Repo Screenshot {$false}
if($script:copies -ne 1){throw 'stale session copied'}
''')

    def test_watcher_cleans_event_subscriptions_when_cancelled_or_timed_out(self):
        self.ps('''$dir=Join-Path $Repo 'captures';[void][IO.Directory]::CreateDirectory($dir)
$before=@(Get-EventSubscriber).Count
$result=Wait-ToolboxCaptureFile $dir @('.mp4') ([DateTime]::UtcNow) ([DateTime]::UtcNow.AddSeconds(1)) {$false}
if($result -or @(Get-EventSubscriber).Count -ne $before){throw 'cancel leaked subscriptions'}
$result=Wait-ToolboxCaptureFile $dir @('.mp4') ([DateTime]::UtcNow) ([DateTime]::UtcNow.AddMilliseconds(50)) {$true}
if($result -or @(Get-EventSubscriber).Count -ne $before){throw 'timeout leaked subscriptions'}
''')

    def test_disabled_entries_cannot_launch_protocol_or_inject_keys(self):
        lib=self.repo/'tools/raycast-scripts/_lib';lib.mkdir()
        (lib/'notify.ps1').write_text("function Start-Process {throw 'native action blocked'}\nfunction Add-Type {throw 'native input blocked'}\nfunction Show-SystemToast {throw 'toast blocked'}\n",encoding='ascii')
        (self.capture/'config.toml').write_text('[screenshot]\nenabled=false\n[record]\nenabled=false\n',encoding='ascii')
        for name in ('screenshot.ps1','record-screen.ps1'):
            target=self.capture.parent/name;shutil.copy(ROOT/'tools/raycast-scripts'/name,target)
            result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(target)],capture_output=True,timeout=5)
            self.assertEqual(0,result.returncode)
        self.assertFalse((self.repo/'.toolbox-state').exists())


class StatusPrivacyTests(unittest.TestCase):
    def test_limited_queries_cannot_claim_a_process_is_absent(self):
        result=status.sanitize({'residents':{'powerPolicy':{'status':'not-running'},'caret':{'status':'missing'}}},{},'', '',limited=True)
        rows={row['id']:row for row in result['components']}
        self.assertEqual('query-failed',rows['powerPolicy']['state'])
        self.assertEqual('query-failed',rows['caret']['state'])

    def test_power_heartbeat_requires_current_identity_checkout_and_freshness(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'repo';power=root/'tools/power-policy';power.mkdir(parents=True)
            names=['PowerPolicy.ps1','PowerPolicy.Core.ps1','PowerNative.cs','PowerPolicy.Identity.ps1','Repair-TaskHost.ps1','Run-PowerPolicy.vbs','config.toml','..\\ToolboxControls.ps1']
            lines=[]
            for name in names:
                path=power/name.replace('\\','/');path.write_text('fixed private fixture',encoding='utf-8')
                lines.append(name+'|'+hashlib.sha256(path.read_bytes()).hexdigest().upper())
            state=Path(folder)/'profile/AppData/Local/lat3ncy-toolbox/power-policy-status.json';state.parent.mkdir(parents=True)
            beat={'identityVersion':1,'repoRoot':str(root),'scriptPath':str(power/'PowerPolicy.ps1'),'pid':42,'startTicks':'1234567890','updatedUtc':datetime.now(timezone.utc).isoformat(),'sourceFingerprint':hashlib.sha256('\n'.join(lines).encode()).hexdigest()}
            with patch.object(status,'ROOT',root),patch.dict(os.environ,{'USERPROFILE':str(Path(folder)/'profile')}),patch.object(status,'process_identity',return_value=('powershell.exe','1234567890')) as identity:
                state.write_text(json.dumps(beat),encoding='utf-8');self.assertEqual('running',status.verified_power())
                (power/'PowerPolicy.Core.ps1').write_text('changed fixture',encoding='utf-8');self.assertEqual('outdated',status.verified_power())
                identity.return_value=('powershell.exe','9876543210');self.assertIsNone(status.verified_power())
                identity.return_value=('powershell.exe','1234567890')
                beat['updatedUtc']=(datetime.now(timezone.utc)-timedelta(seconds=120)).isoformat();state.write_text(json.dumps(beat),encoding='utf-8');self.assertIsNone(status.verified_power())

    def test_status_bridge_exports_only_fixed_states_and_build_ids(self):
        runtime={'residents':{'hud':{'status':'running','command':'PRIVATE_SECRET'},'ahk':{'status':'PRIVATE_SECRET'},'rgb':{'status':'running','path':'PRIVATE_SECRET'}}}
        result=status.sanitize(runtime,{'rgb':False},'PRIVATE_SECRET','PRIVATE_SECRET')
        self.assertNotIn('PRIVATE_SECRET',json.dumps(result))
        rows={row['id']:row for row in result['components']}
        self.assertEqual('running',rows['hud']['state']);self.assertEqual('query-failed',rows['ahk']['state']);self.assertEqual('disabled',rows['rgb']['state'])
        self.assertEqual('process-only',rows['rgb']['evidence'])


if __name__=='__main__':unittest.main()
