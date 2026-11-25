"""Fixed maintenance progress state for the settings UI.

The bridge reads a bounded JSON state file, exports only fixed stage/result
tokens, and accepts cancellation only while a safe (pre-mutation) stage runs.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
LIMIT = 16384
STAGES = ('idle', 'build', 'verify', 'deploy', 'restore')
RESULTS = ('idle', 'running', 'succeeded', 'failed', 'cancelled')
CANCELLABLE = {'build', 'verify'}
FAILURES = ('cancelled', 'deploy_failed', 'restore_failed', 'verification_failed', 'stage_not_cancellable')


class MaintenanceError(ValueError):
    pass


def state_path() -> Path:
    return REPO / '.toolbox-state' / 'maintenance-progress.json'


def cancel_path() -> Path:
    return REPO / '.toolbox-state' / 'maintenance-cancel.flag'


def snapshot() -> dict:
    try:
        raw = state_path().read_bytes()
    except FileNotFoundError:
        raw = b''
    if len(raw) > LIMIT:
        raise MaintenanceError('invalid_state')
    state = {'version': 1, 'stage': 'idle', 'result': 'idle', 'updated_utc': '',
             'record': '', 'failure': '', 'cancellable': False}
    if not raw:
        return state
    try:
        data = json.loads(raw.decode('utf-8-sig'))
    except (ValueError, UnicodeError):
        raise MaintenanceError('invalid_state') from None
    if not isinstance(data, dict):
        raise MaintenanceError('invalid_state')
    # Early fixtures used PascalCase keys; normalize before validation.
    data = {key.lower(): value for key, value in data.items()}
    if 'updatedutc' in data:
        data['updated_utc'] = data.pop('updatedutc')
    if data.get('version') != 1:
        raise MaintenanceError('invalid_state')
    stage, result = data.get('stage'), data.get('result')
    if stage not in STAGES or result not in RESULTS:
        raise MaintenanceError('invalid_state')
    record, failure = data.get('record', ''), data.get('failure', '')
    updated = data.get('updated_utc', '')
    if not all(isinstance(value, str) and len(value) <= 128 for value in (record, failure, updated)):
        raise MaintenanceError('invalid_state')
    if failure and failure not in FAILURES:
        failure = ''
    state.update(stage=stage, result=result, updated_utc=updated, record=record, failure=failure,
                 cancellable=bool(result == 'running' and stage in CANCELLABLE))
    return state


def request_cancel() -> dict:
    state = snapshot()
    if not state['cancellable']:
        raise MaintenanceError('stage_not_cancellable')
    path = cancel_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {'version': 1, 'requested_utc': datetime.now(timezone.utc).isoformat()}
    temporary = path.with_name(path.name + '.' + os.urandom(8).hex() + '.tmp')
    try:
        temporary.write_text(json.dumps(document), encoding='utf-8')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return {'status': 'ok', 'cancelled_stage': state['stage']}


def main(argv=None) -> int:
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--cancel', action='store_true')
    mode.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.apply:
            request = json.loads(sys.stdin.read(LIMIT + 1))
            if not isinstance(request, dict) or request != {'cancel': True}:
                raise MaintenanceError('invalid_request')
            result = {'status': 'ok', **request_cancel()}
        else:
            result = {'status': 'ok', **({'state': snapshot()} if not args.cancel else request_cancel())}
    except (ValueError, OSError) as error:
        code = str(error) if isinstance(error, MaintenanceError) else 'maintenance_unavailable'
        print(json.dumps({'status': 'error', 'code': code}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
