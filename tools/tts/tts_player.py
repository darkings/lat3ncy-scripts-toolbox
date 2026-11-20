#!/usr/bin/env python3
"""Lat3ncy TTS Player & Language Segmenter.

获取输入文本，按中英文语境智能切片，通过 WinRT 本地 OneCore 引擎或 Edge Neural TTS 并发流水线合成并即时播放。
支持全并发请求、流水线即时播放（首段就绪即播）、SHA256 多维缓存、LRU 容量管理与 Windows SAPI 本地兜底。

日志默认只记录元数据（字符数、切片数、语言分布、音色、耗时、缓存命中、退出状态、错误类型等），
不记录原文或片段；只有显式配置 ``log_text = true`` 时才允许写入文本。日志文件以追加模式写入，
并按固定上限轮转（1 MiB x 2 个备份），避免日志无限增长。
"""

import argparse
import asyncio
import ctypes
import hashlib
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid
from logging.handlers import RotatingFileHandler
from typing import Any
from task_protocol import RequestState, TaskFailure

_TASK: RequestState | None = None
SYNTHESIS_TIMEOUT_SECONDS = 30.0
TASK_TIMEOUT_SECONDS = 1800.0

ZH_CHAR_PATTERN = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff]")
ZH_PUNCT_PATTERN = re.compile(r"[\u3000-\u303f\uff01-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65]")
EN_CHAR_PATTERN = re.compile(r"[A-Za-z]")
HAS_WORD_CHAR = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaffA-Za-z0-9]")

LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tts.log")
LOG_MAX_BYTES = 1024 * 1024
LOG_BACKUP_COUNT = 2
LOG_MESSAGE_LIMIT = 300
REDACTED_TEXT = "<text>"

_DEFAULT_LOG_PATH: str | None = None
_LOG_TEXT_ENABLED = False
_REDACTION_TEXT: str | None = None
_REDACTION_SEGMENTS: list[Any] = []


def _logger_name_for(log_path: str) -> str:
    """默认日志沿用固定名称；其它路径用内容无关的短哈希，避免多个测试日志串台。"""
    normalized = os.path.normcase(os.path.abspath(log_path))
    if normalized == os.path.normcase(os.path.abspath(LOG_FILE)):
        return "lat3ncy_tts"
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12]
    return f"lat3ncy_tts.{digest}"


