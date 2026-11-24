"""RGB ownership/entry tests using metadata and process stubs, never devices/tasks."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/rgb'))
from rgb_runtime import quit_flag_name, quit_requested
HOST = str(Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')


@unittest.skipUnless(os.name == 'nt', 'Windows process identity')
class RgbOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo with spaces 测试'
        self.rgb = self.repo / 'tools/rgb'; self.rgb.mkdir(parents=True)
        self.env = dict(os.environ, LOCALAPPDATA=str(Path(self.temp.name) / 'state'))

    def ps(self, body):
        script = Path(self.temp.name) / 'probe.ps1'
        prefix = r'''param([string]$Source,[string]$RgbRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $Source 'tools/rgb/RgbRuntime.ps1')
$when=[datetime]::Parse('2026-01-01T01:02:03Z').ToUniversalTime();$ticks=$when.ToFileTimeUtc().ToString()
$row=[pscustomobject]@{Name='pythonw.exe';ProcessId=81001;ParentProcessId=1;CommandLine=('"C:\Python\pythonw.exe" -u "'+$RgbRoot+'\ambient.py"');ExecutablePath='C:\Python\pythonw.exe';CreationDate=$when}
$identity={param($Id) [pscustomobject]@{Status='present';Name='pythonw';StartTicks=$ticks}}
'''
        script.write_text(prefix + body, encoding='utf-8-sig')
        run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), str(ROOT), str(self.rgb)], capture_output=True, env=self.env, timeout=15)
        self.assertEqual(0, run.returncode, run.stdout + run.stderr)
        return run.stdout.decode('utf-8-sig').strip()

    def test_exact_owner_foreign_relative_module_and_unreadable_states(self):
        self.ps(r'''
$s=Get-RgbProcessSnapshot $RgbRoot {$row} $identity
if($s.Status -ne 'running' -or $s.Processes.Count -ne 1){throw 'owned process missing'}
$row.CommandLine='pythonw.exe -u "'+($RgbRoot.Replace('\\','/')+'/ambient.py')+'"'
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'running'){throw 'slash form failed'}
$row.CommandLine='pythonw.exe -u "'+$RgbRoot+'-other\ambient.py"'
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'foreign'){throw 'foreign accepted'}
$row.CommandLine='pythonw.exe -u .\ambient.py'
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'unknown'){throw 'relative accepted'}
$row.CommandLine='pythonw.exe -c "print(123)"'
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'absent'){throw 'unrelated interpreter matched'}
$row.CommandLine=$null
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'unknown'){throw 'unreadable treated absent'}
if((Get-RgbProcessSnapshot $RgbRoot {throw 'private query error'} $identity).Status -ne 'unknown'){throw 'query failure treated absent'}
''')

    def test_creation_identity_reuse_and_helper_prefix_boundary(self):
        self.ps(r'''
$changed={param($Id) [pscustomobject]@{Status='present';Name='pythonw';StartTicks=($when.AddSeconds(1).ToFileTimeUtc().ToString())}}
if((Get-RgbProcessSnapshot $RgbRoot {$row} $changed).Status -ne 'unknown'){throw 'PID reuse accepted'}
$row.Name='hi75.exe';$row.ExecutablePath=Join-Path $RgbRoot 'dist\hi75\hi75.exe'
$identity={param($Id) [pscustomobject]@{Status='present';Name='hi75';StartTicks=$ticks}}
$s=Get-RgbProcessSnapshot $RgbRoot {$row} $identity
if($s.Status -ne 'running' -or $s.Processes[0].Role -ne 'hi75'){throw 'owned helper not recognized'}
$row.ExecutablePath=Join-Path $RgbRoot 'dist-other\hi75.exe'
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'foreign'){throw 'prefix boundary escaped'}
$row.ExecutablePath=$null
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'unknown'){throw 'unreadable helper path accepted'}
''')

    def test_custom_helper_requires_live_verified_parent(self):
        self.ps(r'''
$child=[pscustomobject]@{Name='hi75.exe';ProcessId=81002;ParentProcessId=81001;ExecutablePath='C:\custom\hi75.exe';CommandLine='hi75.exe';CreationDate=$when.AddSeconds(1)}
$identity={param($Id) if($Id -eq 81001){[pscustomobject]@{Status='present';Name='pythonw';StartTicks=$ticks}}else{[pscustomobject]@{Status='present';Name='hi75';StartTicks=$when.AddSeconds(1).ToFileTimeUtc().ToString()}}}
$s=Get-RgbProcessSnapshot $RgbRoot {@($row,$child)} $identity
if($s.Status -ne 'running' -or $s.Processes.Count -ne 2){throw 'verified child rejected'}
$child.ParentProcessId=99999
if((Get-RgbProcessSnapshot $RgbRoot {@($row,$child)} $identity).Status -ne 'foreign'){throw 'foreign orphan accepted'}
''')

    def test_waiters_task_owner_and_ambiguous_options(self):
        self.ps(r'''
$row.Name='powershell.exe';$row.CommandLine='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$RgbRoot+'\Start-Ambient.ps1" -Wait'
$identity={param($Id) [pscustomobject]@{Status='present';Name='powershell';StartTicks=$ticks}}
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'running'){throw 'owned waiter missing'}
$row.CommandLine='powershell.exe -Command Write-Host -File "'+$RgbRoot+'\Start-Ambient.ps1"'
if((Get-RgbProcessSnapshot $RgbRoot {$row} $identity).Status -ne 'absent'){throw 'command operand mistaken for script'}
$action=[pscustomobject]@{Execute='C:\Python\pythonw.exe';Arguments=('-u "'+$RgbRoot+'\ambient.py"');WorkingDirectory=$RgbRoot}
$task=[pscustomobject]@{TaskName='RGB-Ambient';TaskPath='\';State='Running';Actions=@($action)}
if(-not (Get-RgbOwnedTask $RgbRoot {$task})){throw 'owned task missing'}
$action.WorkingDirectory=$RgbRoot+'-other';$rejected=$false
try{Get-RgbOwnedTask $RgbRoot {$task}|Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'foreign task accepted'}
$action.Execute='powershell.exe';$action.Arguments='-NoProfile -File "'+$RgbRoot+'\Start-Ambient.ps1" -Wait'
if(-not (Get-RgbOwnedTask $RgbRoot {$task})){throw 'legacy owned task missing'}
$action.Arguments='-EncodedCommand bogus -File "'+$RgbRoot+'\Start-Ambient.ps1"';$rejected=$false
try{Get-RgbOwnedTask $RgbRoot {$task}|Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'ambiguous task accepted'}
''')

    def test_final_stop_rechecks_identity_and_holds_verified_object(self):
        self.ps(r'''
$expected=[pscustomobject]@{ProcessId=81001;Name='pythonw.exe';StartTicks=$ticks}
$processFixture=[pscustomobject]@{ProcessName='pythonw';StartTime=$when.AddSeconds(1);HasExited=$false}
$script:stops=0;$rejected=$false
try{Stop-RgbVerifiedProcess $expected {$processFixture} {$script:stops++}}catch{$rejected=$true}
if(-not $rejected -or $script:stops){throw 'reused PID stopped'}
$processFixture.StartTime=$when
Stop-RgbVerifiedProcess $expected {$processFixture} {param($value) if(-not [object]::ReferenceEquals($value,$processFixture)){throw 'object changed'};$script:stops++}
if($script:stops -ne 1){throw 'verified stop not called'}
$rejected=$false;try{Stop-RgbVerifiedProcess $expected {throw 'query unavailable'} {$script:stops++}}catch{$rejected=$true}
if(-not $rejected -or $script:stops -ne 1){throw 'query failure stopped a process'}
''')

    def test_admission_excludes_other_writer_or_orphan_but_allows_start_parent(self):
        self.ps(r'''
$owner=[pscustomobject]@{ProcessId=81001;ParentProcessId=81002;Role='ambient';StartTicks=$ticks}
$parent=[pscustomobject]@{ProcessId=81002;ParentProcessId=1;Role='waiter';StartTicks=$when.AddSeconds(-1).ToFileTimeUtc().ToString()}
$snapshot=[pscustomobject]@{Status='running';Processes=@($owner,$parent)}
if((Test-RgbHardwareAdmission $RgbRoot 81001 {$snapshot}) -ne 'ok'){throw 'parent waiter rejected'}
$parent.Role='hi75'
if((Test-RgbHardwareAdmission $RgbRoot 81001 {$snapshot}) -ne 'busy'){throw 'orphan accepted'}
$snapshot.Status='foreign'
if((Test-RgbHardwareAdmission $RgbRoot 81001 {$snapshot}) -ne 'foreign'){throw 'foreign writer accepted'}
$snapshot.Status='running';$snapshot.Processes=@()
if((Test-RgbHardwareAdmission $RgbRoot 81001 {$snapshot}) -ne 'unknown'){throw 'missing owner accepted'}
''')

    def test_reload_uses_verified_stop_and_rechecks_before_start(self):
        (self.rgb / 'Stop-Ambient.ps1').write_text("$global:trace+='stop';$global:task.State='Ready';exit 0", encoding='ascii')
        self.ps(r'''
$global:trace=@();$global:task=[pscustomobject]@{State='Running'}
$script:foreign=$false;$script:orphan=$false
function Get-RgbOwnedTask {if($script:foreign){throw 'rgb-task-owner'};return $global:task}
function Get-RgbProcessSnapshot {return [pscustomobject]@{Status='absent';Processes=@()}}
function Start-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
 if($TaskName -ne 'RGB-Ambient' -or $TaskPath -ne '\'){throw 'wrong task target'}
 $global:trace+='start';$global:task.State='Running'
}
function Start-Sleep {}
Restart-RgbOwnedTask $RgbRoot
if(($global:trace -join ',') -ne 'stop,start'){throw 'reload order'}
$global:trace=@();$script:foreign=$true;$rejected=$false
try{Restart-RgbOwnedTask $RgbRoot}catch{$rejected=$true}
if(-not $rejected -or $global:trace.Count){throw 'foreign task changed'}
$script:foreign=$false;$global:task.State='Ready';Restart-RgbOwnedTask $RgbRoot
if($global:trace.Count){throw 'idle task started'}
$global:task.State='Running'
function Get-RgbProcessSnapshot {return [pscustomobject]@{Status='running';Processes=@([pscustomobject]@{Role='hi75'})}}
$rejected=$false;try{Restart-RgbOwnedTask $RgbRoot}catch{$rejected=$true}
if(-not $rejected -or ($global:trace -join ',') -ne 'stop'){throw 'orphan writer started'}
''')

    def test_quit_scope_matches_python_and_never_uses_legacy_global_flag(self):
        value = self.ps('[IO.Path]::GetFileName((Get-RgbQuitFlag $RgbRoot))')
        self.assertEqual(quit_flag_name(self.rgb), value)
        self.assertNotEqual(quit_flag_name(self.rgb), quit_flag_name(self.rgb.parent / 'other'))
        self.assertNotEqual('rgb-quit.flag', value)

    def test_short_path_scope_expands_existing_prefix_with_missing_leaf(self):
        import ctypes
        from ctypes import wintypes
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.GetShortPathNameW.argtypes=[wintypes.LPCWSTR,wintypes.LPWSTR,wintypes.DWORD]
        kernel.GetShortPathNameW.restype=wintypes.DWORD
        buffer=ctypes.create_unicode_buffer(32768)
        size=kernel.GetShortPathNameW(os.environ['ProgramFiles'],buffer,len(buffer))
        self.assertTrue(0<size<len(buffer))
        short=Path(buffer.value)/'Lat3ncyRgbFixtureMissing'/ 'rgb'
        value=self.ps("[IO.Path]::GetFileName((Get-RgbQuitFlag '"+str(short).replace("'","''")+"'))")
        self.assertEqual(quit_flag_name(short),value)
        self.assertEqual(quit_flag_name(Path(os.environ['ProgramFiles'])/'Lat3ncyRgbFixtureMissing'/'rgb'),value)

    def test_powershell_quit_request_is_readable_by_python_and_cleanup_is_conditional(self):
        text=self.ps(r'''
$s=Get-RgbProcessSnapshot $RgbRoot {$row} $identity
$path=Get-RgbQuitFlag $RgbRoot
$id=Write-RgbQuitRequest $path $s
Clear-RgbQuitRequest $path ('f'*32)
if(-not [IO.File]::Exists($path)){throw 'other request removed'}
[IO.File]::ReadAllText($path)
''')
        data=json.loads(text);path=Path(self.env['LOCALAPPDATA'])/'lat3ncy-toolbox'/quit_flag_name(self.rgb)
        target=data['targets'][0]
        self.assertTrue(quit_requested(path,identity=(target['pid'],target['start_ticks']),now=data['expires_utc']-1))
        self.assertFalse(quit_requested(path,identity=(target['pid'],str(int(target['start_ticks'])+1)),now=data['expires_utc']-1))
        self.ps(r'''
$s=Get-RgbProcessSnapshot $RgbRoot {$row} $identity;$path=Get-RgbQuitFlag $RgbRoot
$old=Write-RgbQuitRequest $path $s;$new=Write-RgbQuitRequest $path $s
Clear-RgbQuitRequest $path $old;if(-not [IO.File]::Exists($path)){throw 'new request removed'}
Clear-RgbQuitRequest $path $new;if([IO.File]::Exists($path)){throw 'own request retained'}
''')

    def test_actual_start_stop_and_toggle_reject_foreign_before_any_mutation(self):
        # Replace only metadata helpers; execute the real entries. Every rejected
        # branch must precede flag writes, process creation and task operations.
        for name in ('Start-Ambient.ps1', 'Stop-Ambient.ps1', 'Install-Ambient.ps1'):
            text = (ROOT / 'tools/rgb' / name).read_text(encoding='utf-8-sig')
            # Only bypass the elevation boundary inside this isolated fixture.
            text = text.replace('if (-not (Test-AmbientAdmin)) {', 'if ($false) {')
            (self.rgb / name).write_text(text, encoding='utf-8-sig')
        scripts = self.repo / 'tools/raycast-scripts'; (scripts / '_lib').mkdir(parents=True)
        shutil.copyfile(ROOT / 'tools/raycast-scripts/toggle-rgb.ps1', scripts / 'toggle-rgb.ps1')
        (self.rgb / 'ambient.py').write_text('raise RuntimeError("HARDWARE_BODY_BLOCKED")')
        (self.repo / 'tools/ToolboxControls.ps1').write_text('function Test-ToolboxModuleEnabled {return $true}', encoding='ascii')
        (scripts / '_lib/settings.ps1').write_text('function Test-ToolboxRaycastCommandEnabled {return $true}', encoding='ascii')
        (scripts / '_lib/notify.ps1').write_text('function Show-SystemToast {}', encoding='ascii')
        helper = self.rgb / 'RgbRuntime.ps1'
        for status in ('foreign', 'unknown'):
            helper.write_text(". '" + str(ROOT / 'tools/rgb/RgbRuntime.ps1').replace("'", "''") + "'\nfunction Enter-RgbOperation {return $null}\nfunction Exit-RgbOperation {}\nfunction Get-RgbProcessSnapshot {return [pscustomobject]@{Status='" + status + "';Processes=@()}}\nfunction Get-RgbOwnedTask {throw 'TASK_BODY_BLOCKED'}\n", encoding='utf-8-sig')
            state = Path(self.env['LOCALAPPDATA']) / 'lat3ncy-toolbox'; state.mkdir(parents=True, exist_ok=True)
            flag = state / 'rgb-disabled.flag'; flag.write_bytes(b'original-fixture')
            for script in (self.rgb / 'Start-Ambient.ps1', self.rgb / 'Stop-Ambient.ps1', self.rgb / 'Install-Ambient.ps1', scripts / 'toggle-rgb.ps1'):
                run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)], capture_output=True, timeout=10, env=self.env)
                self.assertNotEqual(0, run.returncode, script.name)
                self.assertEqual(b'original-fixture', flag.read_bytes())
                self.assertEqual([flag], list(state.iterdir()))
                self.assertNotIn(b'TASK_BODY_BLOCKED', run.stdout + run.stderr)
                self.assertFalse((self.rgb / 'logs').exists())


if __name__ == '__main__': unittest.main()
