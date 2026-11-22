"""Settings privacy, isolated overrides and concurrent-writer behavior."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import toolbox_preferences as prefs


class PreferencesTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.repo = self.root / "repo with spaces"
        for section in ("translate", "tts"):
            module = self.repo / "tools" / section
            module.mkdir(parents=True)
            (module / "config.toml").write_text('secret_key="SENSITIVE_SENTINEL"\n', encoding="utf-8")
        self.before = {path: path.read_bytes() for path in self.repo.rglob("*.toml")}
        self.addCleanup(self.assert_configs_unchanged)
        self.repo_patch = patch.object(prefs, "REPO", self.repo)
        self.env_patch = patch.dict(os.environ, {"LOCALAPPDATA": str(self.root / "local")})
        self.repo_patch.start(); self.env_patch.start()
        self.addCleanup(self.repo_patch.stop); self.addCleanup(self.env_patch.stop)

    def assert_configs_unchanged(self):
        for path, before in self.before.items():
            self.assertEqual(before, path.read_bytes())

    def test_snapshot_and_disk_never_copy_credentials(self):
        initial = prefs.snapshot()
        self.assertNotIn("SENSITIVE_SENTINEL", json.dumps(initial))
        result = prefs.save({"translate": {"fallback_on_auth_error": True}, "tts": {"rate": "+20%"}}, initial["revision"])
        self.assertEqual("+20%", result["values"]["tts"]["rate"])
        raw = prefs.preference_path().read_text(encoding="utf-8")
        self.assertNotIn("SENSITIVE_SENTINEL", raw)
        self.assertNotIn("secret_key", raw)
        self.assertEqual({"fallback_on_auth_error": True}, json.loads(raw)["values"]["translate"])

    def test_rejects_secret_keys_unknown_values_and_bad_types_atomically(self):
        initial = prefs.snapshot()
        for changes in ({"translate": {"secret_key": "private"}}, {"tts": {"rate": "+101%"}},
                        {"tts": {"rate": "0%"}}, {"tts": {"pitch": "+5%"}},
                        {"translate": {"fallback_on_auth_error": 1}}, {"translate": {"engine": []}},
                        {"tts": {"en_voice": "voice\nprivate"}}, {"arbitrary": {}}):
            with self.subTest(changes=changes), self.assertRaises(prefs.PreferenceError):
                prefs.save(changes, initial["revision"])
            self.assertFalse(prefs.preference_path().exists())

    def test_partial_apply_preserves_existing_preferences_and_runtime_credentials(self):
        first = prefs.save({"translate": {"target_language": "en"}}, prefs.snapshot()["revision"])
        prefs.save({"tts": {"volume": "-20%"}}, first["revision"])
        cfg = {"target_language": "auto", "secret_key": "kept"}
        actual = prefs.apply_overlay("translate", cfg, self.repo / "tools/translate/config.toml")
        self.assertEqual({"target_language": "en", "secret_key": "kept"}, actual)
        self.assertEqual(cfg, prefs.apply_overlay("translate", cfg, self.root / "standalone.toml"))

    def test_stale_revision_cannot_overwrite_newer_save(self):
        revision = prefs.snapshot()["revision"]
        prefs.save({"translate": {"engine": "google_gtx"}}, revision)
        with self.assertRaisesRegex(prefs.PreferenceError, "settings_changed_reload"):
            prefs.save({"translate": {"engine": "tencent"}}, revision)
        self.assertEqual("google_gtx", prefs.snapshot()["values"]["translate"]["engine"])
        self.assertEqual([], list(prefs.preference_path().parent.glob("*.tmp")))

    def test_corrupt_or_oversized_overlay_is_rejected(self):
        path = prefs.preference_path(); path.parent.mkdir(parents=True)
        for raw in (b'[]', b'{', b'x' * 16385, b'{"version":1,"values":{"tts":{"token":"secret"}}}'):
            path.write_bytes(raw)
            with self.assertRaises(prefs.PreferenceError):
                prefs.snapshot()

    def test_repository_identity_isolates_preferences(self):
        path = prefs.preference_path()
        with patch.object(prefs, "REPO", self.root / "other repo"):
            self.assertNotEqual(path, prefs.preference_path())

    def test_aliases_of_the_same_repository_share_identity_and_effective_config(self):
        canonical = prefs.preference_path()
        with patch.object(prefs, 'REPO', self.repo / 'tools' / '..'):
            self.assertEqual(canonical, prefs.preference_path())
            prefs.save({'translate': {'target_language': 'en'}}, prefs.snapshot()['revision'])
            effective = prefs.apply_overlay('translate', {'target_language': 'auto'}, self.repo / 'tools/translate/config.toml')
            self.assertEqual('en', effective['target_language'])
        self.assertEqual('en', prefs.snapshot()['values']['translate']['target_language'])

    def test_two_real_processes_cannot_silently_lose_a_save(self):
        revision = prefs.snapshot()["revision"]
        code = '''import sys,json
from pathlib import Path
sys.path.insert(0,sys.argv[1]);import toolbox_preferences as p
p.REPO=Path(sys.argv[2])
try:
 p.save({'translate':{'target_language':sys.argv[3]}},sys.argv[4]);print('ok')
except p.PreferenceError as e: print(str(e))
'''
        commands = [[sys.executable, "-I", "-S", "-c", code, str(Path(prefs.__file__).parent),
                     str(self.repo), language, revision] for language in ("en", "zh")]
        processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for command in commands]
        results = [process.communicate(timeout=10) for process in processes]
        self.assertEqual([0, 0], [process.returncode for process in processes], '\n'.join(stderr for _, stderr in results))
        self.assertEqual(["ok", "settings_changed_reload"], sorted(stdout.strip() for stdout, _ in results))
        self.assertTrue(all(not stderr for _, stderr in results))

    @unittest.skipUnless(os.name == 'nt', 'Windows byte-range locking regression')
    def test_empty_lock_file_content_is_not_written_before_its_lock_is_acquired(self):
        import msvcrt
        path = prefs.preference_path().with_suffix('.lock')
        path.parent.mkdir(parents=True)
        attempted = self.root / 'attempted.txt'
        code = '''import sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]);import toolbox_preferences as p;import msvcrt
p.REPO=Path(sys.argv[2]);native=msvcrt.locking
def observe(fd,mode,count):
 if mode==msvcrt.LK_NBLCK:Path(sys.argv[3]).write_text('attempted')
 return native(fd,mode,count)
msvcrt.locking=observe
p.save({'translate':{'target_language':'en'}},p.snapshot()['revision']);print('ok')
'''
        with path.open('a+b') as held:
            msvcrt.locking(held.fileno(), msvcrt.LK_NBLCK, 1)
            process = subprocess.Popen([sys.executable, '-I', '-S', '-c', code, str(Path(prefs.__file__).parent),
                                        str(self.repo), str(attempted)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while not attempted.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
            finally:
                held.seek(0)
                msvcrt.locking(held.fileno(), msvcrt.LK_UNLCK, 1)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(0, process.returncode, stderr)
        self.assertTrue(attempted.exists(), 'writer must acquire the existing empty-file byte lock before touching its content')
        self.assertEqual('ok', stdout.strip())
        self.assertEqual(b'', path.read_bytes())

    def test_real_translation_and_speech_load_the_same_overlay_in_isolated_repo(self):
        source_tools = Path(prefs.__file__).parent
        shutil.copyfile(source_tools / 'toolbox_preferences.py', self.repo / 'tools/toolbox_preferences.py')
        for filename in ('translate.py', 'auth_cooldown.py', 'long_translation.py', 'engine_trace.py'):
            shutil.copyfile(source_tools / 'translate' / filename, self.repo / 'tools/translate' / filename)
        for filename in ('tts_player.py', 'task_protocol.py'):
            shutil.copyfile(source_tools / 'tts' / filename, self.repo / 'tools/tts' / filename)
        prefs.save({'translate': {'source_language': 'en', 'target_language': 'en'}, 'tts': {'rate': '+25%'}}, prefs.snapshot()['revision'])
        output = self.root / 'translation.txt'
        run = subprocess.run([sys.executable, '-I', '-S', str(self.repo / 'tools/translate/translate.py'),
                              '--text', 'fixed text', '--output-file', str(output)], capture_output=True, timeout=10)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertIn('engine=identity', output.read_text('utf-8'))
        self.assertIn('text=fixed text', output.read_text('utf-8'))
        code = 'import sys;sys.path.insert(0,sys.argv[1]);import tts_player;print(tts_player.load_config()["rate"])'
        run = subprocess.run([sys.executable, '-I', '-S', '-c', code, str(self.repo / 'tools/tts')], capture_output=True, timeout=10)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertEqual('+25%', run.stdout.decode('utf-8').strip())


if __name__ == "__main__":
    unittest.main()
