"""Locked Python 3.14 OCR environment metadata; no model or clipboard access."""
import importlib.metadata
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent


def expected_versions(lock: Path = ROOT/'requirements.lock') -> dict[str, str]:
    versions = dict(re.findall(r'^([\w.-]+)==([^\s\\]+)', lock.read_text('utf-8'), re.MULTILINE))
    if not {'rapidocr-onnxruntime', 'pillow', 'pyperclip', 'onnxruntime'} <= versions.keys():
        raise ValueError('Invalid OCR dependency lock')
    return versions


def installed_status() -> dict:
    expected = expected_versions()
    actual = {}
    for name in expected:
        try:
            actual[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            actual[name] = None
    mismatches = {name: {'expected': version, 'actual': actual[name]}
                  for name, version in expected.items() if version != actual[name]}
    return {'status': 'outdated' if mismatches else 'ready', 'mismatches': mismatches, 'packages': actual}


def base_python(module: Path = ROOT) -> Path:
    settings = {}
    for line in (module/'.venv314/pyvenv.cfg').read_text('utf-8-sig').splitlines():
        key, separator, value = line.partition('=')
        if separator:
            settings[key.strip()] = value.strip()
    version = settings.get('version_info', settings.get('version', ''))
    home = Path(settings.get('home', ''))
    if not re.fullmatch(r'3\.14(?:\.\d+)?', version) or not home.is_absolute():
        raise ValueError('Locked OCR requires a declared Python 3.14 base')
    python = home/'python.exe'
    if not python.is_file():
        raise FileNotFoundError('OCR base interpreter is missing')
    return python


def check_environment(module: Path = ROOT) -> dict:
    try:
        python = base_python(module)
    except FileNotFoundError:
        return {'status': 'missing'}
    run = subprocess.run([str(python), '-I', '-S', str(module/'ocr_host.py'), '--check'],
                         capture_output=True, timeout=30)
    if run.returncode not in {0, 2}:
        return {'status': 'broken', 'reason': 'host-import-failed', 'python': str(python)}
    result = json.loads(run.stdout.decode('utf-8-sig'))
    if result.get('status') != ('ready' if run.returncode == 0 else 'outdated'):
        raise ValueError('Invalid OCR environment response')
    return {**result, 'python': str(python)}
