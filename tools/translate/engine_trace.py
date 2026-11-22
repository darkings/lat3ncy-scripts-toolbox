"""Bounded, text-free engine summaries for a single owned translation request."""
from __future__ import annotations

import os
from pathlib import Path
import re
import ssl
import urllib.error
import uuid

ENGINES = ('tencent', 'aliyun', 'google_gtx', 'mymemory')
KINDS = {'none', 'credentials', 'cooldown', 'auth', 'timeout', 'tls', 'http', 'network', 'response', 'too_long', 'internal'}


def failure_kind(error: BaseException) -> str:
    """Inspect types only, including wrapped urllib causes; never stringify errors."""
    chain = []
    current = error
    for _ in range(8):
        if current is None or any(current is item for item in chain):
            break
        chain.append(current)
        reason = getattr(current, 'reason', None)
        current = reason if isinstance(reason, BaseException) else current.__cause__
    if any(isinstance(item, TimeoutError) for item in chain):
        return 'timeout'
    if any(isinstance(item, ssl.SSLError) for item in chain):
        return 'tls'
    if any(isinstance(item, urllib.error.HTTPError) for item in chain):
        return 'http'
    if any(isinstance(item, (urllib.error.URLError, OSError)) for item in chain):
        return 'network'
    return 'response' if isinstance(error, ValueError) else 'internal'


class EngineTrace:
    def __init__(self, path: str, request_id: str):
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', request_id):
            raise ValueError('invalid_request_id')
        self.path = Path(path)
        self.request_id = request_id
        self.routes: dict[str, dict] = {}

    def record(self, engine: str, outcome: str, *, elapsed_ms: int = 0, kind: str = 'none') -> None:
        if engine not in ENGINES or outcome not in {'ok', 'failed', 'cached', 'skipped'} or kind not in KINDS:
            return
        route = self.routes.setdefault(engine, dict(calls=0, failed=0, cached=0, skipped=0, elapsed_ms=0, kind='none'))
        if outcome in {'ok', 'failed'}:
            route['calls'] = min(200, route['calls'] + 1)
            route['elapsed_ms'] = min(7200000, route['elapsed_ms'] + max(0, min(7200000, int(elapsed_ms))))
            if outcome == 'failed':
                route['failed'] = min(route['calls'], route['failed'] + 1)
        else:
            route[outcome] = min(200, route[outcome] + 1)
        if kind != 'none' and (outcome == 'failed' or route['failed'] == 0):
            route['kind'] = kind
        self._write()

    def _write(self):
        temporary = self.path.with_name(self.path.name + '.' + uuid.uuid4().hex + '.tmp')
        lines = ['version=1', 'request_id=' + self.request_id]
        for engine in ENGINES:
            if engine in self.routes:
                route = self.routes[engine]
                values = [str(route[key]) for key in ('calls', 'failed', 'cached', 'skipped', 'elapsed_ms', 'kind')]
                lines.append('route_' + engine + '=' + ','.join(values))
        try:
            temporary.write_text('\n'.join(lines) + '\n', encoding='utf-8')
            os.replace(temporary, self.path)
        except OSError:
            pass  # A diagnostic failure must not stop a usable translation.
        finally:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
