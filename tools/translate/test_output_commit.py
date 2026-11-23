"""A reader's short Windows handle must not turn a completed result into failure."""
import ctypes
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

import translate as tr


class OutputCommitTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.output = self.directory / 'result.txt'
        self.output.write_text('status=progress\ntext=fixed fixture', encoding='utf-8')

    def test_transient_windows_replace_errors_retry_then_publish_exact_result(self):
        replace = tr.os.replace
        for code in (5, 32, 33):
            error = PermissionError('PRIVATE_SENTINEL'); error.winerror = code
            with mock.patch.object(tr.os, 'replace') as publish, mock.patch.object(tr.time, 'sleep') as delay:
                def attempt(source, target):
                    if publish.call_count == 1: raise error
                    return replace(source, target)
                publish.side_effect = attempt
                tr._atomic_long_output(str(self.output), 'ok', text='fixed translation')
                self.assertEqual(2, publish.call_count); delay.assert_called_once_with(.015)
            self.assertEqual('status=ok\ntext=fixed translation\n', self.output.read_text(encoding='utf-8'))
            self.assertFalse(list(self.directory.glob('*.tmp')))

    def test_persistent_lock_is_bounded_and_preserves_previous_output(self):
        before = self.output.read_bytes()
        error = PermissionError('PRIVATE_SENTINEL'); error.winerror = 5
        with mock.patch.object(tr.os, 'replace', side_effect=error) as publish, mock.patch.object(tr.time, 'sleep') as delay:
            with self.assertRaises(PermissionError): tr._atomic_long_output(str(self.output), 'ok', text='fixed translation')
            self.assertEqual(4, publish.call_count)
            self.assertEqual([mock.call(.015), mock.call(.03), mock.call(.045)], delay.call_args_list)
        self.assertEqual(before, self.output.read_bytes()); self.assertFalse(list(self.directory.glob('*.tmp')))

    def test_other_io_failures_are_not_retried(self):
        with mock.patch.object(tr.os, 'replace', side_effect=FileNotFoundError()) as publish, mock.patch.object(tr.time, 'sleep') as delay:
            with self.assertRaises(FileNotFoundError): tr._atomic_long_output(str(self.output), 'ok', text='fixed translation')
            self.assertEqual(1, publish.call_count); delay.assert_not_called()

    @unittest.skipUnless(os.name == 'nt', 'Windows file sharing')
    def test_real_reader_handle_released_during_commit(self):
        from ctypes import wintypes as w
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE]
        kernel.CreateFileW.restype = w.HANDLE; kernel.CloseHandle.argtypes = [w.HANDLE]
        handle = kernel.CreateFileW(str(self.output), 0x80000000, 3, None, 3, 0, None)
        self.assertNotIn(handle, (None, w.HANDLE(-1).value))
        released = threading.Event()
        def release():
            kernel.CloseHandle(handle); released.set()
        # Release on the first real sharing failure, rather than relying on scheduler speed.
        replace = tr.os.replace; attempts = []
        def publish(source, target):
            try: return replace(source, target)
            except OSError:
                attempts.append(True)
                if not released.is_set(): release()
                raise
        try:
            with mock.patch.object(tr.os, 'replace', side_effect=publish):
                tr._atomic_long_output(str(self.output), 'ok', text='fixed translation')
        finally:
            if not released.is_set(): release()
        self.assertTrue(attempts); self.assertTrue(released.is_set())
        self.assertIn('status=ok', self.output.read_text(encoding='utf-8'))
        self.assertFalse(list(self.directory.glob('*.tmp')))


if __name__ == '__main__': unittest.main()
