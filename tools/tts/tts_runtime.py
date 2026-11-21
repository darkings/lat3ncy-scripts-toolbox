"""Deterministic, repository-owned profile environment; never changes file ACLs."""
import os
from pathlib import Path


def owner_name(module: Path) -> str:
    return str(module.absolute()).rstrip('\\/').lower()


def owner_key(module: Path) -> str:
    # Same UTF-8 FNV-1a contract as ToolboxInstance.Hash in AHK.
    value = 2166136261
    for byte in owner_name(module).encode('utf-8'):
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return f'{value:08x}'


def profile_directory(module: Path, local_data: str | None = None) -> Path:
    root = local_data if local_data is not None else os.environ.get('LOCALAPPDATA')
    if not root:
        raise ValueError('LOCALAPPDATA is required for the profile environment')
    return Path(root)/'lat3ncy-toolbox'/'tts-runtimes'/owner_key(module)


def owns_profile(directory: Path, module: Path, *, ready: bool = False) -> bool:
    try:
        return (directory/('.ready.txt' if ready else '.owner.txt')).read_text('utf-8').strip() == owner_name(module)
    except OSError:
        return False


def claim_profile(directory: Path, module: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    if owns_profile(directory, module):
        return
    if any(directory.iterdir()):
        raise ValueError('Refusing an unowned or foreign TTS environment')
    # Exclusive creation also prevents concurrent claims from replacing owners.
    with (directory/'.owner.txt').open('x', encoding='utf-8') as output:
        output.write(owner_name(module))


def publish_ready(directory: Path, module: Path) -> None:
    if not owns_profile(directory, module):
        raise ValueError('Cannot publish a foreign TTS environment')
    temporary = directory/f'.ready.{os.getpid()}.tmp'
    try:
        temporary.write_text(owner_name(module), encoding='utf-8')
        os.replace(temporary, directory/'.ready.txt')
    finally:
        temporary.unlink(missing_ok=True)
