"""Workflow delivery, stale screenshots and locked installation without UI/network."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from unittest.mock import Mock, patch

ROOT = Path(__file__).parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT/filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


workflow = load('ocr_workflow_fixture', 'ocr_workflow.py')
runtime = load('ocr_runtime_fixture', 'ocr_runtime.py')
installer = load('ocr_locked_installer', 'install-deps.py')


class WorkflowTests(unittest.TestCase):
    def test_old_image_is_ignored_and_only_new_image_is_recognized(self):
        class Image:
            def close(self): pass
        first, second = Image(), Image()
        core = types.SimpleNamespace(load_engine=Mock(return_value='engine'),
            extract_text=Mock(return_value='fixed\n中文|😀'), _clipboard_sequence=Mock(side_effect=[5, 6]))
        pil = types.SimpleNamespace(Image=types.SimpleNamespace(Image=Image),
            ImageGrab=types.SimpleNamespace(grabclipboard=Mock(side_effect=[first, second])))
        with patch.dict(sys.modules, {'ocr': core, 'PIL': pil}), patch.object(workflow.time, 'sleep'):
            self.assertEqual(('ok', 'fixed\n中文|😀'), workflow.capture_text(5, 1))
        core.extract_text.assert_called_once_with('engine', second)

    def test_no_new_image_cancels_without_reading_or_copying_text(self):
        core = types.SimpleNamespace(load_engine=Mock())
        grab = Mock()
        with patch.dict(sys.modules, {'ocr': core, 'PIL': types.SimpleNamespace(Image=Mock(), ImageGrab=grab)}), \
             patch.object(workflow.time, 'monotonic', side_effect=[0, 2]):
            self.assertEqual(('cancelled', ''), workflow.capture_text(5, 1))
        grab.grabclipboard.assert_not_called()

    def test_result_is_atomic_and_keeps_full_text_or_fixed_error(self):
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory)/'result.txt'
            args = ['ocr_workflow.py', '--request-id', 'owned-1', '--result-file', str(result), '--baseline-sequence', '5']
            for outcome in [('ok', 'English\r\n中文|😀\ntext=literal'), RuntimeError('private exception')]:
                with patch.object(sys, 'argv', args), patch.object(workflow, 'capture_text') as capture:
                    if isinstance(outcome, Exception):
                        capture.side_effect = outcome
                        self.assertEqual(1, workflow.main())
                        self.assertIn('status=error', result.read_text('utf-8'))
                        self.assertNotIn('private', result.read_text('utf-8'))
                    else:
                        capture.return_value = outcome
                        self.assertEqual(0, workflow.main())
                        self.assertEqual(outcome[1], result.read_bytes().decode('utf-8').split('text=', 1)[1])
                self.assertEqual([result], list(Path(directory).iterdir()))

    def test_invalid_identity_or_unavailable_baseline_never_starts_capture(self):
        for request, baseline in [('bad\nidentity', '5'), ('good', '0')]:
            with patch.object(sys, 'argv', ['worker', '--request-id', request, '--result-file', 'unused', '--baseline-sequence', baseline]), \
                 patch.object(workflow, 'capture_text') as capture:
                self.assertEqual(1, workflow.main())
                capture.assert_not_called()


class LockedRuntimeTests(unittest.TestCase):
    def test_all_installed_versions_are_compared_and_mismatch_is_retained(self):
        with patch.object(runtime, 'expected_versions', return_value={'pillow': '13.0.0', 'pyperclip': '1.11.0'}), \
             patch.object(runtime.importlib.metadata, 'version', side_effect=['12.0.0', '1.11.0']):
            result = runtime.installed_status()
        self.assertEqual('outdated', result['status'])
        self.assertEqual({'pillow': {'expected': '13.0.0', 'actual': '12.0.0'}}, result['mismatches'])

    def test_declared_wrong_abi_is_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'.venv314').mkdir()
            (root/'.venv314/pyvenv.cfg').write_text(f'home = {root}\nversion_info = 3.15\n', encoding='utf-8')
            with patch.object(runtime.subprocess, 'run') as execute:
                with self.assertRaises(ValueError): runtime.check_environment(root)
            execute.assert_not_called()

    def test_check_does_not_install_or_download_and_install_uses_module_hash_lock(self):
        with redirect_stdout(io.StringIO()), patch.object(installer, 'check_environment', return_value={'status': 'missing'}), \
             patch.object(installer.subprocess, 'run') as execute, patch.object(installer, 'ensure_mobile_models') as download, \
             patch.object(sys, 'argv', ['installer', '--check']):
            self.assertEqual(1, installer.main())
            execute.assert_not_called(); download.assert_not_called()
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()):
            root = Path(directory); (root/'.venv314').mkdir()
            (root/'.venv314/pyvenv.cfg').write_text('fixture', encoding='utf-8')
            script = root/'install-deps.py'
            config = root/'config.toml'; config.write_text('model="default"\n', encoding='utf-8')
            with patch.object(installer, '__file__', str(script)), patch.object(sys, 'argv', ['installer']), \
                 patch.object(installer, 'check_environment', side_effect=[{'status': 'outdated'}, {'status': 'ready'}]), \
                 patch.object(installer.shutil, 'which', return_value='uv.exe'), patch.object(installer, 'base_python'), \
                 patch.object(installer.subprocess, 'run') as execute:
                self.assertEqual(0, installer.main())
            args = execute.call_args.args[0]
            self.assertIn('--require-hashes', args)
            self.assertIn(str(root/'.venv314/Scripts/python.exe'), args)
            self.assertIn(str(root/'requirements.lock'), args)
            self.assertEqual('model="default"\n', config.read_text('utf-8'))

    def test_corrupted_model_download_never_replaces_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'fixed.onnx'; target.write_bytes(b'original')
            def retrieve(url, path): Path(path).write_bytes(b'corrupted')
            with patch.object(installer, 'MODELS_DIR', directory), patch.object(installer.urllib.request, 'urlretrieve', side_effect=retrieve), redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError): installer.download_model('fixed.onnx', 'fixed', hashlib.sha256(b'expected').hexdigest())
            self.assertEqual(b'original', target.read_bytes())
            self.assertFalse(target.with_suffix('.onnx.part').exists())


if __name__ == '__main__':
    unittest.main()
