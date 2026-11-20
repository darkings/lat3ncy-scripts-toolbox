"""Validate the candidate working tree in an isolated local Git clone.

Configuration comes from HEAD, never from modified personal config.toml files.
No commits, staging, branches or remotes in the source repository are changed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
EXCLUDED = {'.git', '.tmp', '.worktrees', '.pip_manual', '.tmp_caps',
            'bin', 'obj', 'out', 'test-out', 'dist', '__pycache__'}


def eligible(relative: str) -> bool:
    path = Path(relative)
    return (not path.is_absolute() and '..' not in path.parts
            and not any(p.lower() in EXCLUDED or p.lower().startswith('.venv') for p in path.parts)
            and not any(p.lower() in {'relays', 'backups'} for p in path.parts)
            and not path.name.lower().endswith(('.log', '.bak', '.pyc', '.pyo'))
            and '.log.' not in path.name.lower())


def git(repo: Path, *args: str) -> bytes:
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE)


def export_candidate(repo: Path, destination: Path) -> list[dict]:
    destination.mkdir(parents=True, exist_ok=False)
    names = set(git(repo, 'ls-files', '-co', '--exclude-standard', '-z').decode('utf-8').split('\0')) - {''}
    entries = []
    for name in sorted(names):
        if not eligible(name):
            continue
        source = repo / name
        if not source.is_file():
            continue
        # Never follow a tracked or untracked junction/symlink outside the repo.
        resolved = source.resolve()
        if source.is_symlink() or not resolved.is_relative_to(repo.resolve()):
            raise ValueError(f'Export path is not a regular repository file: {name}')
        mode = 'working-tree'
        if source.name == 'config.toml':
            try:
                data = git(repo, 'show', f'HEAD:{name}')
            except subprocess.CalledProcessError:
                continue  # Untracked personal configuration has no baseline.
            mode = 'HEAD-config'
        else:
            data = source.read_bytes()
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        entries.append({'path': name, 'sha256': hashlib.sha256(data).hexdigest(), 'origin': mode})
    return entries


def run_phase(name: str, command: list[str], cwd: Path, evidence: Path, timeout: int) -> dict:
    start = time.monotonic()
    log = evidence / f'{name}.log'
    environment = os.environ.copy()
    # A Python parent does not perform pwsh's Windows PowerShell compatibility
    # cleanup. Keep PS 7/Codex modules out of the 5.1 child and its test children.
    environment['PSMODULEPATH'] = ';'.join([
        str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/Modules'),
        str(Path(os.environ['ProgramFiles']) / 'WindowsPowerShell/Modules'),
    ])
    with log.open('w', encoding='utf-8') as output:
        process = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                   env=environment,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # These are our isolated test/build descendants, never residents.
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            process.wait(timeout=10)
            code = -1
    return {'name': name, 'status': 'passed' if code == 0 else 'failed', 'exitCode': code,
            'seconds': round(time.monotonic()-start, 2), 'log': str(log)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--full', action='store_true', help='Also source-build WinUI and run the AHK/full suite')
    parser.add_argument('--output', type=Path, help='A new evidence directory (kept for review)')
    args = parser.parse_args()
    evidence = (args.output or ROOT / '.tmp' / 'validation' / uuid.uuid4().hex).resolve()
    if evidence.exists():
        parser.error('output directory must not already exist')
    evidence.mkdir(parents=True)
    report = {'version': 1, 'sourceHead': git(ROOT, 'rev-parse', 'HEAD').decode().strip(),
              'evidence': str(evidence), 'configMode': 'HEAD baseline', 'phases': [],
              'scope': 'local candidate clone on the current machine; not a clean OS or remote CI'}
    try:
        staging = evidence / 'candidate'
        entries = export_candidate(ROOT, staging)
        (evidence / 'files.json').write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding='utf-8')
        subprocess.run(['git', 'init', '--quiet', str(staging)], check=True, capture_output=True)
        hooks = evidence / 'empty-hooks'; hooks.mkdir()
        git(staging, 'add', '--all')
        git(staging, '-c', 'user.name=Toolbox Validation', '-c', 'user.email=validation@invalid',
            '-c', 'commit.gpgsign=false', '-c', f'core.hooksPath={hooks}',
            'commit', '--quiet', '-m', 'isolated validation snapshot (not a project commit)')
        checkout = evidence / 'checkout with spaces'
        subprocess.run(['git', 'clone', '--quiet', '--no-hardlinks', str(staging), str(checkout)], check=True, capture_output=True)
        if git(checkout, 'status', '--porcelain').strip():
            raise RuntimeError('Candidate clone is not clean before validation')
        report.update({'files': len(entries), 'initiallyClean': True, 'checkout': str(checkout)})
        host = str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
        phases = [('offline', ['ahk/tests/run-offline-tests.ps1'], 300),
                  ('helpers', ['tools/build/Build-ManagedHelpers.ps1'], 120)]
        if args.full:
            phases.append(('full', ['ahk/tests/run-tests.ps1', '-BuildImeHud'], 900))
        for name, arguments, timeout in phases:
            phase = run_phase(name, [host, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', *arguments], checkout, evidence, timeout)
            report['phases'].append(phase)
            print(json.dumps(phase), flush=True)
            if phase['status'] != 'passed':
                break
        report['status'] = 'passed' if len(report['phases']) == len(phases) and all(p['status'] == 'passed' for p in report['phases']) else 'failed'
    except Exception as error:
        report.update({'status': 'failed', 'error': f'{type(error).__name__}: {error}'})
    finally:
        (evidence / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'status': report['status'], 'report': str(evidence / 'report.json')}))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
