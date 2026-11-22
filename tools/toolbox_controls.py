"""Shared non-secret function/hotkey policy; defaults come from current AHK source.

The flat profile lives at the repository root and is ignored by Git. Runtime
consumers can read booleans without interpreting commands or executing config.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid

REPO = Path(__file__).resolve().parents[1]
LIMIT = 16384
MODULES = {'translate': '翻译', 'tts': '朗读', 'ocr': '截图识别', 'audio': '音频切换',
           'theme': '主题、壁纸与背光', 'power': '电源与唤醒', 'rgb': '氛围灯', 'capture': '截图与录屏'}
FEATURES = [
    ('CapsLockIme', 'CapsLock 输入法增强', '', 'leader'),
    ('SpeakSelectedText', '朗读选中文字', 'tts', 'hotkey'),
    ('TranslateSelectedText', '划词翻译', 'translate', 'hotkey'),
    ('ScreenshotTranslate', '截图翻译', 'ocr', 'hotkey'),
    ('SearchSelectedText', '搜索选中文字', '', 'hotkey'),
    ('OpenSelectedTarget', '打开选中目标', '', 'hotkey'),
    ('LocateSelectedTarget', '定位选中目标', '', 'hotkey'),
    ('AlwaysOnTop', '窗口置顶', '', 'hotkey'),
    ('HideActiveWindow', '隐藏当前窗口', '', 'hotkey'),
    ('ToggleHiddenFiles', '显示隐藏文件', '', 'hotkey'),
    ('ToggleDotfiles', '切换点文件', '', 'hotkey'),
    ('ToggleFileExtensions', '显示文件扩展名', '', 'hotkey'),
    ('AudioSwitcher', '音频输出切换', 'audio', 'hotkey'),
    ('KillForegroundProcess', '结束前台进程', '', 'hotkey'),
    ('RestartForegroundProcess', '重启前台进程', '', 'hotkey'),
    ('SmartPaste', '智能粘贴', '', 'hotkey'),
    ('SwitchAppWindowNext', '同应用下一窗口', '', 'hotkey'),
    ('SwitchAppWindowPrevious', '同应用上一窗口', '', 'hotkey'),
    ('VsCodeCopyPath', 'VS Code 复制路径转发', '', 'editor-vscode'),
    ('ZedCopyPath', 'Zed 复制路径转发', '', 'editor-zed'),
    ('ThinkPadBacklight', 'ThinkPad 键盘背光', 'theme', 'resident'),
    ('CaffeineIndicator', 'Caffeine 状态图标', '', 'resident'),
    ('FindMouse', '摇动定位指针', '', 'resident'),
]
CONFIGS = {'ocr': 'tools/raycast-scripts/ocr/config.toml',
           'capture': 'tools/raycast-scripts/capture/config.toml',
           **{name: f'tools/{name}/config.toml' for name in ('translate', 'tts', 'rgb')},
           'audio': 'tools/audio-switcher/config.toml',
           'power': 'tools/power-policy/config.toml', 'theme': 'tools/theme-scheduler/config.toml'}


class ControlsError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ControlsError('invalid_controls')
        result[key] = value
    return result


def profile_path() -> Path:
    return REPO / '.toolbox-controls.json'


def shortcut_defaults() -> dict[str, str]:
    source = (REPO / 'ahk/shortcuts.ahk').read_text(encoding='utf-8-sig')
    found = dict(re.findall(r'^\s*static\s+(\w+)\s*:=\s*"([^"\r\n]+)"\s*$', source, re.M))
    if any(name not in found for name, _, _, kind in FEATURES if kind != 'resident'):
        raise ControlsError('shortcut_defaults_unavailable')
    return found


def defaults() -> dict:
    shortcuts = shortcut_defaults()
    result = {'version': 1, 'tray_visible': True}
    result.update({f'module_{name}_enabled': True for name in MODULES})
    for name, _, _, kind in FEATURES:
        result[f'feature_{name}_enabled'] = True
        if kind != 'resident':
            result[f'hotkey_{name}_enabled'] = True
            result[f'binding_{name}'] = shortcuts[name]
    return result


KEY = r'(?:[A-Za-z0-9]|[.,/;=\[\]-]|F(?:[1-9]|1\d|2[0-4])|sc[0-9A-Fa-f]{3}|vk[0-9A-Fa-f]{2}|Tab|Space|Enter|Esc|Escape|Backspace|Delete|Insert|Home|End|PgUp|PgDn|Up|Down|Left|Right|AppsKey|PrintScreen|Pause|ScrollLock|NumLock|Numpad(?:[0-9]|Add|Sub|Mult|Div|Dot|Enter))'


def normalize_binding(value: str) -> str:
    if not isinstance(value, str) or not 0 < len(value) <= 80:
        raise ControlsError('invalid_binding')
    value = value.strip()
    if re.fullmatch(r'~?CapsLock\s*&\s*' + KEY, value, re.I):
        return 'capslock & ' + normalize_binding(value.split('&')[1].strip())
    match = re.fullmatch(r'[~$]*([!^+#]*)(' + KEY + ')', value, re.I)
    if not match or len(set(match[1])) != len(match[1]):
        raise ControlsError('invalid_binding')
    if re.fullmatch(r'sc[0-9a-f]{3}', match[2], re.I) and not 1 <= int(match[2][2:], 16) <= 0x1FF:
        raise ControlsError('invalid_binding')
    if re.fullmatch(r'vk[0-9a-f]{2}', match[2], re.I) and not 1 <= int(match[2][2:], 16) <= 0xFE:
        raise ControlsError('invalid_binding')
    key = match[2].lower()
    return ''.join(c for c in '^!+#' if c in match[1]) + ('esc' if key == 'escape' else key)


def validate(changes: object, base: dict) -> dict:
    if not isinstance(changes, dict) or set(changes) - (set(base) - {'version'}):
        raise ControlsError('invalid_field')
    for key, value in changes.items():
        if isinstance(base[key], bool):
            if not isinstance(value, bool):
                raise ControlsError('invalid_' + key)
        elif key == 'binding_CapsLockIme':
            if value != base[key]:
                raise ControlsError('capslock_base_is_fixed')
        elif key.startswith('binding_'):
            normalize_binding(value)
        else:
            raise ControlsError('invalid_field')
    return changes


def check_conflicts(values: dict) -> None:
    registered = {}
    for name, _, module, kind in FEATURES:
        if kind in ('resident', 'leader'):
            continue
        if not values[f'feature_{name}_enabled'] or not values[f'hotkey_{name}_enabled']:
            continue
        if module and not values[f'module_{module}_enabled']:
            continue
        if name == 'ScreenshotTranslate' and not values['module_translate_enabled']:
            continue
        binding = normalize_binding(values[f'binding_{name}'])
        context = kind if kind.startswith('editor-') else 'global'
        for previous, previous_context in registered.get(binding, []):
            if context == 'global' or previous_context == 'global' or context == previous_context:
                raise ControlsError('hotkey_conflict_' + previous + '_' + name)
        registered.setdefault(binding, []).append((name, context))


def read_raw() -> bytes:
    try:
        with profile_path().open('rb') as stream:
            raw = stream.read(LIMIT + 1)
    except FileNotFoundError:
        return b''
    if len(raw) > LIMIT:
        raise ControlsError('invalid_controls')
    return raw


def read_profile() -> tuple[dict, str]:
    raw = read_raw()
    base = defaults()
    if raw:
        try:
            doc = json.loads(raw, object_pairs_hook=unique_object)
            if not isinstance(doc, dict) or type(doc.get('version')) is not int or doc['version'] != 1:
                raise ValueError()
            validate({key: value for key, value in doc.items() if key != 'version'}, base)
            base.update(doc)
            check_conflicts(base)
        except (ValueError, TypeError, KeyError):
            raise ControlsError('invalid_controls') from None
    return base, hashlib.sha256(raw).hexdigest()


def snapshot() -> dict:
    values, revision = read_profile()
    keys = shortcut_defaults()
    return {'version': 1, 'revision': revision, 'values': values,
            'modules': [{'id': name, 'label': label} for name, label in MODULES.items()],
            'features': [{'id': name, 'label': label, 'module': module, 'kind': kind,
                          'default': keys.get(name, '')} for name, label, module, kind in FEATURES]}


def save(changes: object, expected_revision: str, *, reset_shortcuts: bool = False) -> dict:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import toolbox_preferences as prefs
    from toolbox_configuration import protect_temporary
    base = defaults()
    changes = validate(changes, base)
    if not isinstance(reset_shortcuts, bool):
        raise ControlsError('invalid_request')
    path = profile_path()
    with prefs._writer_lock(prefs.preference_path().with_name('controls.json')):
        values, current = read_profile()
        if current != expected_revision:
            raise ControlsError('settings_changed_reload')
        if reset_shortcuts:
            for key, value in base.items():
                if key.startswith(('binding_', 'hotkey_')):
                    values[key] = value
        values.update(changes)
        check_conflicts(values)
        temporary = path.with_name('.toolbox-controls-' + uuid.uuid4().hex + '.tmp')
        try:
            temporary.touch(exist_ok=False)
            protect_temporary(path, temporary)
            with temporary.open('w', encoding='utf-8', newline='\n') as stream:
                json.dump(values, stream, ensure_ascii=False, indent=2)
                stream.flush(); os.fsync(stream.fileno())
            if hashlib.sha256(read_raw()).hexdigest() != current:
                raise ControlsError('settings_changed_reload')
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    return snapshot()


def module_enabled(module: str, config_path: str | Path | None = None) -> bool:
    if module not in MODULES:
        return False
    if config_path is not None and Path(config_path).resolve() != (REPO / CONFIGS[module]).resolve():
        return True  # Explicit isolated/standalone CLI configurations retain their semantics.
    if not profile_path().exists():
        return True
    try:
        values, _ = read_profile()
        return values[f'module_{module}_enabled']
    except (ValueError, OSError, KeyError):
        return False


def main(argv=None) -> int:
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.apply:
            request = json.loads(sys.stdin.read(LIMIT + 1), object_pairs_hook=unique_object)
            if (not isinstance(request, dict) or not {'changes', 'revision'} <= set(request)
                    or set(request) - {'changes', 'revision', 'reset_shortcuts'}):
                raise ControlsError('invalid_request')
            result = save(request['changes'], request['revision'], reset_shortcuts=request.get('reset_shortcuts', False))
        else:
            result = snapshot()
        print(json.dumps({'status': 'ok', **result}, ensure_ascii=False))
        return 0
    except (ValueError, OSError, TypeError, KeyError) as error:
        code = str(error) if isinstance(error, ControlsError) else 'controls_unavailable'
        print(json.dumps({'status': 'error', 'code': code}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
