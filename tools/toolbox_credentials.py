"""Write-only translation credentials bridge. No network, secret readback or logs."""
from __future__ import annotations

import argparse
import json
import os
import sys
import uuid

sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import toolbox_configuration as config
import toolbox_preferences as prefs

PROVIDERS = {
    'tencent': ('腾讯云', [('secret_id', 'Secret ID', ('TENCENTCLOUD_SECRET_ID', 'TENCENT_SECRET_ID', 'QCLOUD_SECRET_ID')),
                          ('secret_key', 'Secret Key', ('TENCENTCLOUD_SECRET_KEY', 'TENCENT_SECRET_KEY', 'QCLOUD_SECRET_KEY'))]),
    'aliyun': ('阿里云', [('access_key_id', 'AccessKey ID', ('ALIBABA_CLOUD_ACCESS_KEY_ID', 'ALIYUN_ACCESS_KEY_ID', 'ALIBABA_ACCESS_KEY_ID')),
                        ('access_key_secret', 'AccessKey Secret', ('ALIBABA_CLOUD_ACCESS_KEY_SECRET', 'ALIYUN_ACCESS_KEY_SECRET', 'ALIBABA_ACCESS_KEY_SECRET'))]),
}


class CredentialError(ValueError):
    pass


def environment_present(names: tuple[str, ...]) -> bool:
    for name in names:
        if os.environ.get(name, '').strip(): return True
        if os.name == 'nt':
            try:
                import winreg
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
                    value, _ = winreg.QueryValueEx(key, name)
                    if isinstance(value, str) and value.strip(): return True
            except OSError:
                pass
    return False


def snapshot() -> dict:
    raw = config.read_bytes(config.module_path('translate'))
    values, _ = config.entries(raw.decode('utf-8-sig'), 'translate')
    providers = []
    for provider, (label, definitions) in PROVIDERS.items():
        local_first = values.get(provider + '.prefer_config_credentials') is True
        fields = []
        for name, title, env in definitions:
            local = isinstance(values.get(provider + '.' + name), str) and bool(values[provider + '.' + name].strip())
            environment = environment_present(env)
            source = ('config' if local else 'missing') if local_first else ('environment' if environment else 'config' if local else 'missing')
            fields.append({'id': name, 'label': title, 'configured': source != 'missing', 'source': source, 'local_configured': local})
        providers.append({'id': provider, 'label': label, 'prefer_config': local_first, 'fields': fields})
    return {'version': 1, 'revision': config.revision(raw), 'providers': providers}


def save(provider: str, changes: object, revision: str, *, clear: bool = False) -> dict:
    if provider not in PROVIDERS or not isinstance(changes, dict) or type(clear) is not bool:
        raise CredentialError('invalid_request')
    allowed = {name for name, *_ in PROVIDERS[provider][1]}
    if set(changes) - allowed or (clear and changes): raise CredentialError('invalid_field')
    if not clear and (not changes or any(not isinstance(value, str) or not 1 <= len(value.strip()) <= 2048
                            or any(ord(c) < 32 for c in value) for value in changes.values())):
        raise CredentialError('invalid_credentials')
    updates = {provider + '.' + name: '' for name in allowed} if clear else {
        provider + '.' + name: value.strip() for name, value in changes.items()}
    # An explicit UI edit must take effect even if an old environment key exists.
    updates[provider + '.prefer_config_credentials'] = not clear
    path = config.module_path('translate')
    with prefs._writer_lock(prefs.preference_path().with_name('module-translate.json')):
        raw = config.read_bytes(path)
        if config.revision(raw) != revision: raise CredentialError('settings_changed_reload')
        current, _ = config.entries(raw.decode('utf-8-sig'), 'translate')
        if not clear and any(not str(updates.get(provider + '.' + name, current.get(provider + '.' + name, ''))).strip() for name in allowed):
            raise CredentialError('invalid_credentials_pair')
        updated = config.render(raw, 'translate', updates)
        temporary = path.with_name('.toolbox-config-' + uuid.uuid4().hex + '.tmp')
        try:
            temporary.touch(exist_ok=False)
            config.protect_temporary(path, temporary)
            with temporary.open('wb') as stream:
                stream.write(updated); stream.flush(); os.fsync(stream.fileno())
            if config.read_bytes(path) != raw: raise CredentialError('settings_changed_reload')
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    return snapshot()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise CredentialError('invalid_request')
        result[key] = value
    return result


def main() -> int:
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, 'reconfigure'): stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--apply', action='store_true'); args = parser.parse_args()
    try:
        if args.apply:
            request = json.loads(sys.stdin.read(16385), object_pairs_hook=unique_object)
            if not isinstance(request, dict) or set(request) - {'provider', 'changes', 'revision', 'clear'}: raise CredentialError('invalid_request')
            result = save(request['provider'], request.get('changes', {}), request['revision'], clear=request.get('clear', False))
        else: result = snapshot()
        print(json.dumps({'status': 'ok', **result}, ensure_ascii=False)); return 0
    except (ValueError, OSError, TypeError, KeyError) as error:
        # Never return exception text: TOML/parser errors can contain credentials.
        code = 'settings_changed_reload' if isinstance(error, CredentialError) and str(error) == 'settings_changed_reload' else 'credentials_not_saved'
        print(json.dumps({'status': 'error', 'code': code})); return 1


if __name__ == '__main__': raise SystemExit(main())
