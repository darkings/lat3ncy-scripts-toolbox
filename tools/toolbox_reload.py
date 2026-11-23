"""Persist pending module reloads and submit fixed requests to the AHK resident."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolbox_configuration as config
import toolbox_preferences as prefs
import toolbox_controls as controls

MODULES = {'power': '电源与唤醒', 'theme': '主题切换计划', 'rgb': '氛围灯'}


class ReloadError(ValueError): pass


def state_path(name: str) -> Path: return prefs.preference_path().with_name('reload-' + name + '.json')


def read(name: str) -> dict:
    try:
        raw = state_path(name).read_bytes()
        if len(raw) > 8192: raise ReloadError('invalid_reload_state')
        value = json.loads(raw)
        if not isinstance(value, dict): raise ReloadError('invalid_reload_state')
        return value
    except FileNotFoundError: return {}


def write(name: str, value: dict) -> None:
    path = state_path(name); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8'); os.replace(temporary, path)
    finally: temporary.unlink(missing_ok=True)


def revision(module: str) -> str: return hashlib.sha256(config.read_bytes(config.module_path(module))).hexdigest()


def pending() -> dict:
    data = read('pending')
    if set(data) - set(MODULES) or any(not isinstance(value, str) or re.fullmatch('[0-9a-f]{64}', value) is None for value in data.values()):
        raise ReloadError('invalid_reload_state')
    return data


def mark_pending(module: str, keys, digest: str) -> None:
    if module not in MODULES or (module == 'theme' and not any(key.startswith('schedule.') for key in keys)): return
    with prefs._writer_lock(state_path('pending')):
        data = pending(); data[module] = digest; write('pending', data)


def reconcile() -> dict:
    request, result = read('request'), read('result')
    if request.get('id') and request.get('id') == result.get('id') and result.get('status') == 'completed':
        with prefs._writer_lock(state_path('pending')):
            data = pending()
            completed = result.get('completed', '').split(',')
            for module in completed:
                if module in MODULES and module in data and revision(module) == request.get(module + '_revision'):
                    data.pop(module)
            write('pending', data)
    return result


def snapshot() -> dict:
    result = reconcile(); data = pending()
    from toolbox_capture_activity import recording_state
    errors=result.get('errors',{})
    return {'version': 1, 'pending': [{'id': module, 'label': MODULES[module], 'revision': revision(module),
                                     'enabled': controls.module_enabled(module)} for module in data],
            'recording_state': recording_state(config.REPO),
            'result': {**{key: result[key] for key in ('id', 'status', 'completed', 'failed') if key in result},
                       'errors':{key:value for key,value in errors.items() if key in {*MODULES,'busy'} and value in {'busy','capture_busy','disabled','config_changed','ownership','operation_failed'}} if isinstance(errors,dict) else {}}}


def process_ticks(pid: int) -> str:
    if os.name != 'nt': return '0'
    import ctypes
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]; kernel.OpenProcess.restype = w.HANDLE
    kernel.GetProcessTimes.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle: raise ReloadError('reload_owner_unavailable')
    try:
        values = [ctypes.c_ulonglong() for _ in range(4)]
        if not kernel.GetProcessTimes(handle, *(ctypes.byref(value) for value in values)): raise ReloadError('reload_owner_unavailable')
        return str(values[0].value)
    finally: kernel.CloseHandle(handle)


def request_reload(modules: list[str] | None = None) -> dict:
    if modules is not None and (not isinstance(modules,list) or len(modules)!=1 or not isinstance(modules[0],str) or modules[0] not in MODULES):raise ReloadError('invalid_reload_action')
    with prefs._writer_lock(state_path('request')):
        current = snapshot(); existing = read('request'); result = read('result')
        age = time.time() - float(existing.get('created_unix', 0))
        running=False
        if result.get('id')==existing.get('id') and result.get('status')=='running' and type(result.get('worker_pid')) is int:
            try:running=process_ticks(result['worker_pid'])==result.get('worker_ticks')
            except (OSError,ValueError):pass
        if existing and (age < 180 or running) and not (result.get('id') == existing.get('id') and result.get('status') == 'completed'):
            raise ReloadError('reload_busy')
        modules = modules if modules is not None else [item['id'] for item in current['pending']]
        if not modules: return {'version': 1, 'id': '', 'pending': []}
        if current['recording_state']!='idle':raise ReloadError('reload_capture_busy' if current['recording_state']=='active' else 'reload_capture_unavailable')
        if any(not controls.module_enabled(module) for module in modules):raise ReloadError('reload_disabled')
        owner = os.getppid(); token = uuid.uuid4().hex
        document = {'version': 1, 'id': token, 'actions': ','.join(modules), 'owner_pid': owner,
                    'owner_ticks': process_ticks(owner), 'created_unix': int(time.time())}
        document.update({module + '_revision': revision(module) for module in modules})
        write('request', document)
        return {'version': 1, 'id': token, 'pending': current['pending']}


def main() -> int:
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, 'reconfigure'): stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--apply', action='store_true'); args = parser.parse_args()
    try:
        if args.apply:
            request = json.loads(sys.stdin.read(1025))
            if not isinstance(request,dict) or request.get('action')!='reload' or set(request) not in ({'action'},{'action','modules'}): raise ReloadError('invalid_reload_action')
            if 'modules' in request and not isinstance(request['modules'],list):raise ReloadError('invalid_reload_action')
            result = request_reload(request.get('modules'))
        else: result = snapshot()
        print(json.dumps({'status': 'ok', **result}, ensure_ascii=False)); return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        code=str(error) if isinstance(error,ReloadError) and str(error) in {'reload_busy','reload_capture_busy','reload_capture_unavailable','reload_disabled'} else 'reload_unavailable'
        print(json.dumps({'status': 'error', 'code': code})); return 1


if __name__ == '__main__': raise SystemExit(main())
