"""Engine routing, recovery cache format and failure reporting; no real audio."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
import tts_player as tts
spec = importlib.util.spec_from_file_location('tts_installer', Path(__file__).with_name('install-deps.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class RecoveryTests(unittest.TestCase):
    def test_explicit_engine_wins_over_voice_name(self):
        self.assertEqual(('edge', 'en-US-AriaNeural'), tts.synthesis_target('edge', 'Microsoft Zira', 'en'))
        self.assertEqual(('winrt', 'Microsoft Zira'), tts.synthesis_target('winrt', 'Microsoft Zira', 'en'))

    def run_segment(self, directory, engine):
        async def edge(voice, text, rate, pitch, volume, path, **kwargs):
            Path(path).write_bytes(b'valid audio fixture')
            return True
        events = [asyncio.Event()]
        results = [None]
        online = AsyncMock(side_effect=edge)
        with patch.object(tts, 'synthesize_winrt_segment', new=AsyncMock(return_value=False)), \
             patch.object(tts, 'synthesize_sapi_segment', new=AsyncMock(return_value=False)), \
             patch.object(tts, 'synthesize_edge_segment', new=online), patch.object(tts, 'get_logger', return_value=Mock()):
            asyncio.run(tts.synthesize_one_segment(0, 'en', 'fixture', 'Microsoft Zira', '+0%', '+0Hz', '+0%',
                str(Path(directory)/'local.wav'), engine, events, results))
        self.assertTrue(events[0].is_set())
        return online, results[0]

    def test_auto_recovers_into_distinct_mp3_cache_and_reuses_it(self):
        with tempfile.TemporaryDirectory() as directory:
            online, result = self.run_segment(directory, 'auto')
            self.assertEqual(1, online.await_count)
            self.assertTrue(result.endswith('.mp3'))
            self.assertFalse((Path(directory)/'local.wav').exists())
            online, reused = self.run_segment(directory, 'auto')
            self.assertEqual(0, online.await_count)
            self.assertEqual(result, reused)

    def test_explicit_winrt_failure_never_contacts_online(self):
        with tempfile.TemporaryDirectory() as directory:
            online, result = self.run_segment(directory, 'winrt')
            self.assertEqual(0, online.await_count)
            self.assertIsNone(result)

    def test_failed_sapi_is_not_success_and_does_not_leak_text(self):
        logger = Mock()
        with patch.object(tts, 'get_logger', return_value=logger), \
             patch.object(tts.subprocess, 'run', return_value=types.SimpleNamespace(returncode=1)) as run:
            self.assertFalse(tts.play_sapi_fallback("private text with 'quotes'"))
        self.assertTrue(run.call_args.kwargs['capture_output'])
        self.assertNotIn('private text', str(logger.method_calls))

    def test_mci_open_failure_returns_false(self):
        fake = types.SimpleNamespace(winmm=types.SimpleNamespace(mciSendStringW=Mock(side_effect=[0, 5])))
        with patch.object(tts.sys, 'platform', 'win32'), patch.object(tts.ctypes, 'windll', fake, create=True), \
             patch.object(tts, 'get_logger', return_value=Mock()):
            self.assertFalse(tts.play_audio_file('fixture.mp3'))

    def test_top_level_error_has_nonzero_exit(self):
        with patch.object(tts, 'main_async', new=AsyncMock(side_effect=RuntimeError('failure'))), \
             patch.object(tts, 'get_logger', return_value=Mock()), patch.object(tts, 'log_error'):
            self.assertEqual(1, tts.main())

    def test_exhausted_backends_fail_the_pipeline_after_cleanup(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(tts.sys, 'argv', ['tts_player.py', '--text', 'fixture']), \
             patch.object(tts, 'get_logger', return_value=Mock()), \
             patch.object(tts, 'get_default_cache_dir', return_value=directory), \
             patch.object(tts, 'load_config', return_value={'engine': 'winrt'}), \
             patch.object(tts, 'synthesize_winrt_segment', new=AsyncMock(return_value=False)), \
             patch.object(tts, 'synthesize_edge_segment', new=AsyncMock()) as edge, \
             patch.object(tts, 'play_sapi_fallback', return_value=False), \
             patch.object(tts, 'prune_lru_cache') as prune:
            with self.assertRaisesRegex(RuntimeError, 'TTS playback failed'):
                asyncio.run(tts.main_async())
            prune.assert_called_once()
            self.assertEqual(0, edge.await_count)


class EnvironmentTests(unittest.TestCase):
    def test_cache_falls_back_when_profile_directory_cannot_be_written(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)/'profile'
            module = Path(directory)/'module'; module.mkdir()
            original_open = open
            def guarded(path, *args, **kwargs):
                if str(path).startswith(str(profile)):
                    raise PermissionError('profile is not writable')
                return original_open(path, *args, **kwargs)
            with patch.dict('os.environ', {'LOCALAPPDATA': str(profile)}), \
                 patch.object(tts, '__file__', str(module/'tts_player.py')), patch('builtins.open', side_effect=guarded):
                self.assertEqual(str(module/'.cache'), tts.get_default_cache_dir())
            self.assertEqual([], list((module/'.cache').iterdir()))

    def test_missing_environment_does_not_use_global_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual('missing', installer.check_environment(Path(directory)/'absent.exe')['status'])

    def test_installed_old_edge_is_outdated(self):
        versions = installer.expected_versions()
        versions['edge-tts'] = '7.2.8'
        with patch.object(installer.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0, stdout=json.dumps(versions))):
            report = installer.check_environment(Path(sys.executable))
        self.assertEqual('outdated', report['status'])
        self.assertEqual('7.2.8', report['mismatches']['edge-tts']['actual'])


if __name__ == '__main__':
    unittest.main()
