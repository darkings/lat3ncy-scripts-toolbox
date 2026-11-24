"""Actual kernel mutexes use unique fixture names; no RGB, capture or system task IO."""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rgb_runtime import RgbBusy, hardware_writer, quit_requested, verify_hardware_admission


class AdmissionTests(unittest.TestCase):
    def test_disabled_guard_does_not_touch_kernel_objects(self):
        with hardware_writer(enabled=False):
            pass

    def test_admission_accepts_only_bounded_fixed_success(self):
        for status in ('unknown', 'foreign', 'busy'):
            runner = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({'status': status}).encode(), b'PRIVATE_SENTINEL'))
            with self.assertRaisesRegex(RgbBusy, '^rgb-owner-unavailable$'):
                verify_hardware_admission(Path('fixture'), runner=runner)
        for result in (subprocess.CompletedProcess([], 1, b'{}', b'PRIVATE_SENTINEL'),
                       subprocess.CompletedProcess([], 0, b'{' * 5000, b''),
                       subprocess.CompletedProcess([], 0, b'{"status":"ok","private":"PRIVATE_SENTINEL"}', b'')):
            with self.assertRaisesRegex(RgbBusy, '^rgb-owner-unavailable$'):
                verify_hardware_admission(Path('fixture'), runner=Mock(return_value=result))
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, b'{"status":"ok"}', b''))
        verify_hardware_admission(Path('fixture'), runner=runner)
        self.assertEqual(4, runner.call_args.kwargs['timeout'])
        self.assertEqual(0x08000000, runner.call_args.kwargs['creationflags'])

    def test_query_timeout_does_not_expose_exception_content(self):
        with self.assertRaisesRegex(RgbBusy, '^rgb-owner-unavailable$'):
            verify_hardware_admission(Path('fixture'), runner=Mock(side_effect=subprocess.TimeoutExpired('PRIVATE_SENTINEL', 1)))

    def test_quit_request_requires_unexpired_creation_identity_and_is_not_consumed(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'request.flag'
            data={'version':1,'id':'a'*32,'expires_utc':110,'targets':[{'pid':81001,'start_ticks':'123456'},{'pid':81002,'start_ticks':'654321'}]}
            path.write_text(json.dumps(data))
            self.assertTrue(quit_requested(path,identity=(81001,'123456'),now=100))
            self.assertTrue(quit_requested(path,identity=(81002,'654321'),now=100));self.assertTrue(path.exists())
            self.assertFalse(quit_requested(path,identity=(81001,'654321'),now=100))
            self.assertFalse(quit_requested(path,identity=(81001,'123456'),now=111))
            self.assertFalse(quit_requested(path,identity=(81001,'123456'),now=1))
            for invalid in (dict(data,version=True),dict(data,targets=[{'pid':True,'start_ticks':'123456'}]),dict(data,targets=[])):
                path.write_text(json.dumps(invalid));self.assertFalse(quit_requested(path,identity=(81001,'123456'),now=100))
            path.write_bytes(b'['*16385);self.assertFalse(quit_requested(path,identity=(81001,'123456'),now=100))


@unittest.skipUnless(sys.platform == 'win32', 'Windows named mutexes')
class KernelLeaseTests(unittest.TestCase):
    def test_writer_and_control_mutex_exclusion_and_owner_crash_cleanup(self):
        source = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for kind in ('writer', 'control'):
                name = 'Local\\Lat3ncyRgbFixture-' + uuid.uuid4().hex
                ready, release = folder / (kind + '.ready'), folder / (kind + '.release')
                if kind == 'writer':
                    code = '''import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1]);from rgb_runtime import hardware_writer,RgbBusy
try:
 with hardware_writer(name=sys.argv[2]):
  if sys.argv[3]=='hold':
   Path(sys.argv[4]).touch()
   while not Path(sys.argv[5]).exists():time.sleep(.02)
except RgbBusy:sys.exit(2)
'''
                    base = [sys.executable, '-I', '-S', '-c', code, str(source), name]
                else:
                    script = folder / 'control.ps1'
                    script.write_text('''param([string]$Helper,[string]$Name,[string]$Mode,[string]$Ready,[string]$Release)
. $Helper
try {$lease=Enter-RgbOperation -Name $Name}catch{exit 2}
try {if($Mode -eq 'hold'){[IO.File]::WriteAllText($Ready,'ready');while(-not [IO.File]::Exists($Release)){Start-Sleep -Milliseconds 20}}}finally{Exit-RgbOperation $lease}
''', encoding='ascii')
                    base = [str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), str(source / 'RgbRuntime.ps1'), name]
                owner = subprocess.Popen(base + ['hold', str(ready), str(release)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=0x08000000)
                keep = None
                kernel = ctypes.WinDLL('kernel32', use_last_error=True)
                kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
                kernel.CreateMutexW.restype = wintypes.HANDLE
                kernel.CloseHandle.argtypes = [wintypes.HANDLE]
                try:
                    deadline = time.monotonic() + 6
                    while not ready.exists() and owner.poll() is None and time.monotonic() < deadline:
                        time.sleep(.02)
                    self.assertTrue(ready.exists(), kind)
                    # Keep the named object alive after killing its owning fixture thread.
                    keep = kernel.CreateMutexW(None, False, name); self.assertTrue(keep)
                    result = subprocess.run(base + ['probe', str(ready), str(release)], capture_output=True, timeout=6, creationflags=0x08000000)
                    self.assertEqual(2, result.returncode, kind)
                    owner.kill(); owner.communicate(timeout=6)
                    result = subprocess.run(base + ['probe', str(ready), str(release)], capture_output=True, timeout=6, creationflags=0x08000000)
                    self.assertEqual(0, result.returncode, kind)
                finally:
                    if owner.poll() is None: owner.kill()
                    owner.communicate(timeout=6)
                    if keep: kernel.CloseHandle(keep)


if __name__ == '__main__': unittest.main()
