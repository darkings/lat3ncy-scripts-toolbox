"""Run OCR with its matching base interpreter and existing isolated dependencies.

Invoke with -I -S. No packages are installed and no integrity labels are changed.
"""
import json
from pathlib import Path
import re
import site
import sys

ROOT = Path(__file__).resolve().parent


def activate_environment(module: Path = ROOT) -> dict:
    if not sys.flags.isolated or not sys.flags.no_site:
        raise RuntimeError('OCR host requires -I -S')
    environment = module/'.venv314'
    settings = {}
    for line in (environment/'pyvenv.cfg').read_text('utf-8-sig').splitlines():
        key, separator, value = line.partition('=')
        if separator:
            settings[key.strip()] = value.strip()
    version = re.fullmatch(r'(\d+)\.(\d+)(?:\.\d+)?', settings.get('version_info', settings.get('version', '')))
    if not version or tuple(map(int, version.groups()[:2])) != sys.version_info[:2]:
        raise RuntimeError('OCR host and environment Python versions differ')
    home = Path(settings.get('home', ''))
    if not home.is_absolute() or home.resolve() != Path(sys._base_executable).resolve().parent:
        raise RuntimeError('OCR host does not match the environment base')
    packages = environment/'Lib/site-packages'
    if not packages.is_dir():
        raise RuntimeError('OCR dependency directory is missing')
    # -I -S excludes ambient/global/user packages; only the declared environment
    # is added, including its own trusted .pth/DLL initialization.
    site.addsitedir(str(packages))
    sys.path.insert(0, str(module))
    return {'base': sys.executable, 'environment': str(environment), 'site': str(packages)}


def main() -> int:
    try:
        metadata = activate_environment()
        if '--check' in sys.argv:
            from ocr_runtime import installed_status
            status = installed_status()
            if status['status'] == 'ready':
                import PIL
                import pyperclip
                import rapidocr_onnxruntime
            print(json.dumps({**metadata, **status}))
            return 0 if status['status'] == 'ready' else 2
        if '--workflow' in sys.argv:
            from ocr_runtime import installed_status
            if sys.version_info[:2] != (3, 14) or installed_status()['status'] != 'ready':
                raise RuntimeError('Screenshot translation requires the locked Python 3.14 environment')
            sys.argv.remove('--workflow')
            import ocr_workflow as entry
        else:
            import ocr as entry
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        message = 'OCR host initialization failed: ' + type(error).__name__
        if '--result-file' in sys.argv:
            index = sys.argv.index('--result-file') + 1
            if index < len(sys.argv):
                try:
                    Path(sys.argv[index]).write_text('ERROR: ' + message, encoding='utf-8')
                except OSError:
                    pass
        if sys.stderr is not None:
            print(message, file=sys.stderr)
        return 1
    return entry.main()


if __name__ == '__main__':
    raise SystemExit(main())
