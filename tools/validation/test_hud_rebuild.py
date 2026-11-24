"""Composite rebuild failures on private artifact fixtures. No actual app/device IO."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOST = str(Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
ARTIFACTS = ('shared/notify/anchor-locator.exe', 'tools/ime-hud-winui/out/ImeHudWinUi.exe',
             'tools/ime-hud-winui/out/ImeHudWinUi.dll', 'tools/ime-hud-winui/out/.source-stamp')

DRIVER = r'''
param($Core,$Support,$Repo,$Scenario)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. $Core
. $Support
$global:trace=@();$global:stops=0;$global:fixtureWork=''
$script:copyOriginal=${function:Copy-ToolboxReleaseFile};$script:copied=0
if($Scenario -eq 'partial'){
 function Copy-ToolboxReleaseFile {
  param($Source,$Destination)
  & $script:copyOriginal $Source $Destination
  $script:copied++
  if($script:copied -eq 2){throw 'injected partial write'}
 }
}
$builder={param($work)
 $global:trace+='build';$global:fixtureWork=$work
 if($Scenario -eq 'build-fail'){throw 'injected build failure'}
 $bundle=Join-Path $work 'bundle'
 $stamp=Get-ImeHudSourceHash (Join-Path $Repo 'tools\ime-hud-winui')
 foreach($relative in @('shared\notify\anchor-locator.exe','tools\ime-hud-winui\out\ImeHudWinUi.exe',
  'tools\ime-hud-winui\out\ImeHudWinUi.dll','tools\ime-hud-winui\out\.source-stamp','tools\ime-hud-winui\out\added.dll')){
  $path=Join-Path $bundle $relative
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  [IO.File]::WriteAllText($path,$(if($relative.EndsWith('.source-stamp')){$stamp}else{'new artifact'}))
 }
 if($Scenario -eq 'forbidden'){
  $path=Join-Path $bundle 'tools\audio-switcher\audio-switcher.exe'
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,'forbidden')
 }
 $candidate=@{Version=1;Repo=[IO.Path]::GetFullPath($Repo);HudSource=$stamp;
  AnchorSource=(Get-FileHash (Join-Path $Repo 'shared\notify\AnchorLocator.cs')).Hash;
  Files=@(Get-ToolboxHudBundleFiles $bundle)}
 [IO.File]::WriteAllText((Join-Path $work 'candidate.json'),($candidate|ConvertTo-Json -Depth 6))
}
$testCandidate={param($work)
 $global:trace+='test'
 [IO.File]::WriteAllText((Join-Path $work 'bundle\tools\ime-hud-winui\out\ImeHudWinUi.log'),'private fixture log; never deployed')
 if($Scenario -eq 'candidate-fail'){throw 'injected candidate self-test failure'}
 if($Scenario -eq 'artifact-drift'){[IO.File]::WriteAllText((Join-Path $work 'bundle\shared\notify\anchor-locator.exe'),'drift')}
}
$stop={
 $global:trace+='stop';$global:stops++
 if($Scenario -eq 'foreign'){throw 'foreign owner fixture'}
 if($Scenario -eq 'source-drift' -and $global:stops -eq 1){[IO.File]::WriteAllText((Join-Path $Repo 'shared\notify\AnchorLocator.cs'),'source changed')}
}
$start={$global:trace+='start'}
$check={
 $global:trace+='health'
 $bytes=[IO.File]::ReadAllText((Join-Path $Repo 'shared\notify\anchor-locator.exe'))
 if($Scenario -eq 'health-fail' -and $bytes -eq 'new artifact'){throw 'injected unhealthy runtime'}
 if($Scenario -eq 'conflict' -and $bytes -eq 'new artifact'){
  [IO.File]::WriteAllText((Join-Path $Repo 'shared\notify\anchor-locator.exe'),'later writer')
  throw 'injected later writer'
 }
 return 'healthy fixture'
}
$installed={$global:trace+='installed-test';if($Scenario -eq 'installed-fail'){throw 'injected installed self-test failure'}}
$failed=$false;$message='';$action=''
try {
 $result=Invoke-ToolboxHudRebuild -Repo $Repo -BuildCandidate $builder -TestCandidate $testCandidate `
  -StopRuntime $stop -StartRuntime $start -CheckRuntime $check -TestInstalled $installed -PlanOnly:($Scenario -eq 'plan')
 $action=$result.Action
}catch{$failed=$true;$message=$_.Exception.Message}
@{failed=$failed;message=$message;trace=$global:trace;action=$action;work=$global:fixtureWork}|ConvertTo-Json -Depth 4 -Compress
'''


@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell release transaction')
class HudRebuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo with spaces 测试'
        for name in (*ARTIFACTS, 'shared/notify/AnchorLocator.cs', 'tools/ime-hud-winui/App.cs',
                     'tools/audio-switcher/audio-switcher.exe', 'tools/power-policy/config.toml'):
            path = self.repo / name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'old artifact')
        self.original = {name: (self.repo / name).read_bytes() for name in ARTIFACTS}
        self.driver = Path(self.temp.name) / 'driver.ps1'
        self.driver.write_text(DRIVER, encoding='utf-8-sig')
        self.env = dict(os.environ)
        self.env['PSMODULEPATH'] = ';'.join((str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/Modules'),
                                           str(Path(os.environ['ProgramFiles']) / 'WindowsPowerShell/Modules')))

    def run_case(self, scenario):
        result = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(self.driver),
                                 str(ROOT / 'tools/startup/HudRebuild.Core.ps1'),
                                 str(ROOT / 'tools/ime-hud-winui/BuildSupport.ps1'), str(self.repo), scenario],
                                capture_output=True, timeout=20, env=self.env)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        report = json.loads(result.stdout.decode('utf-8-sig'))
        for name in ('tools/audio-switcher/audio-switcher.exe', 'tools/power-policy/config.toml'):
            self.assertEqual(b'old artifact', (self.repo / name).read_bytes())
        return report

    def assert_original(self):
        for name, before in self.original.items():
            self.assertEqual(before, (self.repo / name).read_bytes(), name)
        self.assertFalse((self.repo / 'tools/ime-hud-winui/out/added.dll').exists())

    def test_build_and_candidate_failures_never_stop_or_write_production(self):
        for scenario, message in (('build-fail', 'injected build failure'), ('candidate-fail', 'injected candidate self-test failure'),
                                  ('artifact-drift', 'candidate artifact changed'), ('forbidden', 'Unexpected HUD release artifact')):
            report = self.run_case(scenario)
            self.assertTrue(report['failed'], report)
            self.assertIn(message, report['message'])
            self.assertNotIn('stop', report['trace']); self.assert_original()

    def test_plan_builds_and_validates_without_stopping_or_publishing(self):
        report = self.run_case('plan')
        self.assertFalse(report['failed'], report); self.assertEqual('plan', report['action'])
        self.assertEqual(['build', 'test'], report['trace']); self.assert_original()

    def test_success_deploys_both_components_in_one_ordered_transaction(self):
        report = self.run_case('success')
        self.assertFalse(report['failed'], report)
        self.assertEqual(['build', 'test', 'stop', 'installed-test', 'start', 'health'], report['trace'])
        for name in ARTIFACTS[:3]:
            self.assertEqual(b'new artifact', (self.repo / name).read_bytes())
        self.assertTrue((self.repo / 'tools/ime-hud-winui/out/added.dll').exists())
        self.assertFalse((self.repo / 'tools/ime-hud-winui/out/ImeHudWinUi.log').exists())
        releases = list((self.repo / '.tmp/releases').glob('*/manifest.json'))
        self.assertEqual(1, len(releases)); self.assertEqual('healthy', json.loads(releases[0].read_text('utf-8-sig'))['State'])

    def test_installed_or_health_failure_restores_entire_pair_and_old_runtime(self):
        for scenario in ('installed-fail', 'health-fail'):
            report = self.run_case(scenario)
            self.assertTrue(report['failed'], report); self.assert_original()
            self.assertEqual(['stop', 'start', 'health'], report['trace'][-3:])

    def test_partial_write_failure_restores_only_written_files(self):
        report = self.run_case('partial')
        self.assertTrue(report['failed'], report); self.assert_original()
        self.assertIn('injected partial write', report['message'])
        self.assertEqual(['stop', 'start', 'health'], report['trace'][-3:])

    def test_source_change_during_stop_is_rejected_before_first_install(self):
        report = self.run_case('source-drift')
        self.assertTrue(report['failed'], report); self.assert_original()
        self.assertNotIn('installed-test', report['trace'])
        self.assertIn('source changed', report['message']); self.assertEqual('health', report['trace'][-1])

    def test_later_writer_conflict_preserves_newer_bytes_and_backup(self):
        report = self.run_case('conflict')
        self.assertTrue(report['failed'], report)
        self.assertIn('Automatic rollback conflict', report['message'])
        self.assertEqual(b'later writer', (self.repo / ARTIFACTS[0]).read_bytes())
        self.assertTrue(list((self.repo / '.tmp/releases').glob('*/backup/shared/notify/anchor-locator.exe')))

    def test_foreign_runtime_is_never_started_or_published_over(self):
        report = self.run_case('foreign')
        self.assertTrue(report['failed'], report); self.assert_original()
        self.assertNotIn('start', report['trace'])
        self.assertIn('foreign owner fixture', report['message'])

    def test_busy_deployment_lease_rejects_before_build_and_matches_formal_deploy(self):
        holder = Path(self.temp.name) / 'holder.ps1'; ready = Path(self.temp.name) / 'ready'
        holder.write_text(r'''param($Core,$Repo,$Ready)
. $Core
$lease=[Threading.Mutex]::new($false,((Get-ToolboxInstanceName (Join-Path $Repo 'ahk\main.ahk'))+'-Deployment'))
try {$null=$lease.WaitOne();[IO.File]::WriteAllText($Ready,'ready');Start-Sleep -Seconds 30}
finally{$lease.ReleaseMutex();$lease.Dispose()}
''', encoding='ascii')
        child = subprocess.Popen([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(holder),
                                  str(ROOT / 'tools/startup/HudRebuild.Core.ps1'), str(self.repo), str(ready)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=0x08000000, env=self.env)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.03)
            if not ready.exists():
                child.kill(); stdout, stderr = child.communicate(timeout=5)
                self.fail(f'Lease fixture failed: {stdout!r} {stderr!r}')
            report = self.run_case('success')
            self.assertTrue(report['failed']); self.assertIn('Another deployment', report['message'])
            self.assertEqual([], report['trace']); self.assert_original()
            # The actual legacy restart entry must reject the same lease before
            # reaching CIM/process operations, not merely after HUD has stopped.
            startup = self.repo / 'tools/startup'; startup.mkdir()
            power = self.repo / 'tools/power-policy'
            shutil.copyfile(ROOT / 'tools/startup/ToolboxProcess.ps1', startup / 'ToolboxProcess.ps1')
            shutil.copyfile(ROOT / 'tools/power-policy/PowerPolicy.Identity.ps1', power / 'PowerPolicy.Identity.ps1')
            scripts = self.repo / 'tools/raycast-scripts'; (scripts / '_lib').mkdir(parents=True)
            (self.repo / 'ahk').mkdir(); (self.repo / 'ahk/main.ahk').write_text('fixture; never executed')
            (scripts / '_lib/settings.ps1').write_text('function Test-ToolboxRaycastCommandEnabled {return $true}')
            (scripts / '_lib/notify.ps1').write_text("function Show-SystemToast {param($Title,$Message) if($Message -notmatch 'Another deployment'){throw 'unexpected restart body'}}")
            entry = scripts / 'restart-autohotkey.ps1'
            shutil.copyfile(ROOT / 'tools/raycast-scripts/restart-autohotkey.ps1', entry)
            restart = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(entry)],
                                     capture_output=True, env=self.env, timeout=10)
            self.assertEqual(1, restart.returncode, restart.stdout + restart.stderr)
            self.assertNotIn(b'unexpected restart body', restart.stdout + restart.stderr)
        finally:
            child.kill(); child.wait(timeout=5)
            child.stdout.close(); child.stderr.close()

    def test_windows_powershell_child_clears_incompatible_parent_module_path(self):
        probe = Path(self.temp.name) / 'modules.ps1'
        result_path = Path(self.temp.name) / 'modules.json'
        probe.write_text("param($Result)\n@{hash=(Get-FileHash $PSCommandPath).Hash;modules=$env:PSMODULEPATH}|ConvertTo-Json -Compress|Set-Content -LiteralPath $Result -Encoding UTF8", encoding='ascii')
        launcher = Path(self.temp.name) / 'launcher.ps1'
        launcher.write_text(r'''param($Runtime,$HostExe,$Probe,$Result)
$ErrorActionPreference='Stop'
. $Runtime
$env:PSMODULEPATH='INCOMPATIBLE_FIXTURE_MODULE_PATH'
Invoke-ToolboxReleaseProcess $HostExe @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Probe,$Result)
if($env:PSMODULEPATH -ne 'INCOMPATIBLE_FIXTURE_MODULE_PATH'){throw 'parent environment changed'}
''', encoding='ascii')
        run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(launcher),
                              str(ROOT / 'tools/startup/Deployment.Runtime.ps1'), HOST, str(probe), str(result_path)],
                             capture_output=True, env=self.env, timeout=15)
        self.assertEqual(0, run.returncode, run.stdout + run.stderr)
        result = json.loads(result_path.read_text('utf-8-sig'))
        self.assertEqual(64, len(result['hash']))
        self.assertNotIn('INCOMPATIBLE', result['modules'])

    def test_actual_raycast_entry_delegates_once_without_output_or_direct_mutation(self):
        scripts = self.repo / 'tools/raycast-scripts'; (scripts / '_lib').mkdir(parents=True)
        startup = self.repo / 'tools/startup'; startup.mkdir()
        (scripts / '_lib/settings.ps1').write_text('function Test-ToolboxRaycastCommandEnabled {return $true}')
        (scripts / '_lib/notify.ps1').write_text("function Show-SystemToast {param($Title,$Message) [IO.File]::WriteAllText((Join-Path $env:LAT3NCY_HUD_FIXTURE 'notified'),'yes')}")
        (startup / 'Deployment.Runtime.ps1').write_text(r'''function Invoke-ToolboxReleaseProcess {
 param($Exe,[string[]]$Arguments,$TimeoutMs)
 if($Exe -ine (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -or $TimeoutMs -ne 600000){throw 'wrong worker'}
 if(($Arguments[0..3] -join ',') -ne '-NoProfile,-ExecutionPolicy,Bypass,-File' -or
  $Arguments.Count -ne 5 -or $Arguments[4] -ine (Join-Path $env:LAT3NCY_HUD_FIXTURE 'tools\startup\Rebuild-ToolboxHud.ps1')){throw 'wrong rebuild arguments'}
 [IO.File]::WriteAllText((Join-Path $env:LAT3NCY_HUD_FIXTURE 'called'),'yes')
}
''', encoding='ascii')
        entry = scripts / 'reload-ime-hud.ps1'
        shutil.copyfile(ROOT / 'tools/raycast-scripts/reload-ime-hud.ps1', entry)
        env = dict(self.env, LAT3NCY_HUD_FIXTURE=str(self.repo))
        run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(entry)],
                             capture_output=True, env=env, timeout=10)
        self.assertEqual(0, run.returncode, run.stdout + run.stderr)
        self.assertEqual(b'', run.stdout); self.assertEqual(b'', run.stderr)
        self.assertTrue((self.repo / 'called').exists()); self.assertTrue((self.repo / 'notified').exists())
        self.assert_original()

    def test_runtime_stop_rechecks_pinned_processes_and_targets_quit_to_owner(self):
        script = Path(self.temp.name) / 'runtime-stop.ps1'
        script.write_text(r'''param($Runtime,$Repo,$Scenario)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. $Runtime
Add-Type 'public static class ToolboxReleaseHudProbe { public static int OwnerPid=81002,LastQuit=0; public static int Owner(){return OwnerPid;} public static bool Quit(int pid){LastQuit=pid;return true;} }'
function Initialize-ToolboxHudProbe {}
$global:trace=@();$global:disposed=@()
$when=[datetime]::Parse('2026-01-01T01:00:00Z').ToUniversalTime()
$global:ahk=[pscustomobject]@{Id=81001;Handle=1;HasExited=$false;StartTime=$when;ProcessName='AutoHotkey64'}
$global:hud=[pscustomobject]@{Id=81002;Handle=1;HasExited=$false;StartTime=$when;ProcessName='ImeHudWinUi'}
foreach($process in @($global:ahk,$global:hud)){
 $process | Add-Member ScriptMethod Dispose {$global:disposed+=$this.Id}
 $process | Add-Member ScriptMethod WaitForExit {param($Ms) $this.HasExited=$true;return $true}
}
$global:cim=[pscustomobject]@{ProcessId=81001;Name='AutoHotkey64.exe';CreationDate=$when;
 CommandLine=('AutoHotkey64.exe "'+(Join-Path $Repo 'ahk\main.ahk')+'"')}
function Get-ToolboxReleaseRuntime {return [pscustomobject]@{Ahk=@($global:cim);Hud=@($global:hud)}}
function Get-Process {param($Id,$ErrorAction) if($Id -ne 81001){throw 'wrong process query'};return $global:ahk}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)
 if($Scenario -eq 'cim-reused'){return [pscustomobject]@{CreationDate=$when.AddSeconds(1)}}
 return $global:cim
}
function Stop-Process {param($InputObject,[switch]$Force,$ErrorAction)
 if(-not [object]::ReferenceEquals($InputObject,$global:ahk)){throw 'wrong stop object'}
 $global:trace+='stop-ahk';$global:ahk.HasExited=$true
 if($Scenario -eq 'hud-reused'){$global:hud.StartTime=$when.AddSeconds(1)}
}
if($Scenario -eq 'ahk-reused'){$global:ahk.StartTime=$when.AddSeconds(1)}
if($Scenario -eq 'foreign-window'){[ToolboxReleaseHudProbe]::OwnerPid=99999}
$failed=$false
try{Stop-ToolboxReleaseRuntime $Repo}catch{$failed=$true}
@{failed=$failed;trace=$global:trace;quit=[ToolboxReleaseHudProbe]::LastQuit;disposed=$global:disposed}|ConvertTo-Json -Compress
''', encoding='ascii')
        for scenario in ('success', 'ahk-reused', 'cim-reused', 'hud-reused', 'foreign-window'):
            with self.subTest(scenario=scenario):
                run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script),
                                      str(ROOT / 'tools/startup/Deployment.Runtime.ps1'), str(self.repo), scenario],
                                     capture_output=True, env=self.env, timeout=15)
                self.assertEqual(0, run.returncode, run.stdout + run.stderr)
                result = json.loads(run.stdout.decode('utf-8-sig'))
                self.assertEqual(scenario != 'success', result['failed'], result)
                self.assertEqual(81002 if scenario == 'success' else 0, result['quit'], result)
                self.assertEqual(['stop-ahk'] if scenario in ('success', 'hud-reused') else [], result['trace'])
                self.assertIn(81002, result['disposed'])

    def test_native_probe_rejects_wrong_owner_without_sending_quit(self):
        script = Path(self.temp.name) / 'probe.ps1'
        script.write_text(r'''param($Runtime)
$ErrorActionPreference='Stop'
. $Runtime
Initialize-ToolboxHudProbe
if([ToolboxReleaseHudProbe]::Ping(2147483647) -or [ToolboxReleaseHudProbe]::Quit(2147483647)){throw 'wrong owner accepted'}
''', encoding='ascii')
        run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script),
                              str(ROOT / 'tools/startup/Deployment.Runtime.ps1')],
                             capture_output=True, env=self.env, timeout=15)
        self.assertEqual(0, run.returncode, run.stdout + run.stderr)

    def test_source_fingerprint_matches_relative_and_windows_short_paths(self):
        script = Path(self.temp.name) / 'fingerprint.ps1'
        script.write_text(r'''param($Support,$Repo)
$ErrorActionPreference='Stop'
. $Support
Add-Type 'using System;using System.Text;using System.Runtime.InteropServices;public static class FixtureShortPath {[DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern uint GetShortPathName(string path,StringBuilder result,uint size);}'
$project=Join-Path $Repo 'tools\ime-hud-winui'
$expected=Get-ImeHudSourceHash $project
Push-Location $Repo
try {if((Get-ImeHudSourceHash 'tools\ime-hud-winui') -cne $expected){throw 'relative fingerprint differs'}}finally{Pop-Location}
$buffer=[Text.StringBuilder]::new(32768)
$size=[FixtureShortPath]::GetShortPathName($project,$buffer,32768)
if(-not $size -or $size -ge 32768){throw 'short-path fixture unavailable'}
if((Get-ImeHudSourceHash $buffer.ToString()) -cne $expected){throw 'short-path fingerprint differs'}
''', encoding='ascii')
        run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script),
                              str(ROOT / 'tools/ime-hud-winui/BuildSupport.ps1'), str(self.repo)],
                             capture_output=True, env=self.env, timeout=15)
        self.assertEqual(0, run.returncode, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
