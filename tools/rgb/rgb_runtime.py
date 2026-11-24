"""Standard-library ownership guards. Importing this module performs no operations."""
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import hashlib
from functools import lru_cache
import json
import os
from pathlib import Path
import subprocess
import sys
import time

WRITER_MUTEX = r'Global\Lat3ncyRgbHardwareWriter-v1'


class RgbBusy(RuntimeError):
    pass


def quit_flag_name(rgb_root: Path) -> str:
    identity = os.path.abspath(rgb_root).replace('/', '\\').rstrip('\\').lower()
    return 'rgb-quit-' + hashlib.sha256(identity.encode('utf-8')).hexdigest()[:24] + '.flag'


@lru_cache(maxsize=1)
def process_identity():
    if sys.platform != 'win32':
        return None
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE, *([ctypes.POINTER(wintypes.FILETIME)] * 4)]
    kernel.GetProcessTimes.restype = wintypes.BOOL
    times = [wintypes.FILETIME() for _ in range(4)]
    if not kernel.GetProcessTimes(kernel.GetCurrentProcess(), *(ctypes.byref(value) for value in times)):
        return None
    return os.getpid(), str(times[0].dwLowDateTime | (times[0].dwHighDateTime << 32))


def quit_requested(path: Path, *, identity=None, now=None) -> bool:
    try:
        with path.open('rb') as stream:
            raw = stream.read(16385)
        if len(raw) > 16384:
            return False
        data = json.loads(raw)
        now = int(time.time()) if now is None else now
        if (not isinstance(data, dict) or set(data) != {'version', 'id', 'expires_utc', 'targets'}
                or type(data['version']) is not int or data['version'] != 1
                or not isinstance(data['id'], str) or len(data['id']) != 32 or any(c not in '0123456789abcdef' for c in data['id'])
                or type(data['expires_utc']) is not int or not now <= data['expires_utc'] <= now + 30
                or not isinstance(data['targets'], list) or not 1 <= len(data['targets']) <= 64):
            return False
        identity = process_identity() if identity is None else identity
        if identity is None:
            return False
        for target in data['targets']:
            if (not isinstance(target, dict) or set(target) != {'pid', 'start_ticks'}
                    or type(target['pid']) is not int or target['pid'] <= 0
                    or not isinstance(target['start_ticks'], str) or not target['start_ticks'].isascii()
                    or not target['start_ticks'].isdigit() or not 1 <= len(target['start_ticks']) <= 20):
                return False
        return any((target['pid'], target['start_ticks']) == identity for target in data['targets'])
    except (OSError, ValueError, TypeError, RecursionError):
        return False


@contextmanager
def hardware_writer(*, enabled=True, name=WRITER_MUTEX):
    if not enabled:
        yield
        return
    if sys.platform != 'win32':
        raise RgbBusy('rgb-platform-unavailable')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    kernel.CreateMutexW.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.ReleaseMutex.argtypes = [wintypes.HANDLE]
    kernel.ReleaseMutex.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    handle = kernel.CreateMutexW(None, False, name)
    if not handle:
        raise RgbBusy('rgb-writer-unavailable')
    owned = False
    try:
        # WAIT_ABANDONED grants ownership too. A fresh admission check follows.
        owned = kernel.WaitForSingleObject(handle, 0) in (0, 0x80)
        if not owned:
            raise RgbBusy('rgb-writer-busy')
        yield
    finally:
        if owned:
            kernel.ReleaseMutex(handle)
        kernel.CloseHandle(handle)


def verify_hardware_admission(rgb_root: Path, *, runner=subprocess.run) -> None:
    script = Path(__file__).with_name('Check-RgbRuntime.ps1')
    host = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    try:
        result = runner([str(host), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                         '-File', str(script), '-RgbRoot', str(rgb_root), '-OwnerPid', str(os.getpid())],
                        capture_output=True, timeout=4, creationflags=0x08000000)
        if result.returncode != 0 or len(result.stdout) > 4096:
            raise ValueError()
        data = json.loads(result.stdout.decode('utf-8-sig'))
        if data != {'status': 'ok'}:
            raise ValueError()
    except (OSError, ValueError, TypeError, RecursionError, subprocess.SubprocessError):
        raise RgbBusy('rgb-owner-unavailable') from None
