"""Fixed titlebar plan; never enumerates or changes windows, or exports other settings."""
from pathlib import Path
import json
import re
import sys
import tomllib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolbox_configuration as config
import toolbox_controls as controls


def plan() -> dict:
    raw = config.read_bytes(config.module_path('theme'))
    values = tomllib.loads(raw.decode('utf-8-sig')).get('titlebar', {})
    if not isinstance(values, dict): raise ValueError('invalid_titlebar')
    fields = {item['key']: values.get(item['key'].split('.')[1], item['default']) for item in config.MODULES['theme']['fields'] if item['key'].startswith('titlebar.')}
    config.validate('theme', fields)
    return {'version': 1, 'enabled': controls.module_enabled('theme') and fields['titlebar.enabled'],
            'mode': fields['titlebar.mode'], 'process_names': [re.sub(r'(?i)\.exe$', '', item) for item in fields['titlebar.process_names']],
            'revision': config.revision(raw)}


def main() -> int:
    if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8')
    try:
        print(json.dumps({'status': 'ok', **plan()}, ensure_ascii=False)); return 0
    except (OSError, ValueError, TypeError):
        print(json.dumps({'status': 'error', 'code': 'titlebar_config'})); return 1


if __name__ == '__main__': raise SystemExit(main())