def build_logger(log_path: str | None = None, *, stream: Any = None) -> logging.Logger:
    """为指定日志路径构建独立 logger（同一路径复用同一实例）。

    默认追加写入 + 有界轮转；同时保留 stdout 输出。测试可传入 ``stream``
    把控制台副本重定向到 StringIO，避免污染测试输出。
    """
    path = log_path or LOG_FILE
    logger = logging.getLogger(_logger_name_for(path))
    logger.setLevel(logging.DEBUG)
    logger.propagate = False
    if not logger.handlers:
        formatter = logging.Formatter(
            "[%(asctime)s] [Python/%(levelname)s] %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
        try:
            fh = RotatingFileHandler(
                path,
                mode="a",
                maxBytes=LOG_MAX_BYTES,
                backupCount=LOG_BACKUP_COUNT,
                encoding="utf-8",
            )
            fh.setFormatter(formatter)
            logger.addHandler(fh)
        except Exception:
            pass

        ch = logging.StreamHandler(sys.stdout if stream is None else stream)
        ch.setFormatter(formatter)
        logger.addHandler(ch)
    return logger


def get_logger(log_path: str | None = None) -> logging.Logger:
    return build_logger(log_path or _DEFAULT_LOG_PATH or LOG_FILE)


def configure_logging(log_path: str, *, log_text: bool = False) -> logging.Logger:
    """切换默认日志路径与文本开关（自检/测试用，避免写仓库内的 tts.log）。"""
    global _DEFAULT_LOG_PATH, _LOG_TEXT_ENABLED
    _DEFAULT_LOG_PATH = log_path
    _LOG_TEXT_ENABLED = bool(log_text)
    return get_logger()


def set_log_text_enabled(enabled: bool) -> None:
    global _LOG_TEXT_ENABLED
    _LOG_TEXT_ENABLED = bool(enabled)


def get_log_text_enabled() -> bool:
    return _LOG_TEXT_ENABLED


def close_logger(logger: logging.Logger) -> None:
    """关闭并移除 handler（Windows 下清理临时日志目录前必须调用）。"""
    for handler in list(logger.handlers):
        try:
            handler.flush()
        except Exception:
            pass
        try:
            handler.close()
        except Exception:
            pass
        logger.removeHandler(handler)


def _segment_text(segment: Any) -> str:
    if isinstance(segment, (tuple, list)) and len(segment) >= 2:
        return str(segment[1])
    return str(segment)


def set_redaction_context(text: str | None, segments: Any = None) -> None:
    """登记当前待朗读文本，供后续错误日志兜底脱敏（只驻留内存，不写日志）。"""
    global _REDACTION_TEXT, _REDACTION_SEGMENTS
    _REDACTION_TEXT = text
    _REDACTION_SEGMENTS = list(segments) if segments else []


def clear_redaction_context() -> None:
    set_redaction_context(None, None)


def sanitize_message(
    message: object,
    text: str | None = None,
    segments: Any = None,
) -> str:
    """把错误消息中的原文/片段替换为占位符，并压成单行、截断。

    默认日志只允许出现异常类型 + 这条脱敏后的消息，避免底层库把待朗读文本
    拼进异常消息后泄漏到 tts.log。
    """
    raw = str(message)
    candidates: set[str] = set()
    if text:
        candidates.add(text)
        candidates.add(text.strip())
        candidates.add(repr(text))
    for segment in segments or []:
        seg_text = _segment_text(segment)
        if seg_text:
            candidates.add(seg_text)
            candidates.add(seg_text.strip())
            candidates.add(repr(seg_text))
    # 先替换长串，避免整段原文被其内部短片段提前切碎后残留。
    for candidate in sorted((c for c in candidates if c), key=len, reverse=True):
        raw = raw.replace(candidate, REDACTED_TEXT)
    raw = " ".join(raw.split())
    if len(raw) > LOG_MESSAGE_LIMIT:
        raw = raw[:LOG_MESSAGE_LIMIT] + "...(truncated)"
    return raw


def log_startup_summary(
    logger: logging.Logger,
    text: str,
    segments: list[tuple[str, str]],
    *,
    engine: str,
    zh_voice: str,
    en_voice: str,
    concurrency: int,
    log_text: bool = False,
) -> None:
    """启动摘要：默认只写字符/切片/语言分布/引擎/音色/并发数。"""
    zh_count = sum(1 for lang, _ in segments if lang == "zh")
    en_count = len(segments) - zh_count
    if log_text:
        logger.info(
            "TTS 启动摘要: 字符数=%d，切片数=%d（中=%d，英=%d），引擎=%s，中文音色=%s，英文音色=%s，并发=%d，文本=%r",
            len(text),
            len(segments),
            zh_count,
            en_count,
            engine,
            zh_voice,
            en_voice,
            concurrency,
            text,
        )
    else:
        logger.info(
            "TTS 启动摘要: 字符数=%d，切片数=%d（中=%d，英=%d），引擎=%s，中文音色=%s，英文音色=%s，并发=%d",
            len(text),
            len(segments),
            zh_count,
            en_count,
            engine,
            zh_voice,
            en_voice,
            concurrency,
        )


_SEGMENT_STATUS_LABELS = {
    "cache_hit": "缓存命中",
    "synthesized": "合成完成",
    "failed": "合成失败",
    "exception": "合成异常",
}


def log_segment_result(
    logger: logging.Logger,
    idx: int,
    lang: str,
    status: str,
    *,
    text: str = "",
    voice: str = "",
    duration_ms: float | None = None,
    log_text: bool = False,
) -> None:
    """单个切片结果：状态（缓存命中/合成/失败）、音色、字符数、耗时。"""
    label = _SEGMENT_STATUS_LABELS.get(status, status)
    timing = f"，耗时={duration_ms:.1f}ms" if duration_ms is not None else ""
    level = logging.ERROR if status in ("failed", "exception") else logging.INFO
    if log_text:
        logger.log(
            level,
            "片段 #%d [%s] %s: 音色=%s，字符数=%d%s，文本=%r",
            idx + 1,
            lang,
            label,
            voice or "-",
            len(text),
            timing,
            text,
        )
    else:
        logger.log(
            level,
            "片段 #%d [%s] %s: 音色=%s，字符数=%d%s",
            idx + 1,
            lang,
            label,
            voice or "-",
            len(text),
            timing,
        )


def log_error(
    logger: logging.Logger,
    context: str,
    error: BaseException,
    *,
    text: str | None = None,
    segments: Any = None,
    log_text: bool = False,
    include_message: bool = True,
) -> None:
    """记录错误类型与脱敏消息；log_text=true 时才保留完整消息。"""
    error_type = type(error).__name__
    if log_text:
        logger.error("%s: %s: %s", context, error_type, error)
    elif include_message:
        # 除调用方显式传入的文本外，再加上 main 登记的完整原文/切片，
        # 防止底层异常消息里夹带的其它片段漏网。
        redaction_segments: list[Any] = list(_REDACTION_SEGMENTS)
        if _REDACTION_TEXT:
            redaction_segments.append(("_", _REDACTION_TEXT))
        if text:
            redaction_segments.append(("_", text))
        if segments:
            redaction_segments.extend(segments)
        logger.error(
            "%s: %s: %s",
            context,
            error_type,
            sanitize_message(error, segments=redaction_segments),
        )
    else:
        logger.error("%s: %s", context, error_type)


def get_default_cache_dir() -> str:
    local_app_data = os.environ.get(
        "LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local")
    )
    candidates = [os.path.join(local_app_data, "lat3ncy-toolbox", "tts-cache"),
                  os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")]
    for cache_dir in candidates:
        probe = os.path.join(cache_dir, ".write-probe-" + uuid.uuid4().hex)
        try:
            os.makedirs(cache_dir, exist_ok=True)
            with open(probe, "xb") as output:
                output.write(b"probe")
            os.remove(probe)
            return cache_dir
        except OSError:
            continue
    raise PermissionError("No writable TTS cache directory")


def _clamp_int(value: object, default: int, lo: int, hi: int, name: str) -> int:
    """非法值只 warning + 夹紧，不让配置错误把朗读进程打崩。"""
    try:
        parsed = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        get_logger().warning(f"配置 {name}={value!r} 无效，回退 {default}")
        return default
    if parsed < lo or parsed > hi:
        clamped = max(lo, min(hi, parsed))
        get_logger().warning(f"配置 {name}={parsed} 超出 {lo}..{hi}，夹紧为 {clamped}")
        return clamped
    return parsed


def load_config(config_path: str | None = None) -> dict:
    default_config = {
        "engine": "auto",
        "zh_voice": "Microsoft Yaoyao",
        "en_voice": "Microsoft Zira",
        "rate": "+0%",
        "pitch": "+0Hz",
        "volume": "+0%",
        "concurrency": 2,
        "log_text": False,
        "cache": {
            "max_size_mb": 100,
            "max_files": 2000,
        },
    }

    if config_path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        config_path = os.path.join(script_dir, "config.toml")

    if os.path.isfile(config_path):
        try:
            with open(config_path, "rb") as f:
                loaded = tomllib.load(f)
            if isinstance(loaded, dict):
                cache = dict(default_config["cache"])
                default_config.update(loaded)
                if isinstance(default_config.get("cache"), dict):
                    cache.update(default_config["cache"])
                default_config["cache"] = cache
        except Exception as e:
            log_error(get_logger(), "加载配置文件失败，使用默认配置", e)

    default_config["concurrency"] = _clamp_int(
        default_config.get("concurrency", 2), 2, 1, 10, "concurrency"
    )
    cache_cfg = default_config.get("cache", {})
    if not isinstance(cache_cfg, dict):
        cache_cfg = {"max_size_mb": 100, "max_files": 2000}
    cache_cfg["max_size_mb"] = _clamp_int(
        cache_cfg.get("max_size_mb", 100), 100, 1, 10240, "cache.max_size_mb"
    )
    cache_cfg["max_files"] = _clamp_int(
        cache_cfg.get("max_files", 2000), 2000, 1, 100000, "cache.max_files"
    )
    default_config["cache"] = cache_cfg

    log_text_value = default_config.get("log_text", False)
    if not isinstance(log_text_value, bool):
        get_logger().warning(
            "配置 log_text=%r 不是布尔值，按 false 处理", log_text_value
        )
        log_text_value = False
    default_config["log_text"] = log_text_value
    return default_config


def split_by_language(text: str) -> list[tuple[str, str]]:
    """将文本切分为中英文片段，数字、空格与标点根据前后文智能归属。"""
    text = text.strip()
    if not text:
        return []

    raw_segments: list[tuple[str, str]] = []
    current_lang: str | None = None
    current_text = ""

    for char in text:
        if ZH_CHAR_PATTERN.match(char) or ZH_PUNCT_PATTERN.match(char):
            char_lang = "zh"
        elif EN_CHAR_PATTERN.match(char):
            char_lang = "en"
        else:
            char_lang = None

        if char_lang is not None:
            if current_lang is None:
                current_lang = char_lang
                current_text += char
            elif char_lang == current_lang:
                current_text += char
            else:
                if current_text:
                    raw_segments.append((current_lang, current_text))
                current_lang = char_lang
                current_text = char
        else:
            current_text += char

    if current_text:
        raw_segments.append((current_lang or "en", current_text))

    merged: list[tuple[str, str]] = []
    for lang, seg_text in raw_segments:
        if not HAS_WORD_CHAR.search(seg_text):
            if merged:
                prev_lang, prev_text = merged[-1]
                merged[-1] = (prev_lang, prev_text + seg_text)
            else:
                merged.append((lang, seg_text))
        else:
            if merged and not HAS_WORD_CHAR.search(merged[-1][1]):
                p_lang, p_text = merged.pop()
                merged.append((lang, p_text + seg_text))
            else:
                merged.append((lang, seg_text))

    final_segments: list[tuple[str, str]] = []
    for lang, seg_text in merged:
        cleaned = seg_text.strip()
        if cleaned and HAS_WORD_CHAR.search(cleaned):
            final_segments.append((lang, cleaned))

    return final_segments


def unique_temp_path(cache_path: str, ext: str) -> str:
    """为一次合成分配唯一的临时文件名。

    同一进程内重复片段（例如 "Hello 世界 Hello" 里的两个 en:"Hello"）会并发写同一个
    cache_path；只用 pid 命名时两个写者互相截断，先完成的那个 shutil.move 还会抛
    FileNotFoundError，残片则被后续的"文件非空"校验当成缓存命中。
    """
    if _TASK and _TASK.request_id:
        return os.path.join(os.path.dirname(cache_path), f".tts-tmp.{_TASK.request_id}.{os.urandom(8).hex()}{ext}")
    return f"{cache_path}.tmp.{os.getpid()}.{os.urandom(8).hex()}{ext}"


def compute_cache_key(text: str, voice: str, rate: str, pitch: str, volume: str) -> str:
    payload = f"{text}\n{voice}\n{rate}\n{pitch}\n{volume}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def synthesis_target(engine: str, voice: str, lang: str) -> tuple[str, str]:
    neural = "zh-CN-XiaoxiaoNeural" if lang == "zh" else "en-US-AriaNeural"
    if engine == "winrt":
        return "winrt", voice
    if engine == "edge":
        return "edge", voice if "Neural" in voice else neural
    return ("winrt", voice) if "Neural" not in voice else ("edge", voice)


def prune_lru_cache(cache_dir: str, max_size_mb: int, max_files: int) -> None:
    """按最后访问时间 (atime) 清理超额缓存文件。"""
    logger = get_logger()
    try:
        entries = []
        total_bytes = 0
        for entry in os.scandir(cache_dir):
            if entry.is_file() and (entry.name.endswith(".mp3") or entry.name.endswith(".wav")):
                stat = entry.stat()
                total_bytes += stat.st_size
                entries.append((stat.st_atime, stat.st_size, entry.path))

        max_bytes = max_size_mb * 1024 * 1024
        if total_bytes <= max_bytes and len(entries) <= max_files:
            return

        entries.sort(key=lambda x: x[0])
        target_bytes = int(max_bytes * 0.85)
        target_files = int(max_files * 0.85)

        deleted = 0
        remaining = len(entries)
        for _, size, path in entries:
            if total_bytes <= target_bytes and remaining <= target_files:
                break
            try:
                os.remove(path)
                total_bytes -= size
                remaining -= 1
                deleted += 1
            except OSError:
                pass
        if deleted > 0:
            logger.info(f"LRU 缓存清理: 移除了 {deleted} 个过期缓存文件")
    except Exception as e:
        log_error(logger, "LRU 缓存清理异常", e)


async def synthesize_winrt_segment(
    voice_name: str,
    seg_text: str,
    cache_path: str,
    *,
    log_text: bool = False,
) -> bool:
    """使用 WinRT 本地离线合成语音 (零网络延迟)。"""
    logger = get_logger()
    try:
        try:
            import winrt.windows.media.speechsynthesis as ss
            import winrt.windows.storage.streams as streams
        except ImportError:
            # Keep existing Python 3.11/3.12 winsdk installations working.
            import winsdk.windows.media.speechsynthesis as ss
            import winsdk.windows.storage.streams as streams

        synth = ss.SpeechSynthesizer()
        voices = ss.SpeechSynthesizer.all_voices
        # all_voices 在类型桩里可为 None；保持旧行为：拿不到列表就失败，交给 SAPI 兜底。
        if voices is None:
            logger.error("WinRT 语音列表不可用")
            return False
        target_voice = None
        for v in voices:
            if voice_name.lower() in v.display_name.lower() or voice_name.lower() in v.id.lower():
                target_voice = v
                break
        if target_voice:
            synth.voice = target_voice
        else:
            current_voice = synth.voice
            current_name = current_voice.display_name if current_voice is not None else "default"
            logger.warning(
                "未找到指定的 WinRT 语音 '%s'，使用默认语音: %s", voice_name, current_name
            )

        stream = await synth.synthesize_text_to_stream_async(seg_text)
        reader = streams.DataReader(stream.get_input_stream_at(0))
        await reader.load_async(stream.size)
        # winsdk 类型桩要求 Array[UInt8]，运行时 bytearray 可用；用 Any 避免改播放路径。
        buf: Any = bytearray(stream.size)
        reader.read_bytes(buf)

        # 临时名必须唯一：同一个进程里重复片段（"Hello 世界 Hello"）会并发写同一个
        # cache_path，只用 pid 命名时两个写者互相截断，残片还会被当成缓存命中。
        temp_file = unique_temp_path(cache_path, ".wav")
        try:
            with open(temp_file, "wb") as f:
                f.write(buf)
            if os.path.exists(cache_path):
                os.remove(cache_path)
            shutil.move(temp_file, cache_path)
        finally:
            if os.path.exists(temp_file):
                try:
                    os.remove(temp_file)
                except OSError:
                    pass
        return True
    except Exception as e:
        log_error(logger, "WinRT 本地合成异常", e, text=seg_text, log_text=log_text)
        return False


async def synthesize_edge_segment(
    voice: str,
    seg_text: str,
    rate: str,
    pitch: str,
    volume: str,
    cache_path: str,
    *,
    log_text: bool = False,
) -> bool:
    """使用 Edge 在线 Neural TTS 合成语音。"""
    logger = get_logger()
    try:
        import edge_tts

        communicate = edge_tts.Communicate(
            seg_text, voice=voice, rate=rate, pitch=pitch, volume=volume
        )
        temp_file = unique_temp_path(cache_path, ".mp3")
        try:
            await communicate.save(temp_file)
            if os.path.isfile(temp_file) and os.path.getsize(temp_file) > 0:
                if os.path.exists(cache_path):
                    os.remove(cache_path)
                shutil.move(temp_file, cache_path)
                return True
            return False
        finally:
            # 失败/0 字节的残片必须删掉：prune_lru_cache 只统计 .mp3/.wav，
            # 看不见 .tmp.* 文件，留着就是无界增长。
            if os.path.exists(temp_file):
                try:
                    os.remove(temp_file)
                except OSError:
                    pass
    except Exception as e:
        log_error(logger, "Edge TTS 合成异常", e, text=seg_text, log_text=log_text)
        return False


async def synthesize_one_segment(
    idx: int,
    lang: str,
    seg_text: str,
    voice: str,
    rate: str,
    pitch: str,
    volume: str,
    cache_path: str,
    engine: str,
    ready_events: list[asyncio.Event],
    result_files: list[str | None],
    semaphore: asyncio.Semaphore | None = None,
    *,
    log_text: bool = False,
    timeout_seconds: float = SYNTHESIS_TIMEOUT_SECONDS,
    errors: list[str | None] | None = None,
) -> None:
    logger = get_logger()
    started = time.perf_counter()

    async def _do_synthesize():
        if os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0:
            try:
                os.utime(cache_path, None)
            except OSError:
                pass
            result_files[idx] = cache_path
            log_segment_result(
                logger,
                idx,
                lang,
                "cache_hit",
                text=seg_text,
                voice=voice,
                duration_ms=(time.perf_counter() - started) * 1000,
                log_text=log_text,
            )
            return

        backend, used_voice = synthesis_target(engine, voice, lang)
        is_winrt = backend == "winrt"
        resolved_path = cache_path

        engine_label = "本地 WinRT" if is_winrt else "Edge 云端"
        logger.info(
            "片段 #%d [%s] 开始合成: 缓存=未命中，引擎=%s，音色=%s，字符数=%d",
            idx + 1,
            lang,
            engine_label,
            voice,
            len(seg_text),
        )
        if is_winrt:
            ok = await synthesize_winrt_segment(
                used_voice, seg_text, cache_path, log_text=log_text
            )
        else:
            ok = await synthesize_edge_segment(
                used_voice, seg_text, rate, pitch, volume, cache_path, log_text=log_text
            )

        # auto explicitly permits online fallback. An explicit winrt request
        # remains local-only. Never store MP3 bytes under the local WAV key.
        if not ok and is_winrt and engine == "auto":
            _, used_voice = synthesis_target("edge", "", lang)
            key = compute_cache_key(seg_text, used_voice, rate, pitch, volume)
            resolved_path = os.path.join(os.path.dirname(cache_path), key + ".mp3")
            logger.warning("片段 #%d 本地合成失败，回退 Edge，音色=%s", idx + 1, used_voice)
            if os.path.isfile(resolved_path) and os.path.getsize(resolved_path) > 0:
                ok = True
            else:
                ok = await synthesize_edge_segment(used_voice, seg_text, rate, pitch, volume, resolved_path, log_text=log_text)

        duration_ms = (time.perf_counter() - started) * 1000
        if ok and os.path.isfile(resolved_path) and os.path.getsize(resolved_path) > 0:
            result_files[idx] = resolved_path
            log_segment_result(
                logger,
                idx,
                lang,
                "synthesized",
                text=seg_text,
                voice=used_voice,
                duration_ms=duration_ms,
                log_text=log_text,
            )
        else:
            if errors is not None:
                errors[idx] = 'synthesis'
            log_segment_result(
                logger,
                idx,
                lang,
                "failed",
                text=seg_text,
                voice=voice,
                duration_ms=duration_ms,
                log_text=log_text,
            )

    try:
        if semaphore is not None:
            async with semaphore:
                await asyncio.wait_for(_do_synthesize(), timeout_seconds)
        else:
            await asyncio.wait_for(_do_synthesize(), timeout_seconds)
    except TimeoutError:
        if errors is not None:
            errors[idx] = 'timeout'
        logger.error('片段 #%d 合成超时', idx + 1)
    except Exception as e:
        if errors is not None:
            errors[idx] = 'synthesis'
        log_error(
            logger,
            f"片段 #{idx + 1} [{lang}] 合成发生异常",
            e,
            text=seg_text,
            log_text=log_text,
        )
    finally:
        ready_events[idx].set()


def play_sapi_fallback(text: str, *, log_text: bool = False) -> bool:
    """当所有合成不可用时使用 Windows PowerShell 本地 SAPI 兜底朗读。"""
    logger = get_logger()
    if log_text:
        logger.info("启用 Windows SAPI 本地朗读: 字符数=%d，文本=%r", len(text), text)
    else:
        logger.info("启用 Windows SAPI 本地朗读: 字符数=%d", len(text))
    try:
        safe_text = text.replace("'", "''")
        cmd = [
            os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
            "-NoProfile",
            "-Command",
            f"Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak('{safe_text}')",
        ]
        environment = os.environ.copy()
        environment["PSMODULEPATH"] = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "Modules")
        result = subprocess.run(
            cmd,
            env=environment,
            capture_output=True,
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
            timeout=10,
        )
        if result.returncode != 0:
            logger.error("Windows SAPI 朗读失败，退出码=%d", result.returncode)
        return result.returncode == 0
    except Exception as e:
        log_error(logger, "Windows SAPI 朗读异常", e, text=text, log_text=log_text, include_message=False)
        return False


