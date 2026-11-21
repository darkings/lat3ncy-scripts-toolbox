"""Report this interpreter's Windows token and TEMP access without elevation."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import sys
import uuid


def inspect_context() -> dict:
    result = {'python': sys.version, 'executable': sys.executable, 'platform': sys.platform}
    if sys.platform != 'win32':
        return {**result, 'status': 'unsupported'}
    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    advapi.IsTokenRestricted.argtypes = [wintypes.HANDLE]
    advapi.GetSidSubAuthorityCount.argtypes = [ctypes.c_void_p]
    advapi.GetSidSubAuthorityCount.restype = ctypes.POINTER(ctypes.c_ubyte)
    advapi.GetSidSubAuthority.argtypes = [ctypes.c_void_p, wintypes.DWORD]
    advapi.GetSidSubAuthority.restype = ctypes.POINTER(wintypes.DWORD)
    token = wintypes.HANDLE()
    if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        size = wintypes.DWORD()
        advapi.GetTokenInformation(token, 25, None, 0, ctypes.byref(size))
        buffer = ctypes.create_string_buffer(size.value)
        if not advapi.GetTokenInformation(token, 25, buffer, size, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        sid = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_void_p))[0]
        count = advapi.GetSidSubAuthorityCount(sid)[0]
        rid = int(advapi.GetSidSubAuthority(sid, count-1)[0])
        result.update({'integrityRid': rid, 'integrity': {4096: 'low', 8192: 'medium', 12288: 'high', 16384: 'system'}.get(rid, 'other'),
                       'restrictedToken': bool(advapi.IsTokenRestricted(token))})
        container = wintypes.DWORD()
        if advapi.GetTokenInformation(token, 29, ctypes.byref(container), ctypes.sizeof(container), ctypes.byref(size)):
            result['appContainer'] = bool(container.value)
    finally:
        kernel.CloseHandle(token)
    temp = os.environ.get('TEMP') or os.environ.get('TMP')
    result['tempDirectory'] = temp
    if temp:
        probe = Path(temp) / ('toolbox-context-'+uuid.uuid4().hex+'.tmp')
        created = False
        try:
            with probe.open('xb') as output:
                created = True
                output.write(b'context probe')
            result['tempWritable'] = True
        except OSError as error:
            result.update({'tempWritable': False, 'tempError': type(error).__name__, 'tempWinError': getattr(error, 'winerror', None)})
        finally:
            if created:
                probe.unlink()
    result['status'] = 'observed'
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = inspect_context()
    except OSError as error:
        result = {'status': 'query-failed', 'errorType': type(error).__name__}
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding='utf-8')
    print(text)
    return 1 if result['status'] == 'query-failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
