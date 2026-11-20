#!/usr/bin/env python3
# @raycast.schemaVersion 1
# @raycast.title Install TTS Dependencies
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Install the locked TTS environment; --check only validates
"""Create/check the module-owned environment. Never installs into global Python."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import venv
from tts_runtime import claim_profile, owns_profile, profile_directory, publish_ready

ROOT = Path(__file__).resolve().parent
LOCK = ROOT / 'requirements.lock'
DEFAULT_LOCATION = 'profile' if sys.platform == 'win32' else 'repo'


def environment_directory(location: str = DEFAULT_LOCATION) -> Path:
    return profile_directory(ROOT) if location == 'profile' else ROOT/'.venv'


RUNTIME = environment_directory() / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')


def expected_versions(lock: Path = LOCK) -> dict[str, str]:
    versions = dict(re.findall(r'^([\w.-]+)==([^\s\\]+)', lock.read_text('utf-8'), re.MULTILINE))
    if not versions or 'edge-tts' not in versions:
        raise ValueError('TTS dependency lock is missing/invalid')
    return versions


def check_environment(python: Path = RUNTIME, lock: Path = LOCK) -> dict:
    expected = expected_versions(lock)
    if not python.is_file():
        return {'status': 'missing', 'python': str(python), 'mismatches': expected}
    query = '''import importlib.metadata as m,json,sys
result={}
for name in json.loads(sys.argv[1]):
 try: result[name]=m.version(name)
 except m.PackageNotFoundError: result[name]=None
print(json.dumps(result))
'''
    run = subprocess.run([str(python), '-c', query, json.dumps(list(expected))], capture_output=True, text=True, timeout=20)
    if run.returncode:
        raise RuntimeError(f'TTS interpreter check failed: exit {run.returncode}')
    actual = json.loads(run.stdout)
    mismatches = {name: {'expected': version, 'actual': actual.get(name)}
                  for name, version in expected.items() if actual.get(name) != version}
    return {'status': 'ready' if not mismatches else 'outdated', 'python': str(python), 'mismatches': mismatches}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--location', choices=['profile', 'repo'], default=DEFAULT_LOCATION)
    args = parser.parse_args()
    try:
        directory = environment_directory(args.location)
        runtime = directory / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')
        if args.location == 'profile' and directory.exists() and any(directory.iterdir()) and not owns_profile(directory, ROOT):
            raise ValueError('Refusing an unowned or foreign TTS environment')
        if args.location == 'profile' and not args.check:
            claim_profile(directory, ROOT)
            (directory/'.ready.txt').unlink(missing_ok=True)
        status = check_environment(runtime)
        if args.check:
            if args.location == 'profile' and not owns_profile(directory, ROOT, ready=True):
                status['status'] = 'unready'
            print(json.dumps(status))
            return 0 if status['status'] == 'ready' else 1
        if status['status'] == 'ready':
            if args.location == 'profile':
                publish_ready(directory, ROOT)
            print(json.dumps(status))
            return 0
        if not runtime.is_file():
            venv.EnvBuilder(with_pip=True).create(directory)
        has_pip = subprocess.run([str(runtime), '-m', 'pip', '--version'], capture_output=True, timeout=20)
        if has_pip.returncode:
            subprocess.run([str(runtime), '-m', 'ensurepip', '--upgrade'], check=True, timeout=120)
        subprocess.run([str(runtime), '-m', 'pip', 'install', '--require-hashes', '-r', str(LOCK)], check=True, timeout=300)
        status = check_environment(runtime)
        if status['status'] == 'ready' and args.location == 'profile':
            publish_ready(directory, ROOT)
        print(json.dumps(status))
        return 0 if status['status'] == 'ready' else 1
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        print(f'TTS environment failed: {type(error).__name__}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
