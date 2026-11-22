"""Allowlisted local module settings, preserving credentials/comments/encoding.

This bridge edits the files existing consumers already read. It never launches
modules, reloads tasks, changes devices, or returns arbitrary configuration data.
"""
from __future__ import annotations

import argparse
import codecs
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tomllib
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from configuration_schema import MODULES
import toolbox_preferences as prefs

REPO = Path(__file__).resolve().parents[1]
LIMIT = 262144


class ConfigurationError(ValueError):
    pass


def module_path(module: str) -> Path:
    if module not in MODULES:
        raise ConfigurationError('invalid_module')
    path = REPO / MODULES[module]['path']
    if path.is_symlink() or not path.resolve().is_relative_to(REPO.resolve()):
        raise ConfigurationError('invalid_path')
    return path


def read_bytes(path: Path) -> bytes:
    try:
        with path.open('rb') as stream:
            raw = stream.read(LIMIT + 1)
    except FileNotFoundError:
        raw = b''
    if len(raw) > LIMIT:
        raise ConfigurationError('invalid_config')
    return raw


def revision(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def literal(text: str, module: str):
    if module != 'power':
        return tomllib.loads('value=' + text)['value']
    # PowerPolicy intentionally uses literal backslashes, not standard TOML.
    text = re.sub(r'\s*#.*$', '', text).strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    if text in ('true', 'false'):
        return text == 'true'
    if re.fullmatch(r'-?\d+', text):
        return int(text)
    raise ConfigurationError('invalid_config')


def entries(text: str, module: str) -> tuple[dict, dict]:
    """Read assignment spans, consuming multiline values before scanning keys."""
    lines = text.splitlines(keepends=True)
    values, spans = {}, {}
    section = ''
    index = 0
    while index < len(lines):
        stripped = lines[index].strip()
        if not stripped or stripped.startswith('#'):
            index += 1
            continue
        header = re.fullmatch(r'\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?', stripped)
        if header:
            section = header[1]
            index += 1
            continue
        assignment = re.match(r'^(\s*[A-Za-z0-9_-]+\s*=\s*)(.*)', lines[index])
        if not assignment:
            raise ConfigurationError('unsupported_layout')
        key = assignment[1].split('=')[0].strip()
        key = section + '.' + key if section else key
        if key in values:
            raise ConfigurationError('invalid_config')
        end = index + 1
        source = assignment[2].rstrip('\r\n')
        while True:
            try:
                value = literal(source, module)
                break
            except tomllib.TOMLDecodeError:
                if end >= len(lines):
                    raise ConfigurationError('invalid_config') from None
                source += '\n' + lines[end].rstrip('\r\n')
                end += 1
        values[key] = value
        spans[key] = (index, end, assignment[1])
        index = end
    if module != 'power':
        # Also reject duplicate tables and other layouts the runtime rejects.
        tomllib.loads(text)
    return values, spans


def snapshot(module: str) -> dict:
    raw = read_bytes(module_path(module))
    values, _ = entries(raw.decode('utf-8-sig'), module)
    spec = MODULES[module]
    fields = []
    for definition in spec['fields']:
        key = definition['key']
        fields.append({**definition, 'value': values.get(key, definition['default']),
                       'source': 'config' if key in values else 'default'})
    return dict(version=1, module=module, title=spec['title'], effect=spec['effect'],
                config=spec['path'], revision=revision(raw), fields=fields)


def validate(module: str, changes: object) -> dict:
    if not isinstance(changes, dict):
        raise ConfigurationError('invalid_request')
    allowed = {field['key']: field for field in MODULES[module]['fields']}
    for key, value in changes.items():
        field = allowed.get(key)
        if field is None or field['readonly']:
            raise ConfigurationError('invalid_field')
        kind = field['type']
        valid = False
        if kind == 'bool':
            valid = isinstance(value, bool)
        elif kind in ('int', 'number'):
            valid = (type(value) in ((int,) if kind == 'int' else (int, float))
                     and (type(value) is int or math.isfinite(value)))
            if valid:
                valid = ((field['minimum'] is None or value >= field['minimum'])
                         and (field['maximum'] is None or value <= field['maximum']))
        elif kind == 'string':
            valid = isinstance(value, str) and len(value) <= 2048 and all(ord(c) >= 32 for c in value)
            if valid and module in ('power', 'theme', 'audio'):
                valid = '"' not in value and (module != 'power' or '#' not in value)
        elif kind == 'list':
            valid = (isinstance(value, list) and len(value) <= 64
                     and all(isinstance(item, str) and 0 < len(item) <= 128
                             and not any(ord(c) < 32 or c in '"\\' for c in item) for item in value))
            if module == 'audio':
                valid = valid and bool(value)  # Empty arrays mean defaults in the existing C# reader.
        elif kind == 'map':
            valid = (isinstance(value, dict) and len(value) <= 64
                     and all(re.fullmatch(r'[A-Za-z0-9_-]{1,64}', k)
                             and type(v) is int and 0 <= v <= 4096 for k, v in value.items()))
        if field['choices'] is not None:
            valid = valid and value in field['choices']
        if valid and module == 'theme' and key.startswith('schedule.fixed_'):
            valid = re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d', value) is not None
        if valid and module == 'theme' and key in ('schedule.latitude', 'schedule.longitude') and value:
            try:
                coordinate = float(value)
                bound = 90 if key.endswith('latitude') else 180
                valid = math.isfinite(coordinate) and -bound <= coordinate <= bound
            except ValueError:
                valid = False
        if valid and key.endswith('.endpoint'):
            valid = re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?', value) is not None
        if valid and module == 'rgb' and key == 'capture.region' and value not in ('', 'full'):
            valid = re.fullmatch(r'-?\d+,-?\d+,[1-9]\d*,[1-9]\d*', value) is not None
        if valid and module == 'power' and key == 'caffeine.coffee_dir':
            valid = bool(value.strip())
        if valid and module == 'power' and key == 'general.task_name':
            valid = (re.fullmatch(r'[^\\/:*?"<>|]{1,128}', value) is not None
                     and bool(value.strip()) and value == value.strip() and not value.endswith('.'))
        if not valid:
            raise ConfigurationError('invalid_' + key)
    return changes


def serialize(value, module: str) -> str:
    if isinstance(value, dict):
        return '{ ' + ', '.join(key + ' = ' + str(count) for key, count in value.items()) + ' }'
    if isinstance(value, str) and module == 'power':
        return '"' + value + '"'
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def trailing_comment(line: str) -> str:
    quote, escape = '', False
    for index, char in enumerate(line.rstrip('\r\n')):
        if escape:
            escape = False
        elif quote == '"' and char == '\\':
            escape = True
        elif quote and char == quote:
            quote = ''
        elif not quote and char in "\"'":
            quote = char
        elif not quote and char == '#':
            return '  ' + line[index:].rstrip('\r\n')
    return ''


def render(raw: bytes, module: str, changes: dict) -> bytes:
    text = raw.decode('utf-8-sig')
    newline = '\r\n' if '\r\n' in text else '\n'
    for key, value in changes.items():
        _, spans = entries(text, module)
        lines = text.splitlines(keepends=True)
        rendered = serialize(value, module)
        if key in spans:
            start, end, prefix = spans[key]
            comment = trailing_comment(lines[end - 1])
            lines[start:end] = [prefix + rendered + comment + newline]
        else:
            section, _, name = key.rpartition('.')
            insert = 0
            found = not section
            for index, line in enumerate(lines):
                header = re.fullmatch(r'\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?', line.strip())
                if header:
                    if found:
                        insert = index
                        break
                    if header[1] == section:
                        found = True
                insert = index + 1
            if not found:
                lines.append(newline + '[' + section + ']' + newline)
                insert = len(lines)
            if insert and not lines[insert - 1].endswith(('\r', '\n')):
                lines[insert - 1] += newline
            lines.insert(insert, name + ' = ' + rendered + newline)
        text = ''.join(lines)
    # Verify the exact typed values before publishing the file.
    parsed, _ = entries(text, module)
    if any(parsed.get(key) != value for key, value in changes.items()):
        raise ConfigurationError('invalid_config')
    return (codecs.BOM_UTF8 if raw.startswith(codecs.BOM_UTF8) else b'') + text.encode('utf-8')


def protect_temporary(source: Path, temporary: Path) -> None:
    """Apply the existing file's DACL before writing any configuration bytes."""
    if not source.exists():
        return
    if os.name != 'nt':
        import stat
        temporary.chmod(stat.S_IMODE(source.stat().st_mode))
        return
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetFileAttributesW.argtypes = [wintypes.LPCWSTR]
    kernel.GetFileAttributesW.restype = wintypes.DWORD
    attributes = kernel.GetFileAttributesW(str(source))
    if attributes == 0xFFFFFFFF:
        raise ctypes.WinError(ctypes.get_last_error())
    # Do not silently replace an encrypted/read-only file with an ordinary one.
    # Such specialized files remain editable through their existing owner tools.
    if attributes & (0x4000 | 0x1):
        raise ConfigurationError('protected_config_manual')
    security = ctypes.WinDLL('advapi32', use_last_error=True)
    security.GetFileSecurityW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p,
                                         wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    security.GetFileSecurityW.restype = wintypes.BOOL
    needed = wintypes.DWORD()
    security.GetFileSecurityW(str(source), 4, None, 0, ctypes.byref(needed))
    if not 0 < needed.value <= 65536:
        raise ctypes.WinError(ctypes.get_last_error())
    descriptor = ctypes.create_string_buffer(needed.value)
    if not security.GetFileSecurityW(str(source), 4, descriptor, needed, ctypes.byref(needed)):
        raise ctypes.WinError(ctypes.get_last_error())
    security.GetSecurityDescriptorControl.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.WORD),
                                                      ctypes.POINTER(wintypes.DWORD)]
    security.GetSecurityDescriptorControl.restype = wintypes.BOOL
    control, version = wintypes.WORD(), wintypes.DWORD()
    if not security.GetSecurityDescriptorControl(descriptor, ctypes.byref(control), ctypes.byref(version)):
        raise ctypes.WinError(ctypes.get_last_error())
    security.SetFileSecurityW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p]
    security.SetFileSecurityW.restype = wintypes.BOOL
    flags = 4 | (0x80000000 if control.value & 0x1000 else 0x20000000)
    if not security.SetFileSecurityW(str(temporary), flags, descriptor):
        raise ctypes.WinError(ctypes.get_last_error())