def play_audio_file(file_path: str) -> bool:
    """使用 Windows MCI 播放 MP3 / WAV 音频文件。"""
    logger = get_logger()
    if sys.platform != "win32":
        return False

    winmm = ctypes.windll.winmm
    alias = f"lat3ncy_tts_{os.getpid()}"
    full_path = os.path.abspath(file_path)

    winmm.mciSendStringW(f"close {alias}", None, 0, None)

    # 自动识别类型
    file_type = "type mpegvideo" if full_path.lower().endswith(".mp3") else ""
    open_cmd = f'open "{full_path}" {file_type} alias {alias}'.strip()
    err = winmm.mciSendStringW(open_cmd, None, 0, None)
    if err != 0:
        logger.error(
            "MCI open 失败, error code: %s, file: %s",
            err,
            os.path.basename(full_path),
        )
        return False

    try:
        logger.debug(f"播放片段音频 (MCI): {os.path.basename(full_path)}")
        play_err = winmm.mciSendStringW(f"play {alias} wait", None, 0, None)
        if play_err != 0:
            logger.error(f"MCI play 失败, error code: {play_err}")
        return play_err == 0
    finally:
        winmm.mciSendStringW(f"close {alias}", None, 0, None)


async def main_async() -> None:
    global _TASK
    logger = get_logger()
    logger.info("=== TTS Player 启动 ===")

    parser = argparse.ArgumentParser(description="Lat3ncy TTS Player")
    parser.add_argument("--text", type=str, default="", help="要朗读的文本")
    parser.add_argument("--input-file", type=str, default="", help="包含要朗读文本的文件路径")
    parser.add_argument("--config", type=str, default=None, help="配置文件路径")
    parser.add_argument('--request-id', default='')
    parser.add_argument('--result-file', default='')
    parser.add_argument('--synthesis-timeout', type=float, default=SYNTHESIS_TIMEOUT_SECONDS)
    parser.add_argument('--task-timeout', type=float, default=TASK_TIMEOUT_SECONDS)
    args = parser.parse_args()
    _TASK = RequestState(args.request_id, args.result_file)
    if not 0.05 <= args.synthesis_timeout <= 120 or not 0.05 <= args.task_timeout <= 7200:
        raise TaskFailure('input', 'Invalid TTS time budget')
    await asyncio.wait_for(run_pipeline(args), args.task_timeout)


