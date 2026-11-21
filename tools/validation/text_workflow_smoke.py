"""Opt-in fixed-image OCR -> AHK translation -> real panel protocol probe.

Default translation is identity (offline). --online explicitly sends only the
synthetic English fixture using the existing configured translation engine. No clipboard,
screen capture, key injection or audio playback; the current panel is replaced.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT/'tools/raycast-scripts/ocr'
CHECKS = ('recognized', 'translated', 'speechStart', 'speechStop', 'panelClose',
          'cancelled', 'ocrFailure', 'translationFailure', 'jobsClosed', 'tasksClean')


def read_checks(path: Path) -> dict[str, bool]:
    fields = {}
    for line in path.read_text('utf-8-sig').splitlines():
        name, separator, value = line.partition('=')
        if separator and name in CHECKS:
            fields[name] = value == '1'
    return {name: fields.get(name, False) for name in CHECKS}


def translation_outcome(path: Path) -> str:
    """Only export the first request's fixed category, never a free-form log."""
    if not path.is_file():
        return 'not-observed'
    with path.open(encoding='utf-8-sig') as log:
        lines = log.read(65536).splitlines()
    for line in lines:
        if re.search(r'\] ok id=\d+ ', line):
            return 'ok'
        if re.search(r'\] fail id=\d+ ', line):
            kind = re.search(r' diagnostic=(auth|config|timeout|network|io|internal|too_long|detect|empty)(?= |$)', line)
            return kind[1] if kind else 'failed'
    return 'not-observed'


def write_configs(output: Path) -> None:
    (output/'config.toml').write_text(
        'engine="google_gtx"\nsource_language="en"\ntarget_language="en"\n'
        'timeout_s=4\n[cache]\nmax_size_mb=1\nmax_files=10\n', encoding='utf-8')
    (output/'invalid.toml').write_text('source_language="invalid"\n', encoding='utf-8')


def prepare_image(output: Path) -> None:
    # Only the declared base and module environment may load native packages.
    spec = importlib.util.spec_from_file_location('workflow_probe_host', OCR/'ocr_host.py')
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)
    host.activate_environment()
    from PIL import Image, ImageDraw, ImageFont
    image = Image.new('RGB', (1000, 180), 'white')
    try:
        font = ImageFont.truetype(str(Path(os.environ['SystemRoot'])/'Fonts/arial.ttf'), 48)
        ImageDraw.Draw(image).text((30, 40), 'Hello workflow42', fill='black', font=font)
        image.save(output/'fixture.png')
    finally:
        image.close()


def run_probe(output: Path, ahk: Path, online: bool) -> dict:
    spec = importlib.util.spec_from_file_location('workflow_probe_runtime', OCR/'ocr_runtime.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    base = runtime.base_python(OCR)
    flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
    with (output/'prepare.log').open('wb') as log:
        prepared = subprocess.run([str(base), '-I', '-S', str(Path(__file__).resolve()),
                                   '--prepare-image', str(output)], stdout=log, stderr=log,
                                  timeout=30, creationflags=flags)
    if prepared.returncode:
        return {'status': 'failed', 'stage': 'prepare', 'exitCode': prepared.returncode}
    write_configs(output)
    environment = os.environ.copy()
    for variable, directory in [('LOCALAPPDATA', 'local'), ('TEMP', 'temp'), ('TMP', 'temp')]:
        folder = output/directory
        folder.mkdir(exist_ok=True)
        environment[variable] = str(folder)
    # The AHK includes main with --test, so it never initializes resident tools.
    command = [str(ahk), '/ErrorStdOut', str(Path(__file__).with_name('text-workflow-pipeline.ahk')),
               '--test', str(output), 'online' if online else 'identity']
    with (output/'fixture.log').open('wb') as log:
        child = subprocess.Popen(command, stdout=log, stderr=log, env=environment,
                                 creationflags=flags)
        try:
            code = child.wait(timeout=140)
        except subprocess.TimeoutExpired:
            # Only this owned fixture tree; never target residents by name.
            subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            child.wait(timeout=10)
            return {'status': 'failed', 'stage': 'fixture-timeout'}
    checks = read_checks(output/'checks.txt') if (output/'checks.txt').is_file() else {name: False for name in CHECKS}
    return {'status': 'passed' if code == 0 and all(checks.values()) else 'failed',
            'exitCode': code, 'checks': checks, 'translation': 'configured-online' if online else 'identity',
            'translationOutcome': translation_outcome(output/'translation.log'),
            'scope': 'fixed file image; real OCR/translation jobs and panel callbacks; speech counter; no capture/click/audio'}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='New evidence directory; must not exist')
    parser.add_argument('--ahk', type=Path, help='Existing AutoHotkey v2 executable')
    parser.add_argument('--online', action='store_true', help='Send fixed English fixture using existing config; expected target is Chinese')
    parser.add_argument('--prepare-image', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.prepare_image:
        prepare_image(args.prepare_image)
        return 0
    if os.name != 'nt':
        parser.error('Windows is required')
    candidate = args.ahk or shutil.which('AutoHotkey64.exe') or shutil.which('AutoHotkey.exe')
    if not candidate or not Path(candidate).is_file():
        parser.error('Pass --ahk with an existing AutoHotkey v2 executable')
    output = (args.output or ROOT/'.tmp/integration/text-workflow'/uuid.uuid4().hex).resolve()
    if output.exists():
        parser.error('output must not exist')
    output.mkdir(parents=True)
    try:
        report = run_probe(output, Path(candidate).resolve(), args.online)
    except Exception as error:
        report = {'status': 'failed', 'errorType': type(error).__name__}
    (output/'report.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'status': report['status'], 'report': str(output/'report.json')}))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
