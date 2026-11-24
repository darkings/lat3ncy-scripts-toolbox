"""Managed task contract and timeout tests; never contact TTS or play audio."""
import asyncio
from contextlib import ExitStack
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
import tts_player as tts
from task_protocol import RequestState


class LifecycleTests(unittest.TestCase):
    def tearDown(self):
        tts._TASK = None

    def test_atomic_terminal_record_contains_only_contract_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'result.txt'
            state = RequestState('request-123', str(path))
            state.stage = 'complete'
            state.finish('success')
            self.assertEqual({'version': '1', 'request_id': 'request-123', 'status': 'success',
                              'error_kind': 'none', 'stage': 'complete'},
                             dict(line.split('=', 1) for line in path.read_text('utf-8').splitlines()))
            self.assertEqual(['result.txt'], os.listdir(directory))

    def test_request_identity_cannot_escape_filename_glob(self):
        for value in ('../escape', 'a*b', 'a\nb', 'a.b', 'x'*121):
            with self.assertRaises(ValueError):
                RequestState(value, 'result.txt')

    def test_synthesis_timeout_cleans_partial_file_and_unblocks_consumer(self):
        async def stalled(path):
            Path(path).write_bytes(b'partial fixture')
            await asyncio.Event().wait()
        fake = types.SimpleNamespace(Communicate=lambda *a, **k: types.SimpleNamespace(save=stalled))
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, {'edge_tts': fake}), \
             patch.object(tts, 'get_logger', return_value=Mock()):
            tts._TASK = RequestState('owned-fragment', str(Path(directory)/'result.txt'))
            events, files, errors = [asyncio.Event()], [None], [None]
            asyncio.run(tts.synthesize_one_segment(0, 'en', 'fixture', 'en-US-AriaNeural', '+0%', '+0Hz', '+0%',
                str(Path(directory)/'cache.mp3'), 'edge', events, files, timeout_seconds=0.05, errors=errors))
            self.assertTrue(events[0].is_set())
            self.assertEqual(['timeout'], errors)
            self.assertEqual([None], files)
            self.assertEqual([], os.listdir(directory))

    def test_total_timeout_publishes_terminal_timeout(self):
        async def stalled(args):
            await asyncio.Event().wait()
        with tempfile.TemporaryDirectory() as directory, patch.object(tts, 'get_logger', return_value=Mock()), \
             patch.object(tts, 'run_pipeline', side_effect=stalled), \
             patch.object(sys, 'argv', ['tts_player.py', '--text', 'fixture', '--task-timeout', '0.05',
                 '--request-id', 'deadline', '--result-file', str(Path(directory)/'result.txt')]):
            self.assertEqual(2, tts.main())
            result = (Path(directory)/'result.txt').read_text('utf-8')
            self.assertIn('status=timeout\n', result)
            self.assertIn('error_kind=timeout\n', result)

    def test_cancellation_waits_for_producer_cleanup(self):
        entered, cleaned = [], []
        async def stalled(voice, text, rate, pitch, volume, path, **kwargs):
            entered.append(True)
            try:
                await asyncio.Event().wait()
            finally:
                cleaned.append(True)
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            stack.enter_context(patch.object(tts, 'get_logger', return_value=Mock()))
            stack.enter_context(patch.object(tts, 'get_default_cache_dir', return_value=directory))
            stack.enter_context(patch.object(tts, 'load_config', return_value={'engine': 'edge'}))
            stack.enter_context(patch.object(tts, 'synthesize_edge_segment', side_effect=stalled))
            stack.enter_context(patch.object(tts, 'prune_lru_cache'))
            stack.enter_context(patch.object(sys, 'argv', ['tts_player.py', '--text', 'fixture', '--task-timeout', '0.1']))
            self.assertEqual(2, tts.main())
            self.assertEqual([True], entered)
            self.assertEqual([True], cleaned)

    def test_real_cli_missing_input_reports_failure_without_touching_repo_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = root/'tools/tts'
            module.mkdir(parents=True)
            for name in ('tts_player.py', 'task_protocol.py'):
                shutil.copyfile(Path(tts.__file__).parent/name, module/name)
            for name in ('toolbox_controls.py', 'toolbox_preferences.py'):
                shutil.copyfile(Path(tts.__file__).parent.parent/name, root/'tools'/name)
            run = subprocess.run([sys.executable, str(module/'tts_player.py'), '--input-file', str(root/'missing.txt'),
                '--request-id', 'missing-input', '--result-file', str(root/'result.txt')], capture_output=True, timeout=10)
            self.assertEqual(1, run.returncode)
            result = (root/'result.txt').read_text('utf-8')
            self.assertIn('status=failed\n', result)
            self.assertIn('error_kind=input\n', result)

    def test_bom_only_input_is_an_input_failure_instead_of_false_success(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(tts, 'get_logger', return_value=Mock()):
            root = Path(directory)
            source = root/'input.txt'
            source.write_text(' \r\n', encoding='utf-8-sig')
            with patch.object(sys, 'argv', ['tts_player.py', '--input-file', str(source),
                    '--request-id', 'bom-empty', '--result-file', str(root/'result.txt')]):
                self.assertEqual(1, tts.main())
            self.assertIn('error_kind=input\n', (root/'result.txt').read_text('utf-8'))


if __name__ == '__main__':
    unittest.main()