def save(module: str, changes: object, expected_revision: str) -> dict:
    path = module_path(module)
    changes = validate(module, changes)
    # Shared with other module-center writers; no lock/temp artifacts in source
    # other than the short-lived atomic replacement beside the existing config.
    lock = prefs.preference_path().with_name('module-' + module + '.json')
    with prefs._writer_lock(lock):
        raw = read_bytes(path)
        if revision(raw) != expected_revision:
            raise ConfigurationError('settings_changed_reload')
        updated = render(raw, module, changes)
        if updated != raw:
            temporary = path.with_name('.toolbox-config-' + uuid.uuid4().hex + '.tmp')
            try:
                temporary.touch(exist_ok=False)
                protect_temporary(path, temporary)
                with temporary.open('wb') as stream:
                    stream.write(updated)
                    stream.flush()
                    os.fsync(stream.fileno())
                # Detect edits by outside tools as late as possible. OS lock
                # coordinates toolbox writers, not arbitrary external editors.
                if read_bytes(path) != raw:
                    raise ConfigurationError('settings_changed_reload')
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
    return snapshot(module)


def main(argv=None) -> int:
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--module', choices=list(MODULES), required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.apply:
            request = json.loads(sys.stdin.read(LIMIT + 1))
            if not isinstance(request, dict) or set(request) != {'changes', 'revision'}:
                raise ConfigurationError('invalid_request')
            result = save(args.module, request['changes'], request['revision'])
        else:
            result = snapshot(args.module)
        print(json.dumps({'status': 'ok', **result}, ensure_ascii=False, allow_nan=False))
        return 0
    except (ValueError, OSError, TypeError, KeyError, OverflowError) as error:
        code = str(error) if isinstance(error, ConfigurationError) else 'settings_unavailable'
        print(json.dumps({'status': 'error', 'code': code}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
