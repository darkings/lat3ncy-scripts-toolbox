"""Validate snapshot isolation without copying this repository or running hardware."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('clean_checkout', Path(__file__).with_name('clean_checkout.py'))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class SnapshotTests(unittest.TestCase):
    def test_runtime_directories_and_parent_traversal_are_excluded(self):
        for path in ('.tmp/log.txt', 'tools/tts/.venv/Scripts/python.exe', 'tools/x/obj/x.dll', '../escape.txt'):
            self.assertFalse(snapshot.eligible(path), path)
        self.assertTrue(snapshot.eligible('tools/tts/tts_player.py'))

    def test_export_uses_head_config_and_keeps_source_git_state(self):
        with tempfile.TemporaryDirectory(prefix='toolbox-snapshot-') as directory:
            repo = Path(directory)/'source'; repo.mkdir()
            subprocess.run(['git', 'init', '--quiet', str(repo)], check=True, capture_output=True)
            config = repo/'tools/example/config.toml'; config.parent.mkdir(parents=True)
            config.write_text('value = "baseline"', encoding='utf-8')
            (repo/'script.py').write_text('# baseline', encoding='utf-8')
            snapshot.git(repo, 'add', '--all')
            hooks = Path(directory)/'hooks'; hooks.mkdir()
            snapshot.git(repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid',
                         '-c', 'commit.gpgsign=false', '-c', f'core.hooksPath={hooks}', 'commit', '--quiet', '-m', 'fixture')
            config.write_text('value = "personal"', encoding='utf-8')
            (repo/'new.py').write_text('# candidate source', encoding='utf-8')
            (repo/'.tmp').mkdir(); (repo/'.tmp/log.txt').write_text('runtime', encoding='utf-8')
            before = snapshot.git(repo, 'status', '--porcelain')
            head = snapshot.git(repo, 'rev-parse', 'HEAD')
            output = Path(directory)/'candidate'
            records = snapshot.export_candidate(repo, output)
            self.assertEqual('value = "baseline"', (output/'tools/example/config.toml').read_text('utf-8'))
            self.assertEqual('# candidate source', (output/'new.py').read_text('utf-8'))
            self.assertFalse((output/'.tmp').exists())
            self.assertEqual(before, snapshot.git(repo, 'status', '--porcelain'))
            self.assertEqual(head, snapshot.git(repo, 'rev-parse', 'HEAD'))
            self.assertIn('HEAD-config', [entry['origin'] for entry in records])


if __name__ == '__main__':
    unittest.main()
