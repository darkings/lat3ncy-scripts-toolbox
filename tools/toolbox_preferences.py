"""Repository-scoped, non-secret preferences. Credentials remain in module TOML/env.

The CLI is a local JSON bridge for native settings UI. It never returns TOML or
exception details. Writers use an OS lock, optimistic revision and atomic replace.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import tomllib
import uuid

REPO = Path(__file__).resolve().parents[1]
DEFAULTS = {
    "translate": {"engine": "tencent", "source_language": "auto", "target_language": "auto",
                  "fallback_without_credentials": False, "fallback_on_auth_error": False,
                  "long_text_enabled": False},
    "tts": {"engine": "auto", "zh_voice": "Microsoft Yaoyao", "en_voice": "Microsoft Zira",
            "rate": "+0%", "pitch": "+0Hz", "volume": "+0%"},
}
TRANSLATE_ALIASES = {"google": "google_gtx", "gtx": "google_gtx", "ali": "aliyun", "alibaba": "aliyun",
                     "alimt": "aliyun", "aliyun_mt": "aliyun", "tmt": "tencent", "qcloud": "tencent",
                     "tencentcloud": "tencent", "tencent_mt": "tencent"}


class PreferenceError(ValueError):
    pass


def preference_path() -> Path:
    root = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    identity = hashlib.sha256(os.path.normcase(str(REPO.resolve())).encode("utf-8")).hexdigest()[:24]
    return root / "lat3ncy-toolbox" / "preferences" / identity / "preferences.json"


def validate(values: object) -> dict:
    if not isinstance(values, dict) or any(section not in DEFAULTS for section in values):
        raise PreferenceError("invalid_section")
    result = {}
    enums = {
        ("translate", "engine"): {"tencent", "aliyun", "google_gtx", "mymemory"},
        ("translate", "source_language"): {"auto", "zh", "en"},
        ("translate", "target_language"): {"auto", "zh", "en"},
        ("tts", "engine"): {"auto", "winrt", "edge"},
    }
    for section, fields in values.items():
        if not isinstance(fields, dict) or any(key not in DEFAULTS[section] for key in fields):
            raise PreferenceError("invalid_field")
        result[section] = {}
        for key, value in fields.items():
            label = f"{section}.{key}"
            if (section, key) in enums:
                valid = isinstance(value, str) and value in enums[(section, key)]
            elif isinstance(DEFAULTS[section][key], bool):
                valid = isinstance(value, bool)
            elif key in {"zh_voice", "en_voice"}:
                valid = isinstance(value, str) and 0 < len(value) <= 128 and not any(ord(c) < 32 for c in value)
            else:
                suffix = "Hz" if key == "pitch" else "%"
                valid = isinstance(value, str) and re.fullmatch(r"[+-]\d{1,3}" + suffix, value) is not None
                if valid:
                    number = int(value[:-len(suffix)])
                    valid = (-90 if key == "rate" else -100) <= number <= 100
            if not valid:
                raise PreferenceError("invalid_" + label)
            result[section][key] = value
    return result


def read_overlay() -> tuple[dict, str]:
    path = preference_path()
    try:
        with path.open("rb") as handle:
            raw = handle.read(16385)
    except FileNotFoundError:
        raw = b""
    if len(raw) > 16384:
        raise PreferenceError("invalid_preferences")
    revision = hashlib.sha256(raw).hexdigest()
    if not raw:
        return {}, revision
    try:
        doc = json.loads(raw)
        if set(doc) != {"version", "values"} or doc["version"] != 1:
            raise ValueError()
        return validate(doc["values"]), revision
    except (ValueError, TypeError, KeyError, UnicodeError):
        raise PreferenceError("invalid_preferences") from None


def apply_overlay(section: str, cfg: dict, config_path: str | Path | None = None) -> dict:
    # Explicit test/standalone configs retain their exact, isolated semantics.
    default_path = (REPO / "tools" / section / "config.toml").resolve()
    if config_path is not None and Path(config_path).resolve() != default_path:
        return cfg
    overlay, _ = read_overlay()
    return {**cfg, **overlay.get(section, {})}


def snapshot(*, proposed: dict | None = None) -> dict:
    values = {}
    for section, defaults in DEFAULTS.items():
        fields = dict(defaults)
        try:
            with (REPO / "tools" / section / "config.toml").open("rb") as handle:
                cfg = tomllib.load(handle)
            fields.update({key: cfg[key] for key in defaults if key in cfg})
        except FileNotFoundError:
            pass
        except (ValueError, OSError):
            raise PreferenceError("invalid_" + section + "_config") from None
        # Keep aliases already supported by the CLI compatible with settings.
        if section == "translate":
            engine = fields["engine"].strip().lower() if isinstance(fields["engine"], str) else ""
            fields["engine"] = TRANSLATE_ALIASES.get(engine, engine)
            for key in ("source_language", "target_language"):
                language = fields[key].strip().lower() if isinstance(fields[key], str) else ""
                fields[key] = {"zh-cn": "zh", "zh-hans": "zh"}.get(language, language)
        values[section] = fields
    overlay, revision = read_overlay()
    if proposed is not None:
        overlay = proposed
    for section, fields in overlay.items():
        values[section].update(fields)
    return {"version": 1, "revision": revision, "values": validate(values)}


@contextmanager
def _writer_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a+b") as handle:
        handle.seek(0, 2)
        if handle.tell() == 0:
            handle.write(b"0")
            handle.flush()
        deadline = time.monotonic() + 2
        while True:
            try:
                handle.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise PreferenceError("settings_busy") from None
                time.sleep(0.025)
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == "nt":
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle, fcntl.LOCK_UN)


def save(changes: object, expected_revision: str) -> dict:
    changes = validate(changes)
    path = preference_path()
    with _writer_lock(path):
        overlay, revision = read_overlay()
        if revision != expected_revision:
            raise PreferenceError("settings_changed_reload")
        for section, fields in changes.items():
            overlay.setdefault(section, {}).update(fields)
        # Validate the effective result before writing; never report a rejected
        # config after already changing the user's preferences.
        snapshot(proposed=overlay)
        document = {"version": 1, "values": overlay}
        temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
        try:
            temporary.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    return snapshot()


def main(argv=None) -> int:
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Local non-secret settings bridge")
    parser.add_argument("--apply", action="store_true", help="Read changes and revision as JSON from stdin")
    args = parser.parse_args(argv)
    try:
        if args.apply:
            request = json.loads(sys.stdin.read(16385))
            if not isinstance(request, dict) or set(request) != {"changes", "revision"}:
                raise PreferenceError("invalid_request")
            result = save(request["changes"], request["revision"])
        else:
            result = snapshot()
        print(json.dumps({"status": "ok", **result}, ensure_ascii=False))
        return 0
    except (ValueError, OSError, TypeError, KeyError) as exc:
        code = str(exc) if isinstance(exc, PreferenceError) else "settings_unavailable"
        print(json.dumps({"status": "error", "code": code}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
