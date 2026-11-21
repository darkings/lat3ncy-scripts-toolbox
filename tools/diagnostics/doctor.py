"""Offline toolbox diagnostics: no model, network, clipboard or playback access."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[2]
ENGINES = {'ocr': {'system', 'rapidocr'}, 'translate': {'tencent', 'aliyun', 'google_gtx', 'mymemory'},
           'tts': {'auto', 'edge', 'winrt'}}
TRANSLATE_ALIASES = {'google': 'google_gtx', 'gtx': 'google_gtx', 'ali': 'aliyun', 'alibaba': 'aliyun',
                     'alimt': 'aliyun', 'aliyun_mt': 'aliyun', 'tmt': 'tencent', 'qcloud': 'tencent',
                     'tencentcloud': 'tencent', 'tencent_mt': 'tencent'}
MODULES = {'ocr': 'tools/raycast-scripts/ocr', 'translate': 'tools/translate', 'tts': 'tools/tts'}


def load_file(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def config_summary(path: Path, component: str) -> dict:
    """Only export allowlisted enums, never the config or arbitrary values."""
    try:
        if path.stat().st_size > 1024 * 1024:
            return {'status': 'invalid', 'reason': 'config-too-large'}
        value = tomllib.loads(path.read_text('utf-8-sig'))
        engine = value.get('ocr' if component == 'ocr' else 'engine',
                           {'ocr': 'system', 'translate': 'tencent', 'tts': 'auto'}[component])
        if component == 'translate' and isinstance(engine, str):
            engine = engine.strip().lower()
            engine = TRANSLATE_ALIASES.get(engine, engine)
        if not isinstance(engine, str) or engine not in ENGINES[component]:
            return {'status': 'invalid', 'reason': 'unsupported-engine'}
        return {'status': 'ok', 'engine': engine}
    except FileNotFoundError:
        return {'status': 'default', 'engine': {'ocr': 'system', 'translate': 'tencent', 'tts': 'auto'}[component]}
    except (OSError, ValueError) as error:
        return {'status': 'invalid', 'errorType': type(error).__name__}


def log_summary(path: Path, component: str) -> dict:
    """Bounded read; extract fixed event/category tokens, never free-form lines."""
    result = {'path': str(path), 'status': 'missing'}
    try:
        with path.open('rb') as stream:
            stat = os.fstat(stream.fileno())
            result.update(status='available', bytes=stat.st_size,
                          modifiedUtc=datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat())
            stream.seek(max(0, stat.st_size - 65536))
            tail = stream.read(65536).decode('utf-8-sig', errors='replace')
        # Anchored to production AHK records. A detail= field cannot inject one.
        tts = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] \[AHK\] 朗读结束 request=[A-Za-z0-9_-]+ status=(success|failed|timeout|cancelled) kind=(none|input|synthesis|playback|timeout|internal|cancelled|protocol) exit=(-?\d{1,3})$')
        translate = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] (ok|fail) id=\d+(?: .*)?$')
        ocr = re.compile(r'^(\d\d:\d\d:\d\d) py (done exit=(0|1)|error exit=1(?: .*)?)$')
        for line in tail.splitlines():
            match = tts.fullmatch(line) if component == 'tts' else translate.fullmatch(line) if component == 'translate' else ocr.fullmatch(line) if component == 'ocr' else None
            if not match:
                continue
            event = {'atLocal': match[1], 'status': match[2]}
            if component == 'tts':
                event.update(kind=match[3], exitCode=int(match[4]))
            elif component == 'translate':
                category = re.search(r' diagnostic=(config|timeout|network|http|parse|internal)(?= |$)', line)
                if category:
                    event['kind'] = category[1]
            else:
                # OCR exit=0 also includes no-text/cancel; do not infer delivery.
                event['status'] = 'completed' if match[3] == '0' else 'failed'
            result['lastTerminalEvent'] = event
            if event['status'] in {'fail', 'failed', 'timeout'}:
                result['lastFailure'] = event
        return result
    except FileNotFoundError:
        return result
    except OSError as error:
        return {**result, 'status': 'unreadable', 'errorType': type(error).__name__}


def run_json(command: list[str], timeout: float = 15, *, env=None) -> dict:
    try:
        run = subprocess.run(command, capture_output=True, timeout=timeout, env=env,
                             creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        if run.returncode:
            return {'status': 'query-failed', 'reason': 'probe-exit', 'exitCode': run.returncode}
        value = json.loads(run.stdout.decode('utf-8-sig'))
        if not isinstance(value, dict):
            raise ValueError('Invalid report')
        return value
    except subprocess.TimeoutExpired:
        return {'status': 'query-failed', 'reason': 'probe-timeout'}
    except (OSError, ValueError) as error:
        return {'status': 'query-failed', 'errorType': type(error).__name__}


def probe(component: str, kind: str) -> dict:
    """Runs in the selected console sibling; never imports a feature entry point."""
    import importlib.metadata as metadata
    if component == 'ocr' and kind == 'base-host':
        load_file('ocr_host', ROOT/MODULES['ocr']/'ocr_host.py').activate_environment()
    packages = {'ocr': ['rapidocr-onnxruntime', 'onnxruntime', 'Pillow', 'pyperclip'], 'translate': [], 'tts': []}[component]
    expected = {}
    if component == 'tts':
        expected = dict(re.findall(r'^([\w.-]+)==([^\s\\]+)', (ROOT/MODULES['tts']/'requirements.lock').read_text('utf-8'), re.MULTILINE))
        if 'edge-tts' not in expected:
            return {'status': 'invalid', 'reason': 'invalid-lock'}
        packages = list(expected)
    actual = {}
    for package in packages:
        try:
            actual[package] = metadata.version(package)
        except metadata.PackageNotFoundError:
            actual[package] = None
    context = load_file('process_context', ROOT/'tools/validation/process_context.py').inspect_context()
    mismatches = [name for name in packages if actual[name] is None or (name in expected and actual[name] != expected[name])]
    return {'status': 'attention' if mismatches or sys.version_info < (3, 11) or context.get('tempWritable') is False or context.get('integrity') == 'low' else 'ok',
            'pythonVersion': '.'.join(map(str, sys.version_info[:3])), 'packages': actual,
            'mismatches': mismatches, 'integrity': context.get('integrity', 'unknown'),
            'tempWritable': context.get('tempWritable'), 'scope': 'metadata-only'}


def inspect_runtime(component: str, spec: dict | None) -> dict:
    if not spec or not spec.get('python'):
        return {'status': 'missing', 'reason': 'interpreter-not-found'}
    selected = Path(spec['python'])
    console = selected.with_name('python.exe') if selected.name.lower() == 'pythonw.exe' else None
    result = {'selectedPythonW': str(selected), 'kind': spec['kind']}
    if not console or not console.is_file():
        return {**result, 'status': 'query-failed', 'reason': 'console-sibling-unavailable'}
    flags = ['-I', '-S'] if spec['kind'] == 'base-host' else ['-I']
    return {**result, 'diagnosticPython': str(console),
            **run_json([str(console), *flags, str(Path(__file__).resolve()), '--probe', component, '--kind', spec['kind']])}


def select_tts_spec(module: Path, local_data: str | None, global_spec: dict) -> dict:
    tts = load_file('tts_runtime', module/'tts_runtime.py')
    if local_data:
        directory = tts.profile_directory(module, local_data)
        candidate = directory/'Scripts/pythonw.exe'
        # AHK checks the ready marker, not the installer owner marker.
        if candidate.is_file() and tts.owns_profile(directory, module, ready=True):
            return {'python': str(candidate), 'kind': 'profile'}
    candidate = module/'.venv/Scripts/pythonw.exe'
    if candidate.is_file():
        return {'python': str(candidate), 'kind': 'legacy-venv'}
    return global_spec


def collect() -> dict:
    powershell = Path(os.environ.get('SystemRoot', 'C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'
    environment = os.environ.copy()
    environment['PSModulePath'] = str(powershell.parent/'Modules')
    runtime = run_json([str(powershell), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                        str(Path(__file__).with_name('Collect-Runtime.ps1')), '-Repo', str(ROOT)], env=environment)
    configs = {name: config_summary(ROOT/relative/'config.toml', name) for name, relative in MODULES.items()}
    global_spec = {'python': runtime.get('globalPythonW'), 'kind': 'global'}
    tts_spec = select_tts_spec(ROOT/MODULES['tts'], os.environ.get('LOCALAPPDATA'), global_spec)
    modules = {}
    for name, spec in [('translate', global_spec), ('tts', tts_spec), ('ocr', runtime.get('ocr'))]:
        if name == 'ocr' and configs[name].get('engine') == 'system':
            modules[name] = {'status': 'not-applicable', 'reason': 'system-ocr-selected'}
        else:
            modules[name] = inspect_runtime(name, spec)
    logs = {name: log_summary(path, name) for name, path in {
        'translate': Path(os.environ.get('TEMP', '.'))/'lat3ncy-translate.log',
        'tts': ROOT/MODULES['tts']/'tts.log', 'ocr': ROOT/MODULES['ocr']/'.debug.log',
        'startup': Path(os.environ.get('LOCALAPPDATA', Path.home()/'AppData/Local'))/'lat3ncy-toolbox/startup.log'}.items()}
    attention = (any(item['status'] == 'invalid' for item in configs.values())
                 or any(item['status'] not in {'ok', 'not-applicable'} for item in modules.values())
                 or not runtime.get('residents')
                 or any(item['status'] != 'running' for item in runtime.get('residents', {}).values()))
    return {'schemaVersion': 1, 'collectedUtc': datetime.now(timezone.utc).isoformat(), 'repo': str(ROOT),
            'status': 'attention' if attention else 'ok', 'residents': runtime.get('residents', {}),
            'runtimeQuery': {key: runtime[key] for key in ('status', 'reason', 'errorType') if key in runtime},
            'configs': configs, 'modules': modules, 'logs': logs,
            'scope': 'offline-metadata; current shell environment; console siblings; no end-to-end verification'}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true', help='Print structured metadata instead of the summary')
    parser.add_argument('--output', type=Path, help='Also save JSON to this path (contains local paths)')
    parser.add_argument('--probe', choices=list(MODULES), help=argparse.SUPPRESS)
    parser.add_argument('--kind', default='global', help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if args.probe:
            report = probe(args.probe, args.kind)
        elif os.name != 'nt':
            report = {'status': 'unsupported', 'reason': 'windows-required'}
        else:
            report = collect()
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        report = {'status': 'query-failed', 'errorType': type(error).__name__}
    encoded = json.dumps(report, ensure_ascii=True, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded+'\n', encoding='utf-8')
    if args.json or args.probe or 'modules' not in report:
        print(encoded)
    else:
        print('Toolbox diagnostics: '+report['status'])
        for name, item in report['residents'].items():
            print(f"  {name}: {item['status']}")
        for name, item in report['modules'].items():
            print(f"  {name}: {item['status']} ({report['configs'][name].get('engine', 'invalid config')})")
            print('    Python: '+item.get('selectedPythonW', item.get('reason', 'unknown')))
            if 'pythonVersion' in item:
                print(f"    Version: {item['pythonVersion']}; integrity: {item['integrity']}; TEMP writable: {item['tempWritable']}")
            if item.get('mismatches'):
                print('    Dependency mismatches: '+', '.join(item['mismatches']))
            if report['configs'][name]['status'] == 'invalid':
                print('    Check config.toml syntax and engine; values are omitted from this report.')
        for name, item in report['logs'].items():
            print(f"  {name} log: {item['path']} ({item['status']})")
            if 'lastTerminalEvent' in item:
                event = item['lastTerminalEvent']
                print(f"    Latest recorded event: {event['atLocal']} {event['status']}")
            if 'lastFailure' in item:
                event = item['lastFailure']
                print(f"    Historical failure: {event['atLocal']} {event.get('kind', event['status'])}")
        print('Offline metadata only. Use --json for details; historical failures do not indicate a current outage.')
    # A probe successfully delivered an observation even when it found a problem.
    # The outer command owns the health exit code; keep probe findings intact.
    return 0 if args.probe or report['status'] == 'ok' else 1


if __name__ == '__main__':
    raise SystemExit(main())