async def run_pipeline(args) -> None:
    logger = get_logger()

    input_text = args.text
    if args.input_file:
        try:
            with open(args.input_file, "r", encoding="utf-8") as f:
                input_text = f.read()
        except Exception as e:
            log_error(logger, "读取输入文件失败", e)
            raise TaskFailure('input', 'TTS input is unavailable') from e

    input_text = input_text.strip()
    if not input_text:
        clear_redaction_context()
        logger.info("=== 输入为空，退出 ===")
        if _TASK and _TASK.request_id:
            raise TaskFailure('input', 'TTS input is empty')
        return

    config = load_config(args.config)
    log_text = bool(config.get("log_text", False))
    set_log_text_enabled(log_text)

    engine = config.get("engine", "auto")
    zh_voice = config.get("zh_voice", "Microsoft Yaoyao")
    en_voice = config.get("en_voice", "Microsoft Zira")
    rate = config.get("rate", "+0%")
    pitch = config.get("pitch", "+0Hz")
    volume = config.get("volume", "+0%")
    cache_settings = config.get("cache", {})
    max_size_mb = cache_settings.get("max_size_mb", 100)
    max_files = cache_settings.get("max_files", 2000)

    cache_dir = get_default_cache_dir()
    segments = split_by_language(input_text)
    if not segments:
        clear_redaction_context()
        logger.info("=== 无可朗读切片，退出 ===")
        return

    set_redaction_context(input_text, segments)

    concurrency = int(config.get("concurrency", 2))
    concurrency = max(1, min(concurrency, 10))
    semaphore = asyncio.Semaphore(concurrency)

    logger.info(
        "运行配置: 引擎=%s，并发=%d，log_text=%s", engine, concurrency, log_text
    )
    log_startup_summary(
        logger,
        input_text,
        segments,
        engine=engine,
        zh_voice=zh_voice,
        en_voice=en_voice,
        concurrency=concurrency,
        log_text=log_text,
    )

    ready_events = [asyncio.Event() for _ in segments]
    result_files: list[str | None] = [None] * len(segments)
    errors: list[str | None] = [None] * len(segments)

    # 1. 启动受控并发合成 Task (并发上限={concurrency})
    tasks = []
    for idx, (lang, seg_text) in enumerate(segments):
        voice = zh_voice if lang == "zh" else en_voice
        backend, voice = synthesis_target(engine, voice, lang)
        ext = ".wav" if backend == "winrt" else ".mp3"
        key = compute_cache_key(seg_text, voice, rate, pitch, volume)
        cache_path = os.path.join(cache_dir, f"{key}{ext}")
        tasks.append(
            asyncio.create_task(
                synthesize_one_segment(
                    idx,
                    lang,
                    seg_text,
                    voice,
                    rate,
                    pitch,
                    volume,
                    cache_path,
                    engine,
                    ready_events,
                    result_files,
                    semaphore,
                    log_text=log_text,
                    timeout_seconds=args.synthesis_timeout,
                    errors=errors,
                )
            )
        )

    try:
        await play_pipeline(segments, ready_events, result_files, errors, args.synthesis_timeout, log_text)
        await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        prune_lru_cache(cache_dir, max_size_mb, max_files)


