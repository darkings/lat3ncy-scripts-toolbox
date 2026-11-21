"""Validate snapshot isolation without copying this repository or running hardware."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('clean_checkout', Path(__file__).with_name('clean_checkout.py'))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)
spec = importlib.util.spec_from_file_location('clipboard_fixture', Path(__file__).with_name('clipboard_fixture.py'))
clipboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clipboard)


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


class ClipboardFixtureTests(unittest.TestCase):
    def test_dib_memory_is_transferred_only_after_successful_set(self):
        for succeeds in (True, False):
            with self.subTest(succeeds=succeeds):
                kernel, user, image = Mock(), Mock(), Mock()
                kernel.GlobalAlloc.return_value = 7
                kernel.GlobalLock.return_value = 11
                user.CreateWindowExW.return_value = 31
                user.OpenClipboard.return_value = 1
                user.EmptyClipboard.return_value = 1
                user.SetClipboardData.return_value = 7 if succeeds else 0
                image.convert.return_value = image
                image.save.side_effect = lambda target, **kwargs: target.write(b'0'*14+b'fixed DIB')
                lease = Path('owned-sequence.txt')
                with patch.object(clipboard.ctypes, 'WinDLL', side_effect=[kernel, user], create=True), \
                     patch.object(clipboard.ctypes, 'memmove'), \
                     patch.object(clipboard.ctypes, 'WinError', return_value=OSError('fixture failure'), create=True), \
                     patch.object(clipboard, 'record_sequence') as record:
                    if succeeds:
                        clipboard.copy_image(image, lease)
                    else:
                        with self.assertRaises(OSError):
                            clipboard.copy_image(image, lease)
                user.OpenClipboard.assert_called_once_with(31)
                user.SetClipboardData.assert_called_once_with(8, 7)
                user.CloseClipboard.assert_called_once()
                user.DestroyWindow.assert_called_once_with(31)
                record.assert_called_once_with(lease)
                if succeeds:
                    kernel.GlobalFree.assert_not_called()
                else:
                    kernel.GlobalFree.assert_called_once_with(7)


if __name__ == '__main__':
    unittest.main()
