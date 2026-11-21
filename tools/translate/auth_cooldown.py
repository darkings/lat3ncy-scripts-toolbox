"""Best-effort Tencent auth circuit breaker for independent one-shot workers.

Only a credential/config digest and bounded expiry are persisted, never keys or
provider responses. Strict auth mode ignores this state entirely.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import time
import uuid

COOLDOWN_SECONDS = 300


def identity(keys: tuple[str, str], section: dict) -> str:
    fields = {key: section.get(key) for key in ("region", "endpoint", "project_id")}
    payload = json.dumps([keys, fields], sort_keys=True, ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def state_path(cache_root: Path) -> Path:
    repo = os.path.normcase(str(Path(__file__).resolve().parents[2]))
    owner = hashlib.sha256(repo.encode("utf-8")).hexdigest()[:24]
    return cache_root / "state" / ("auth-cooldown-" + owner + ".json")


def active(path: Path, fingerprint: str) -> bool:
    try:
        with path.open("rb") as handle:
            record = json.loads(handle.read(1024))
        until = record["until"]
        return (record["version"] == 1 and record["identity"] == fingerprint
                and isinstance(until, (int, float)) and not isinstance(until, bool)
                and time.time() < until <= time.time() + COOLDOWN_SECONDS)
    except (OSError, ValueError, TypeError, KeyError):
        return False


def record_failure(path: Path, fingerprint: str) -> None:
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary.write_text(json.dumps({"version": 1, "identity": fingerprint,
                                         "until": time.time() + COOLDOWN_SECONDS}), encoding="utf-8")
        os.replace(temporary, path)
    except OSError:
        pass  # inability to persist must not stop successful Google fallback
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def clear(path: Path, fingerprint: str) -> None:
    # Best-effort cleanup; mismatched identities are ignored.
    if active(path, fingerprint):
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
