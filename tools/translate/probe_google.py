"""Explicit Google-only fixed-fixture check; no keys, cache, clipboard or UI."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import sys
import time
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine_trace
import translate

FIXTURES = (
    ('short', 'Hello workflow verification.'),
    ('paragraph', 'This is a fixed paragraph for Google translation verification. ' * 20),
)


def run_probe(timeout: float) -> dict:
    attempts = []
    for name, text in FIXTURES:
        started = time.monotonic()
        item = {'fixture': name, 'inputBytes': len(text.encode('utf-8'))}
        try:
            translated = translate.translate_google_gtx(text, 'en', 'zh', timeout)
            item.update(status='ok', translatedChars=len(translated))
        except Exception as exc:
            item.update(status='failed', kind='timeout' if translate._is_timeout(exc) else engine_trace.failure_kind(exc))
        item['elapsedMs'] = min(7200000, max(0, round((time.monotonic() - started) * 1000)))
        attempts.append(item)
    successes = sum(item['status'] == 'ok' for item in attempts)
    return {'schemaVersion': 1, 'collectedUtc': datetime.now(timezone.utc).isoformat(),
            'scope': 'fixed-fixtures; configured-network; Google-only; no credentials/cache/UI',
            'status': 'ok' if successes == len(attempts) else 'intermittent' if successes else 'failed',
            'timeoutSeconds': timeout,
            'proxyConfigured': any(urllib.request.getproxies().get(key) for key in ('http', 'https')),
            'attempts': attempts}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--online', action='store_true', help='Send only two fixed English fixtures to Google')
    parser.add_argument('--timeout', type=float, default=4.0, help='Network operation timeout, 0.25 to 12 seconds')
    parser.add_argument('--output', type=Path, help='Optional new metadata JSON destination; never overwritten')
    args = parser.parse_args(argv)
    if not args.online:
        parser.error('--online is required; no text was sent')
    if not math.isfinite(args.timeout) or not .25 <= args.timeout <= 12:
        parser.error('timeout must be within 0.25 to 12 seconds')
    if args.output and args.output.exists():
        parser.error('output already exists; no text was sent')
    report = run_probe(args.timeout)
    encoded = json.dumps(report, ensure_ascii=True, indent=2) + '\n'
    if args.output:
        try:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open('x', encoding='utf-8') as stream:
                stream.write(encoded)
        except OSError:
            print('Metadata output unavailable; an existing file was not overwritten.', file=sys.stderr)
            return 1
    print(encoded, end='')
    return 0 if report['status'] == 'ok' else 1


if __name__ == '__main__':
    raise SystemExit(main())
