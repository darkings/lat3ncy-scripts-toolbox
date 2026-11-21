"""Strictly allowlisted support exports and bounded translation statistics."""
from __future__ import annotations

import json
from pathlib import Path
import re
import zipfile

ENGINES = {"tencent", "aliyun", "google_gtx", "mymemory", "identity", "mixed", "unknown"}
STATUSES = {"ok", "attention", "missing", "invalid", "default", "query-failed", "not-applicable", "running",
            "not-running", "ambiguous", "unresponsive", "available", "unreadable", "unsupported"}
METRIC = re.compile(r'^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] metric id=\d{1,10} '
                    r'status=(ok|partial|failed|cancelled|timeout) elapsed_ms=(\d{1,7}) '
                    r'engine=(tencent|aliyun|google_gtx|mymemory|identity|mixed|unknown) cached=([01]) '
                    r'fallback=(none|credentials|auth|timeout|network|too_long) '
                    r'total=(\d{1,3}) completed=(\d{1,3}) failed=(\d{1,3}) resumed=(\d{1,3})$')


def translation_statistics(tail: str) -> dict:
    samples = []
    for line in tail.splitlines():
        match = METRIC.fullmatch(line)
        if not match:
            continue
        status, elapsed, engine, cached, fallback, total, completed, failed, resumed = match.groups()
        elapsed, total, completed, failed, resumed = map(int, (elapsed, total, completed, failed, resumed))
        if elapsed > 7200000 or not 1 <= total <= 200 or completed + failed > total or resumed > completed:
            continue
        samples.append(dict(status=status, elapsed=elapsed, engine=engine, cached=cached == '1',
                            fallback=fallback, total=total, completed=completed, failed=failed, resumed=resumed))
    elapsed = sorted(item['elapsed'] for item in samples)
    successes = [item for item in samples if item['status'] == 'ok']
    return {
        'scope': 'retained-log-window', 'samples': len(samples),
        'statusCounts': {status: sum(item['status'] == status for item in samples) for status in ('ok', 'partial', 'failed', 'cancelled', 'timeout')},
        'elapsedMs': {'average': round(sum(elapsed) / len(elapsed)) if elapsed else None,
                      'p95': elapsed[min(len(elapsed) - 1, (len(elapsed) * 95 + 99) // 100 - 1)] if elapsed else None,
                      'maximum': max(elapsed) if elapsed else None},
        'cacheHits': sum(item['cached'] for item in successes),
        'fallbackRequests': sum(item['fallback'] != 'none' for item in samples if item['status'] in {'ok', 'partial'}),
        'resumedSegments': sum(item['resumed'] for item in samples),
    }


def _enum(target: dict, source: dict, key: str, allowed: set):
    value = source.get(key)
    if isinstance(value, str) and value in allowed:
        target[key] = value


def _mapping(value: object) -> dict:
    return value if isinstance(value, dict) else {}


def _event(source: object) -> dict:
    if not isinstance(source, dict):
        return {}
    result = {}
    for key, allowed in {
        'status': {'ok', 'fail', 'failed', 'timeout', 'cancelled', 'success', 'completed', 'partial'},
        'engine': ENGINES, 'preferredEngine': ENGINES,
        'reason': {'credentials', 'auth', 'network', 'timeout', 'too_long'},
        'kind': {'none', 'input', 'synthesis', 'playback', 'timeout', 'internal', 'cancelled', 'protocol',
                 'auth', 'config', 'network', 'http', 'parse', 'too_long', 'io', 'empty', 'detect', 'error'},
        'stage': {'delivery', 'launch'}, 'presentation': {'panel', 'popup'},
    }.items():
        _enum(result, source, key, allowed)
    stamp = source.get('atLocal')
    if isinstance(stamp, str) and re.fullmatch(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d', stamp):
        result['atLocal'] = stamp
    if isinstance(source.get('cached'), bool):
        result['cached'] = source['cached']
    return result


def redact_report(report: dict) -> dict:
    """Reconstruct the document from typed enums, never recursive key deletion."""
    report = _mapping(report)
    result = {'schemaVersion': 1, 'scope': 'shareable-offline-metadata', 'residents': {}, 'configs': {}, 'modules': {}, 'logs': {}}
    _enum(result, report, 'status', STATUSES)
    for name in ('ahk', 'hud', 'caret', 'powerPolicy'):
        item = _mapping(_mapping(report.get('residents')).get(name))
        result['residents'][name] = {}
        _enum(result['residents'][name], item, 'status', STATUSES)
    for name in ('translate', 'tts', 'ocr'):
        config = _mapping(_mapping(report.get('configs')).get(name))
        safe = result['configs'][name] = {}
        _enum(safe, config, 'status', STATUSES)
        _enum(safe, config, 'engine', ENGINES | {'auto', 'edge', 'winrt', 'system', 'rapidocr'})
        for key in ('source_language', 'target_language'):
            _enum(safe, config, key, {'auto', 'zh', 'en'})
        for key in ('fallback_without_credentials', 'fallback_on_auth_error', 'long_text_enabled', 'preferencesApplied'):
            if isinstance(config.get(key), bool):
                safe[key] = config[key]
        module = _mapping(_mapping(report.get('modules')).get(name))
        safe = result['modules'][name] = {}
        _enum(safe, module, 'status', STATUSES)
        _enum(safe, module, 'kind', {'global', 'profile', 'legacy-venv', 'base-host'})
        _enum(safe, module, 'integrity', {'low', 'medium', 'high', 'system', 'unknown'})
        version = module.get('pythonVersion')
        if isinstance(version, str) and re.fullmatch(r'\d{1,2}\.\d{1,2}\.\d{1,3}', version):
            safe['pythonVersion'] = version
        if isinstance(module.get('tempWritable'), bool):
            safe['tempWritable'] = module['tempWritable']
        # Package names come from this repository's locks, never from free-form
        # process output. Paths, command lines and arbitrary module fields vanish.
        root = Path(__file__).resolve().parents[2]
        lock = root / ('tools/tts/requirements.lock' if name == 'tts' else 'tools/raycast-scripts/ocr/requirements.lock')
        allowed = set(re.findall(r'^([\w.-]+)==', lock.read_text('utf-8'), re.MULTILINE)) if name != 'translate' and lock.is_file() else set()
        if isinstance(module.get('packages'), dict):
            safe['packages'] = {key: value for key, value in module['packages'].items() if key in allowed
                                and (value is None or isinstance(value, str) and re.fullmatch(r'\d[0-9A-Za-z.+-]{0,63}', value))}
        log = _mapping(_mapping(report.get('logs')).get(name))
        safe = result['logs'][name] = {}
        _enum(safe, log, 'status', STATUSES)
        for field in ('lastTerminalEvent', 'lastFailure', 'lastFallbackEvent'):
            if field in log:
                safe[field] = _event(log[field])
        if name == 'translate':
            # Re-validate numbers and fixed keys, even though collect already
            # constructs statistics from strict anchored records.
            stats = _mapping(log.get('statistics'))
            cleaned = {'scope': 'retained-log-window'}
            for key in ('samples', 'cacheHits', 'fallbackRequests', 'resumedSegments'):
                value = stats.get(key)
                if type(value) is int and 0 <= value <= 100000:
                    cleaned[key] = value
            for group, keys in (('statusCounts', ('ok', 'partial', 'failed', 'cancelled', 'timeout')),
                                ('elapsedMs', ('average', 'p95', 'maximum'))):
                values = stats.get(group, {})
                if isinstance(values, dict):
                    cleaned[group] = {key: value for key in keys if (value := values.get(key)) is None
                                      or type(value) is int and 0 <= value <= 7200000}
            safe['statistics'] = cleaned
    return result


def write_bundle(path: Path, report: dict) -> None:
    safe = redact_report(report)
    path.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        with path.open('xb') as stream:
            created = True
            with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('summary.json', json.dumps(safe, ensure_ascii=True, indent=2) + '\n')
                archive.writestr('README.txt', 'Offline metadata only. No source text, translated text, credentials, raw logs, local paths or process command lines.\nStatistics cover only retained logs, not lifetime totals or end-to-end UI acceptance.\n')
    except Exception:
        if created:
            path.unlink(missing_ok=True)
        raise
