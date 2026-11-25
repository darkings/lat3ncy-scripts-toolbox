"""Non-secret settings backup, preview and migration bridge.

Only allowlisted fields from configuration_schema, validated preferences and
non-secret controls are exported. Credentials, raw TOML, logs and unknown keys
never enter a bundle. Preview is always computed before any write.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolbox_configuration as config
import toolbox_preferences as prefs
import toolbox_controls as controls
from configuration_schema import MODULES

FORMAT_VERSION = 1
LIMIT = 262144
SECRET_MARKERS = ('secret', 'password', 'token', 'credential', 'access_key')


class TransferError(ValueError):
    pass


def _public(key: str) -> bool:
    return not any(marker in key.lower() for marker in SECRET_MARKERS)


def _migrate(payload: dict) -> dict:
    """Normalize legacy bundles; version 0 used sections with field lists."""
    version = payload.get('version')
    if version == 0:
        modules = {}
        for name, data in (payload.get('sections') or {}).items():
            if name not in MODULES or not isinstance(data, dict):
                continue
            raw_fields = data.get('fields')
            fields = {}
            if isinstance(raw_fields, dict):
                fields = {str(key): value for key, value in raw_fields.items()}
            elif isinstance(raw_fields, list):
                for field in raw_fields:
                    if isinstance(field, dict) and isinstance(field.get('key'), str):
                        fields[field['key']] = field.get('value')
            modules[name] = {'revision': data.get('revision', ''), 'config': MODULES[name]['path'],
                             'fields': fields, 'skipped': [], 'readonly': []}
        payload = {'version': 1, 'modules': modules,
                   'preferences': {'revision': '', 'values': {}},
                   'controls': {'revision': '', 'values': {}}}
    for data in (payload.get('modules') or {}).values():
        if not isinstance(data, dict):
            raise TransferError('invalid_bundle')
        fields = data.get('fields')
        if isinstance(fields, list):
            normalized = {}
            for field in fields:
                if isinstance(field, dict) and isinstance(field.get('key'), str):
                    normalized[field['key']] = field.get('value')
            data['fields'] = normalized
        elif not isinstance(fields, dict):
            raise TransferError('invalid_bundle')
    return payload


def load_payload(source) -> dict:
    if isinstance(source, (bytes, bytearray)):
        if len(source) > LIMIT:
            raise TransferError('bundle_too_large')
        try:
            source = source.decode('utf-8-sig')
        except UnicodeError:
            raise TransferError('invalid_bundle') from None
    if isinstance(source, str):
        try:
            source = json.loads(source)
        except ValueError:
            raise TransferError('invalid_bundle') from None
    if isinstance(source, dict) and source.get('status') == 'ok' and isinstance(source.get('bundle'), dict):
        source = source['bundle']
    if not isinstance(source, dict) or source.get('version') not in (0, 1):
        raise TransferError('unsupported_version')
    source = _migrate(source)
    for key in ('modules', 'preferences', 'controls'):
        if key not in source or not isinstance(source[key], dict):
            raise TransferError('invalid_bundle')
    return source


def export_payload() -> dict:
    modules = {}
    for name, spec in MODULES.items():
        snap = config.snapshot(name)
        fields, skipped = {}, []
        for field in snap['fields']:
            key = field['key']
            if not _public(key) or field['readonly']:
                skipped.append(key)
                continue
            fields[key] = field['value']
        modules[name] = {'revision': snap['revision'], 'config': spec['path'], 'fields': fields,
                         'skipped': skipped,
                         'readonly': [f['key'] for f in snap['fields'] if f['readonly']]}
    state = prefs.snapshot()
    preferences = {'revision': state['revision'],
                   'values': {section: {key: value for key, value in fields.items() if _public(key)}
                              for section, fields in state['values'].items()}}
    profile = controls.snapshot()
    profile_values = {key: value for key, value in profile['values'].items()
                      if key != 'version' and _public(key)}
    return {'version': FORMAT_VERSION,
            'created_utc': datetime.now(timezone.utc).isoformat(),
            'modules': modules,
            'preferences': preferences,
            'controls': {'revision': profile['revision'], 'values': profile_values}}


def _diff(scope: str, identifier: str, current: dict, incoming: dict, allowed=None) -> list:
    changes = []
    for key, value in incoming.items():
        if not _public(key):
            continue
        if allowed is not None and key not in allowed:
            continue
        if key not in current or current[key] != value:
            changes.append({'scope': scope, 'id': identifier, 'key': key,
                            'current': current.get(key), 'incoming': value})
    return changes


def preview(source) -> dict:
    payload = load_payload(source)
    changes, conflicts, notes = [], [], []
    for name, data in payload['modules'].items():
        if name not in MODULES:
            notes.append({'scope': 'module', 'id': name, 'reason': 'unknown_module_skipped'})
            continue
        current = config.snapshot(name)
        if data.get('revision') and data['revision'] != current['revision']:
            conflicts.append({'scope': 'module', 'id': name, 'reason': 'revision_changed'})
        allowed = {f['key'] for f in current['fields'] if not f['readonly']}
        changes.extend(_diff('module', name,
                             {f['key']: f['value'] for f in current['fields']}, data['fields'], allowed))
        for key in data['fields']:
            if key not in allowed:
                notes.append({'scope': 'module', 'id': name, 'key': key,
                              'reason': 'readonly_or_unknown_skipped'})

    state = prefs.snapshot()
    pref_rev = payload['preferences'].get('revision')
    if pref_rev and pref_rev != state['revision']:
        conflicts.append({'scope': 'preferences', 'id': 'preferences', 'reason': 'revision_changed'})
    for section, fields in payload['preferences'].get('values', {}).items():
        if section not in state['values'] or not isinstance(fields, dict):
            notes.append({'scope': 'preferences', 'id': str(section), 'reason': 'unknown_section_skipped'})
            continue
        changes.extend(_diff('preferences', section, state['values'][section], fields,
                             set(state['values'][section])))

    profile = controls.snapshot()
    control_rev = payload['controls'].get('revision')
    if control_rev and control_rev != profile['revision']:
        conflicts.append({'scope': 'controls', 'id': 'controls', 'reason': 'revision_changed'})
    incoming_controls = {key: value for key, value in payload['controls'].get('values', {}).items()
                         if key in profile['values'] and key != 'version'}
    changes.extend(_diff('controls', 'controls', profile['values'], incoming_controls,
                         set(incoming_controls)))
    merged = dict(profile['values'])
    merged.update(incoming_controls)
    try:
        controls.check_conflicts(merged)
    except controls.ControlsError:
        conflicts.append({'scope': 'controls', 'id': 'controls', 'reason': 'hotkey_conflict'})

    return {'version': FORMAT_VERSION, 'changes': changes, 'conflicts': conflicts, 'notes': notes,
            'summary': {'changes': len(changes), 'conflicts': len(conflicts), 'notes': len(notes)}}


def apply(source) -> dict:
    payload = load_payload(source)
    report = preview(payload)
    if report['conflicts']:
        raise TransferError('conflicts')
    applied = []
    for name, data in payload['modules'].items():
        current = config.snapshot(name)
        changes = {c['key']: c['incoming'] for c in report['changes']
                   if c['scope'] == 'module' and c['id'] == name}
        if changes:
            config.save(name, changes, current['revision'])
            applied.append({'scope': 'module', 'id': name, 'fields': len(changes)})
    pref_changes = {}
    for change in report['changes']:
        if change['scope'] == 'preferences':
            pref_changes.setdefault(change['id'], {})[change['key']] = change['incoming']
    if pref_changes:
        prefs.save(pref_changes, prefs.snapshot()['revision'])
        applied.append({'scope': 'preferences', 'id': 'preferences', 'sections': len(pref_changes)})
    control_changes = {c['key']: c['incoming'] for c in report['changes'] if c['scope'] == 'controls'}
    if control_changes:
        controls.save(control_changes, controls.snapshot()['revision'])
        applied.append({'scope': 'controls', 'id': 'controls', 'fields': len(control_changes)})
    return {'applied': applied, 'preview': report['summary']}


def main(argv=None) -> int:
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--export', action='store_true')
    mode.add_argument('--preview', metavar='FILE')
    mode.add_argument('--apply', metavar='FILE')
    args = parser.parse_args(argv)
    try:
        if args.export:
            result = export_payload()
        else:
            path = Path(args.preview or args.apply)
            if not path.is_file() or path.stat().st_size > LIMIT:
                raise TransferError('invalid_bundle')
            raw = path.read_bytes()
            result = {'status': 'ok', **({'preview': preview(raw)} if args.preview else {'result': apply(raw)})}
    except (ValueError, OSError, TypeError, KeyError, OverflowError) as error:
        code = str(error) if isinstance(error, TransferError) else 'transfer_unavailable'
        print(json.dumps({'status': 'error', 'code': code}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
