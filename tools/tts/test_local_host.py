"""Profile ownership, local-first routing and cancellable stdin synthesis."""
import asyncio
from contextlib import redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
import tts_player as tts
import tts_runtime as runtime
spec = importlib.util.spec_from_file_location('local_host_installer', Path(__file__).with_name('install-deps.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ProfileTests(unittest.TestCase):
    def test_ownership_is_required_before_readiness_and_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)/'profile'
            first, other = Path(root)/'module one', Path(root)/'module two'
            runtime.claim_profile(directory, first)
            self.assertFalse(runtime.owns_profile(directory, first, ready=True))
            runtime.publish_ready(directory, first)
            self.assertTrue(runtime.owns_profile(directory, first, ready=True))
            with self.assertRaises(ValueError):
                runtime.claim_profile(directory, other)
            self.assertTrue(runtime.owns_profile(directory, first, ready=True))
            self.assertNotEqual(runtime.profile_directory(first, root), runtime.profile_directory(other, root))

    def test_unowned_nonempty_environment_is_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)/'profile'; directory.mkdir()
            sentinel = directory/'unrelated.txt'; sentinel.write_text('keep', encoding='utf-8')
            with self.assertRaises(ValueError):
                runtime.claim_profile(directory, Path(root)/'module')
            self.assertEqual('keep', sentinel.read_text('utf-8'))
            self.assertFalse((directory/'.ready.txt').exists())

    def test_installer_never_executes_a_foreign_profile(self):
        with tempfile.TemporaryDirectory() as root, redirect_stderr(io.StringIO()):
            directory = Path(root)/'profile'; directory.mkdir()
            (directory/'foreign.txt').write_text('keep', encoding='utf-8')
            with patch.object(installer, 'environment_directory', return_value=directory), \
                 patch.object(installer, 'check_environment') as check, \
                 patch.object(sys, 'argv', ['install-deps.py', '--check', '--location', 'profile']):
                self.assertEqual(1, installer.main())
            check.assert_not_called()

    def test_failed_install_revokes_readiness_so_launcher_can_fall_back(self):
        with tempfile.TemporaryDirectory() as root, redirect_stderr(io.StringIO()):
            directory, module = Path(root)/'profile', Path(root)/'module'
            runtime.claim_profile(directory, module)
            runtime.publish_ready(directory, module)
            executable = directory/('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')
            executable.parent.mkdir(); executable.write_bytes(b'fixture')
            failure = installer.subprocess.CalledProcessError(1, 'pip')
            with patch.object(installer, 'ROOT', module), patch.object(installer, 'environment_directory', return_value=directory), \
                 patch.object(installer, 'check_environment', return_value={'status': 'outdated'}), \
                 patch.object(installer.subprocess, 'run', side_effect=[types.SimpleNamespace(returncode=0), failure]), \
                 patch.object(sys, 'argv', ['install-deps.py', '--location', 'profile']):
                self.assertEqual(1, installer.main())
            self.assertTrue(runtime.owns_profile(directory, module))
            self.assertFalse(runtime.owns_profile(directory, module, ready=True))
            runtime.publish_ready(directory, module)
            with patch.object(installer, 'ROOT', module), patch.object(installer, 'environment_directory', return_value=directory), \
                 patch.object(installer, 'check_environment', side_effect=RuntimeError('broken interpreter')), \
                 patch.object(sys, 'argv', ['install-deps.py', '--location', 'profile']):
                self.assertEqual(1, installer.main())
            self.assertFalse(runtime.owns_profile(directory, module, ready=True))


class LocalSynthesisTests(unittest.TestCase):
    def test_private_text_is_stdin_data_and_failed_output_is_not_cached(self):
        process = types.SimpleNamespace(returncode=1, communicate=AsyncMock(return_value=(b'', b'private error')))
        logger = Mock()
        with tempfile.TemporaryDirectory() as root, patch.object(tts, 'get_logger', return_value=logger), \
             patch.object(tts.asyncio, 'create_subprocess_exec', new=AsyncMock(return_value=process)) as spawn:
            text = "private <markup> & 'quotes' 中文"
            path = Path(root)/'output.wav'
            self.assertFalse(asyncio.run(tts.synthesize_sapi_segment('voice', text, 'en', '+0%', '+0Hz', '+0%', str(path))))
            self.assertNotIn(text, str(spawn.call_args))
            payload = json.loads(process.communicate.call_args.args[0])
            self.assertEqual(text, payload['text'])
            self.assertNotIn(text, str(logger.method_calls))
            self.assertEqual([], list(Path(root).iterdir()))

    def test_cancel_kills_child_waits_and_removes_partial_wav(self):
        with tempfile.TemporaryDirectory() as root, patch.object(tts, 'get_logger', return_value=Mock()):
            process = types.SimpleNamespace(returncode=None, kill=Mock(), wait=AsyncMock())
            async def stalled(payload):
                Path(json.loads(payload)['output']).write_bytes(b'partial')
                await asyncio.Event().wait()
            process.communicate = stalled
            with patch.object(tts.asyncio, 'create_subprocess_exec', new=AsyncMock(return_value=process)):
                async def run():
                    with self.assertRaises(TimeoutError):
                        await asyncio.wait_for(tts.synthesize_sapi_segment('voice', 'fixture', 'en', '+0%', '+0Hz', '+0%',
                            str(Path(root)/'output.wav')), .05)
                asyncio.run(run())
            process.kill.assert_called_once()
            process.wait.assert_awaited_once()
            self.assertEqual([], list(Path(root).iterdir()))

    def test_auto_prefers_local_wav_and_reuses_separate_cache_without_online(self):
        with tempfile.TemporaryDirectory() as root:
            async def local(voice, text, lang, rate, pitch, volume, path, **kwargs):
                Path(path).write_bytes(b'wave fixture'*8)
                return True
            sapi, edge = AsyncMock(side_effect=local), AsyncMock(return_value=False)
            async def run():
                events, files = [asyncio.Event()], [None]
                await tts.synthesize_one_segment(0, 'en', 'fixture', 'Microsoft Zira', '+0%', '+0Hz', '+0%',
                    str(Path(root)/'winrt.wav'), 'auto', events, files)
                self.assertTrue(events[0].is_set())
                return files[0]
            with patch.object(tts, 'get_logger', return_value=Mock()), \
                 patch.object(tts, 'synthesize_winrt_segment', new=AsyncMock(return_value=False)), \
                 patch.object(tts, 'synthesize_sapi_segment', new=sapi), patch.object(tts, 'synthesize_edge_segment', new=edge):
                first = asyncio.run(run())
                second = asyncio.run(run())
            self.assertEqual(first, second)
            self.assertTrue(first.endswith('.wav'))
            self.assertNotEqual(str(Path(root)/'winrt.wav'), first)
            self.assertFalse((Path(root)/'winrt.wav').exists())
            self.assertEqual(1, sapi.await_count)
            self.assertEqual(0, edge.await_count)


if __name__ == '__main__':
    unittest.main()