async def play_pipeline(segments, ready_events, result_files, errors, synthesis_timeout, log_text):
    logger = get_logger()
    played_count = 0
    fallback_count = 0
    failures = []
    for idx in range(len(segments)):
        if _TASK:
            _TASK.stage = 'waiting'
        await asyncio.wait_for(ready_events[idx].wait(), synthesis_timeout * (idx + 1) + 5)
        if _TASK:
            _TASK.stage = 'playback'
        audio_path = result_files[idx]
        played = False
        if audio_path and os.path.isfile(audio_path):
            # MCI play ... wait 会堵住事件循环；丢到线程里，合成任务才能继续排队。
            # 仍按片段下标顺序 await，音频不会乱序。
            played = await asyncio.to_thread(play_audio_file, audio_path)
        if played:
            played_count += 1
        else:
            lang, seg_text = segments[idx]
            if await asyncio.to_thread(play_sapi_fallback, seg_text, log_text=log_text):
                fallback_count += 1
            else:
                failures.append(errors[idx] or ('playback' if audio_path else 'synthesis'))

    if failures:
        kind = 'timeout' if 'timeout' in failures else ('playback' if 'playback' in failures else 'synthesis')
        raise TaskFailure(kind, f"TTS playback failed for {len(failures)} segment(s)")

    logger.info(
        "=== TTS Player 播放完成退出: 状态=success，切片=%d，音频播放=%d，SAPI 兜底=%d ===",
        len(segments),
        played_count,
        fallback_count,
    )


