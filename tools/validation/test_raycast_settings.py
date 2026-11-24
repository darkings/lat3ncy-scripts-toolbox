"""Raycast entry policy: real PowerShell gates, isolated files, no command bodies."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import toolbox_configuration as config

COMMANDS = ('screenshot', 'record-screen', 'screenshot-ocr', 'screenshot-translate', 'next-wallpaper', 'toggle-rgb')
MAINTENANCE = ('restart-autohotkey', 'reload-ime-hud', 'diagnose-ime-hud-anchor', 'fix-rdp-clipboard-prompt')
NAMES = COMMANDS + MAINTENANCE
FIELDS = {'general.enabled', *('commands.' + x.replace('-', '_') for x in COMMANDS),
          *('maintenance.' + x.replace('-', '_') for x in MAINTENANCE)}
HOST = str(Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')


class RaycastCatalogTests(unittest.TestCase):
    def test_public_catalog_covers_tracked_commands_except_always_available_settings(self):
        spec = config.MODULES['raycast']
        self.assertEqual(FIELDS, {f['key'] for f in spec['fields']})
        self.assertTrue(all(f['type'] == 'bool' and f['default'] is True for f in spec['fields']))
        tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', 'tools/raycast-scripts/*.ps1']).decode().splitlines()
        top = {Path(p).stem for p in tracked if len(Path(p).parts) == 3}
        self.assertEqual(set(NAMES) | {'toolbox-settings'}, top)
        self.assertNotIn('Test-ToolboxRaycastCommandEnabled', (ROOT / 'tools/raycast-scripts/toolbox-settings.ps1').read_text('utf-8-sig'))
        reload = (ROOT / 'tools/raycast-scripts/reload-ime-hud.ps1').read_text('utf-8-sig')
        self.assertNotIn('Stop-Process', reload)
        self.assertIn('Stop-ToolboxOwnedHudProcess -Repo $repositoryRoot', reload)


@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell policy consumer')
class RaycastPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo with spaces'
        self.scripts = self.repo / 'tools/raycast-scripts'
        (self.scripts / '_lib').mkdir(parents=True)
        self.helper = self.scripts / '_lib/settings.ps1'
        shutil.copyfile(ROOT / 'tools/raycast-scripts/_lib/settings.ps1', self.helper)
        self.path = self.scripts / 'config.toml'
        self.probe = self.repo / 'read.ps1'
        names = ','.join("'" + name + "'" for name in NAMES)
        self.probe.write_text("param([string]$Helper,[string]$Repo)\n. $Helper\n$result=@{}\nforeach($name in @(" + names + ")){$result[$name]=Test-ToolboxRaycastCommandEnabled -Command $name -RepoRoot $Repo}\n$result['unknown']=Test-ToolboxRaycastCommandEnabled -Command 'unknown' -RepoRoot $Repo\n$result|ConvertTo-Json -Compress\n", encoding='ascii')

    def read(self):
        run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(self.probe), str(self.helper), str(self.repo)], capture_output=True, timeout=10)
        self.assertEqual(0, run.returncode, run.stderr.decode(errors='replace'))
        return json.loads(run.stdout)

    def test_missing_configuration_retains_defaults_and_unknown_command_is_rejected(self):
        result = self.read()
        self.assertTrue(all(result[n] for n in NAMES)); self.assertFalse(result['unknown'])

    def test_each_saved_entry_switch_matches_runtime_and_master_overrides_all(self):
        for name in NAMES:
            group = 'commands.' if name in COMMANDS else 'maintenance.'
            self.path.write_bytes(config.render(b'', 'raycast', {group + name.replace('-', '_'): False}))
            result = self.read()
            self.assertFalse(result[name])
            blocked = {name, 'reload-ime-hud'} if name == 'restart-autohotkey' else {name}
            self.assertTrue(all(result[n] for n in NAMES if n not in blocked))
            self.assertTrue(all(not result[n] for n in blocked))
        self.path.write_bytes(config.render(b'', 'raycast', {'general.enabled': False}))
        self.assertFalse(any(self.read().values()))

    def test_bom_comments_and_invalid_duplicate_or_oversized_policy_fail_closed(self):
        self.path.write_text('# fixture\n[commands] # group\nscreenshot = false # off\n', encoding='utf-8-sig')
        self.assertFalse(self.read()['screenshot']); self.assertTrue(self.read()['record-screen'])
        for raw in ('[commands]\nscreenshot=false\nscreenshot=true\n', '[general]\nenabled="false"\n', '[general]\n[general]\n', '#' * 16385):
            self.path.write_text(raw)
            self.assertFalse(any(self.read().values()))

    def test_actual_entry_prefixes_gate_before_any_command_body(self):
        # Execute the actual prefix and replace the body with a fixed exception.
        # A regression cannot open capture UI, stop a process or alter system policy.
        for name in NAMES:
            source = (ROOT / 'tools/raycast-scripts' / (name + '.ps1')).read_text('utf-8-sig')
            gate = "if(-not(Test-ToolboxRaycastCommandEnabled -Command '" + name + "')){exit 0}"
            self.assertEqual(1, source.count(gate))
            before, _ = source.split(gate, 1)
            # Only declarations/comments, error preference and our helper load precede the gate.
            executable = before.split('$ErrorActionPreference', 1)[1]
            self.assertNotIn('Start-Process', executable); self.assertNotIn('Add-Type', executable)
            probe = self.scripts / (name + '.ps1')
            probe.write_text(before + gate + '\nthrow "COMMAND_BODY_REACHED"\n', encoding='utf-8-sig')
            self.path.write_bytes(config.render(b'', 'raycast', {'general.enabled': False}))
            run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(probe)], capture_output=True, timeout=10)
            self.assertEqual(0, run.returncode, name)
            self.assertEqual(b'', run.stdout); self.assertEqual(b'', run.stderr)
            self.path.write_bytes(config.render(b'', 'raycast', {'general.enabled': True}))
            run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(probe)], capture_output=True, timeout=10)
            self.assertNotEqual(0, run.returncode, name)
            self.assertIn(b'COMMAND_BODY_REACHED', run.stderr)

    def test_diagnostic_restart_respects_entry_policy_and_child_failure(self):
        source = (ROOT / 'tools/raycast-scripts/diagnose-ime-hud-anchor.ps1').read_text('utf-8-sig')
        branch = source[source.index('if ($Restart) {'):]
        script = self.repo / 'diagnostic-restart.ps1'
        for allowed, child_code in ((False, 0), (True, 9), (True, 0)):
            self.path.write_bytes(config.render(b'', 'raycast', {'maintenance.restart_autohotkey': allowed}))
            prefix = "param([string]$Helper)\n$ErrorActionPreference='Stop'\n. $Helper\n$Restart=$true;$restartAhk='isolated-restart.ps1'\n"
            prefix += "function powershell.exe {$global:LASTEXITCODE=" + str(child_code) + ";Write-Output 'FIXED_CHILD_CALLED'}\n"
            script.write_text(prefix + branch, encoding='utf-8-sig')
            run = subprocess.run([HOST, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), str(self.helper)], capture_output=True, timeout=10)
            if not allowed:
                self.assertEqual(0, run.returncode); self.assertNotIn(b'FIXED_CHILD_CALLED', run.stdout)
                self.assertNotIn(b'Restart done', run.stdout)
            elif child_code:
                self.assertEqual(1, run.returncode); self.assertNotIn(b'Restart done', run.stdout)
            else:
                self.assertEqual(0, run.returncode); self.assertIn(b'Restart done', run.stdout)


if __name__ == '__main__': unittest.main()
