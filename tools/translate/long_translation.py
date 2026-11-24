"""Bounded paragraph/UTF-8 segmentation and request-local retry checkpoints.

Checkpoints contain translated segments (like the existing translation cache),
never credentials, source text or errors. The panel owns their lifetime.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import uuid

MAX_TOTAL_CHARS = 20000
MAX_SEGMENTS = 200
MAX_CHECKPOINT_BYTES = 2 * 1024 * 1024
MAX_OUTPUT_CHARS = 200000
TASK_BUDGET_SECONDS = 120


def split_segments(text: str, *, max_chars: int, max_bytes: int) -> list[str]:
    """Lossless split, prefer paragraphs, sentence boundaries, then word spaces.

    Each piece, including separators, fits both limits. Python code points are
    never cut in the middle of a UTF-8 encoding.
    """
    if max_chars < 1 or max_bytes < 4:
        raise ValueError("invalid_segment_budget")
    pieces = []
    remaining = text
    while remaining:
        size = 0
        end = 0
        for char in remaining[:max_chars]:
            width = len(char.encode("utf-8"))
            if size + width > max_bytes:
                break
            size += width
            end += 1
        if end < len(remaining):
            prefix = remaining[:end]
            # Don't turn a large paragraph into lots of tiny fragments.
            minimum = max(1, end // 3)
            paragraph = [match.end() for match in re.finditer(r"\r?\n", prefix) if match.end() >= minimum]
            sentence = [match.end() for match in re.finditer(r"[。！？.!?](?:\s+|$)", prefix) if match.end() >= minimum]
            space = [match.end() for match in re.finditer(r"\s+", prefix) if match.end() >= minimum]
            boundaries = paragraph or sentence or space
            if boundaries:
                end = boundaries[-1]
        if end == 0:
            raise ValueError("invalid_segment_budget")
        pieces.append(remaining[:end])
        remaining = remaining[end:]
    return pieces


def checkpoint_key(text: str, direction: str, engine: str, scope: dict, segments: list[str]) -> str:
    payload = json.dumps([text, direction, engine, scope, [len(part) for part in segments]],
                         ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def load_checkpoint(path: str, key: str, count: int) -> list[dict | None]:
    empty = [None] * count
    if not path:
        return empty
    try:
        with Path(path).open("rb") as handle:
            raw = handle.read(MAX_CHECKPOINT_BYTES + 1)
        if len(raw) > MAX_CHECKPOINT_BYTES:
            return empty
        doc = json.loads(raw)
        if (doc["version"] != 1 or doc["key"] != key or not isinstance(doc["results"], list)
                or len(doc["results"]) != count):
            return empty
        results = doc["results"]
        total_chars = 0
        for result in results:
            if result is None:
                continue
            if (not isinstance(result, dict) or set(result) != {"text", "engine", "cached", "fallback_reason"}
                    or not isinstance(result["text"], str)
                    or (not result["text"].strip() and result.get("engine") != "identity")
                    or len(result["text"]) > 100000
                    or result["engine"] not in {"tencent", "aliyun", "google_gtx", "mymemory", "identity"}
                    or not isinstance(result["cached"], bool)
                    or result["fallback_reason"] not in {"", "credentials", "auth", "network", "timeout", "too_long"}):
                return empty
            total_chars += len(result["text"])
            if total_chars > MAX_OUTPUT_CHARS:
                return empty
        return results
    except (OSError, ValueError, TypeError, KeyError):
        return empty


def save_checkpoint(path: str, key: str, results: list[dict | None]) -> None:
    if not path:
        return
    target = Path(path)
    temporary = target.with_name(target.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        raw = json.dumps({"version": 1, "key": key, "results": results}, ensure_ascii=False)
        if len(raw.encode("utf-8")) > MAX_CHECKPOINT_BYTES:
            return
        temporary.write_text(raw, encoding="utf-8")
        os.replace(temporary, target)
    except OSError:
        pass  # Translation succeeds even if request-local retry storage fails.
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def join_results(segments: list[str], results: list[dict | None], *, hard_separator: str = "") -> str:
    parts = []
    for index, (source, result) in enumerate(zip(segments, results)):
        if index and hard_separator and not segments[index - 1][-1:].isspace() and not source[:1].isspace():
            parts.append(hard_separator)
        if not source.strip():
            parts.append(source)
            continue
        if result is None:
            parts.append(f"【第 {index + 1} 段翻译失败，重试后补全】")
        else:
            # Providers usually strip whitespace. Reattach exact separators so
            # paragraph boundaries, line endings and split word spaces survive.
            leading = source[:len(source) - len(source.lstrip())]
            trailing = source[len(source.rstrip()):]
            parts.append(leading + result["text"].strip() + trailing)
    return "".join(parts)