def _create_temp_dir(prefix: str) -> str:
    """创建可写临时目录。

    不用 ``tempfile.mkdtemp``：Windows 受限环境（如沙箱/低权限令牌）下它会把
    目录 ACL 收紧到仅属主可写，后续写日志/缓存会被拒绝。这里用唯一名称 +
    ``os.makedirs`` 继承系统 TEMP 的 ACL，供自检使用；目录由调用方清理。
    """
    base = tempfile.gettempdir()
    for _ in range(10):
        path = os.path.join(base, f"{prefix}{uuid.uuid4().hex}")
        try:
            os.makedirs(path)
            return path
        except FileExistsError:
            continue
    raise RuntimeError(f"无法创建临时目录: {base}")


def run_self_test() -> int:
    """纯函数/文件系统单测：不合成、不播放、不写仓库日志。"""
    global _DEFAULT_LOG_PATH, _LOG_TEXT_ENABLED
    failed = 0
    previous_log_path = _DEFAULT_LOG_PATH
    previous_log_text = _LOG_TEXT_ENABLED
    self_test_log_dir = _create_temp_dir("lat3ncy-tts-selftest-log-")
    self_test_logger = configure_logging(
        os.path.join(self_test_log_dir, "tts.log"), log_text=False
    )

    def check(cond: bool, name: str) -> None:
        nonlocal failed
        if not cond:
            print(f"FAIL {name}", file=sys.stderr)
            failed += 1

    try:
        cfg = load_config(os.path.join(tempfile.gettempdir(), "lat3ncy-missing-tts.toml"))
        check(cfg["zh_voice"] == "Microsoft Yaoyao", "default zh_voice")
        check(cfg["en_voice"] == "Microsoft Zira", "default en_voice")
        check(1 <= int(cfg["concurrency"]) <= 10, "default concurrency range")
        check(cfg["log_text"] is False, "default log_text false")

        tmp = _create_temp_dir("lat3ncy-tts-selftest-data-")
        try:
            bad = os.path.join(tmp, "bad.toml")
            with open(bad, "w", encoding="utf-8") as handle:
                handle.write("concurrency = 99\n[cache]\nmax_size_mb = 0\nmax_files = -3\n")
            loaded = load_config(bad)
            check(loaded["concurrency"] == 10, "concurrency clamp high")
            check(loaded["cache"]["max_size_mb"] == 1, "max_size_mb clamp low")
            check(loaded["cache"]["max_files"] == 1, "max_files clamp low")
            check(loaded["log_text"] is False, "bad config log_text false")

            cache_dir = os.path.join(tmp, "cache")
            os.makedirs(cache_dir, exist_ok=True)
            for i in range(5):
                path = os.path.join(cache_dir, f"{i}.wav")
                with open(path, "wb") as handle:
                    handle.write(b"x" * 100)
                os.utime(path, (i + 1, i + 1))
            prune_lru_cache(cache_dir, max_size_mb=1, max_files=2)
            left = [name for name in os.listdir(cache_dir) if name.endswith(".wav")]
            check(len(left) <= 2, "lru remaining count after prune")
            check("4.wav" in left, "lru keeps newest file")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

        segs = split_by_language("今天使用 Windows")
        check(len(segs) >= 2, "split mixed text")
        if failed:
            print(f"self-test failed: {failed}", file=sys.stderr)
            return 1
        print("PASS: tts self-test")
        return 0
    finally:
        close_logger(self_test_logger)
        _DEFAULT_LOG_PATH = previous_log_path
        _LOG_TEXT_ENABLED = previous_log_text
        shutil.rmtree(self_test_log_dir, ignore_errors=True)


def main() -> int:
    global _TASK
    _TASK = None
    if "--self-test" in sys.argv:
        raise SystemExit(run_self_test())
    try:
        asyncio.run(main_async())
    except KeyboardInterrupt:
        finish_request('cancelled', 'cancelled')
        return 130
    except TimeoutError:
        finish_request('timeout', 'timeout')
        return 2
    except TaskFailure as error:
        finish_request('timeout' if error.kind == 'timeout' else 'failed', error.kind)
        return 2 if error.kind == 'timeout' else 1
    except Exception as e:
        # 顶层拿不到输入原文上下文：默认只留异常类型，避免未知异常消息泄露文本。
        log_error(
            get_logger(),
            "TTS Player 顶层未捕获异常",
            e,
            log_text=get_log_text_enabled(),
            include_message=get_log_text_enabled(),
        )
        finish_request('failed', 'internal')
        return 1
    if _TASK:
        _TASK.stage = 'complete'
    if not finish_request('success'):
        return 1
    return 0


def finish_request(status: str, kind: str = 'none') -> bool:
    try:
        if _TASK:
            _TASK.finish(status, kind)
        return True
    except OSError:
        get_logger().error('TTS result delivery failed')
        return False


if __name__ == "__main__":
    raise SystemExit(main())
