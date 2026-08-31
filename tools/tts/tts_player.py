#!/usr/bin/env python3
"""Lat3ncy TTS Player & Language Segmenter.

获取输入文本，按中英文语境智能切片，通过 WinRT 本地 OneCore 引擎或 Edge Neural TTS 并发流水线合成并即时播放。
支持全并发请求、流水线即时播放（首段就绪即播）、SHA256 多维缓存、LRU 容量管理与 Windows SAPI 本地兜底。
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
import tomllib
from typing import Any

ZH_CHAR_PATTERN = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff]")
ZH_PUNCT_PATTERN = re.compile(r"[\u3000-\u303f\uff01-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65]")
EN_CHAR_PATTERN = re.compile(r"[A-Za-z]")
HAS_WORD_CHAR = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaffA-Za-z0-9]")

LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tts.log")


def get_logger() -> logging.Logger:
    logger = logging.getLogger("lat3ncy_tts")
    if not logger.handlers:
        logger.setLevel(logging.DEBUG)
        formatter = logging.Formatter(
            "[%(asctime)s] [Python/%(levelname)s] %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
        try:
            fh = logging.FileHandler(LOG_FILE, encoding="utf-8", mode="a")
            fh.setFormatter(formatter)
            logger.addHandler(fh)
        except Exception:
            pass

        ch = logging.StreamHandler(sys.stdout)
        ch.setFormatter(formatter)
        logger.addHandler(ch)
    return logger


def get_default_cache_dir() -> str:
    local_app_data = os.environ.get(
        "LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local")
    )
    cache_dir = os.path.join(local_app_data, "lat3ncy-toolbox", "tts-cache")
    os.makedirs(cache_dir, exist_ok=True)
    return cache_dir


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
            get_logger().warning(f"加载配置文件失败，使用默认配置: {e}")

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


def compute_cache_key(text: str, voice: str, rate: str, pitch: str, volume: str) -> str:
    payload = f"{text}\n{voice}\n{rate}\n{pitch}\n{volume}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def prune_lru_cache(cache_dir: str, max_size_mb: int, max_files: int) -> None:
    """按最后访问时间 (atime) 清理超额缓存文件。"""
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
            get_logger().info(f"LRU 缓存清理: 移除了 {deleted} 个过期缓存文件")
    except Exception as e:
        get_logger().warning(f"LRU 缓存清理异常: {e}")


async def synthesize_winrt_segment(voice_name: str, seg_text: str, cache_path: str) -> bool:
    """使用 WinRT 本地离线合成语音 (零网络延迟)。"""
    logger = get_logger()
    try:
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
            logger.warning(f"未找到指定的 WinRT 语音 '{voice_name}'，使用默认语音: {current_name}")

        stream = await synth.synthesize_text_to_stream_async(seg_text)
        reader = streams.DataReader(stream.get_input_stream_at(0))
        await reader.load_async(stream.size)
        # winsdk 类型桩要求 Array[UInt8]，运行时 bytearray 可用；用 Any 避免改播放路径。
        buf: Any = bytearray(stream.size)
        reader.read_bytes(buf)

        temp_file = cache_path + f".tmp.{os.getpid()}.wav"
        with open(temp_file, "wb") as f:
            f.write(buf)

        if os.path.exists(cache_path):
            os.remove(cache_path)
        shutil.move(temp_file, cache_path)
        return True
    except Exception as e:
        logger.error(f"WinRT 本地合成异常: {e}")
        return False


async def synthesize_edge_segment(
    voice: str,
    seg_text: str,
    rate: str,
    pitch: str,
    volume: str,
    cache_path: str,
) -> bool:
    """使用 Edge 在线 Neural TTS 合成语音。"""
    logger = get_logger()
    try:
        import edge_tts

        communicate = edge_tts.Communicate(
            seg_text, voice=voice, rate=rate, pitch=pitch, volume=volume
        )
        temp_file = cache_path + f".tmp.{os.getpid()}.mp3"
        await communicate.save(temp_file)
        if os.path.isfile(temp_file) and os.path.getsize(temp_file) > 0:
            if os.path.exists(cache_path):
                os.remove(cache_path)
            shutil.move(temp_file, cache_path)
            return True
        return False
    except Exception as e:
        logger.error(f"Edge TTS 合成异常: {e}")
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
) -> None:
    logger = get_logger()

    async def _do_synthesize():
        if os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0:
            logger.info(f"片段 #{idx+1} [{lang}] 命中缓存: {os.path.basename(cache_path)[:12]}... ({seg_text})")
            try:
                os.utime(cache_path, None)
            except OSError:
                pass
            result_files[idx] = cache_path
            return

        is_winrt = (
            engine == "winrt"
            or voice.startswith("Microsoft ")
            or "Neural" not in voice
        )

        if is_winrt:
            logger.info(f"片段 #{idx+1} [{lang}] 本地 WinRT 瞬发合成: {voice} -> {seg_text}")
            ok = await synthesize_winrt_segment(voice, seg_text, cache_path)
        else:
            logger.info(f"片段 #{idx+1} [{lang}] Edge 云端合成: {voice} -> {seg_text}")
            ok = await synthesize_edge_segment(voice, seg_text, rate, pitch, volume, cache_path)

        if ok and os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0:
            result_files[idx] = cache_path
            logger.debug(f"片段 #{idx+1} [{lang}] 合成就绪")
        else:
            logger.error(f"片段 #{idx+1} [{lang}] 输出文件无效")

    try:
        if semaphore is not None:
            async with semaphore:
                await _do_synthesize()
        else:
            await _do_synthesize()
    except Exception as e:
        logger.error(f"片段 #{idx+1} [{lang}] 合成发生异常: {e}")
    finally:
        ready_events[idx].set()


def play_sapi_fallback(text: str) -> None:
    """当所有合成不可用时使用 Windows PowerShell 本地 SAPI 兜底朗读。"""
    logger = get_logger()
    logger.info(f"启用 Windows SAPI 本地朗读: {text}")
    try:
        safe_text = text.replace("'", "''")
        cmd = [
            "powershell",
            "-NoProfile",
            "-Command",
            f"Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak('{safe_text}')",
        ]
        subprocess.run(
            cmd,
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
            timeout=10,
        )
    except Exception as e:
        logger.error(f"Windows SAPI 朗读异常: {e}")


def play_audio_file(file_path: str) -> None:
    """使用 Windows MCI 播放 MP3 / WAV 音频文件。"""
    logger = get_logger()
    if sys.platform != "win32":
        return

    winmm = ctypes.windll.winmm
    alias = f"lat3ncy_tts_{os.getpid()}"
    full_path = os.path.abspath(file_path)

    winmm.mciSendStringW(f"close {alias}", None, 0, None)
    
    # 自动识别类型
    file_type = "type mpegvideo" if full_path.lower().endswith(".mp3") else ""
    open_cmd = f'open "{full_path}" {file_type} alias {alias}'.strip()
    err = winmm.mciSendStringW(open_cmd, None, 0, None)
    if err != 0:
        logger.error(f"MCI open 失败, error code: {err}, path: {full_path}")
        return

    try:
        logger.debug(f"播放片段音频 (MCI): {os.path.basename(full_path)}")
        play_err = winmm.mciSendStringW(f"play {alias} wait", None, 0, None)
        if play_err != 0:
            logger.error(f"MCI play 失败, error code: {play_err}")
    finally:
        winmm.mciSendStringW(f"close {alias}", None, 0, None)


async def main_async() -> None:
    logger = get_logger()
    logger.info("=== TTS Player 启动 ===")

    parser = argparse.ArgumentParser(description="Lat3ncy TTS Player")
    parser.add_argument("--text", type=str, default="", help="要朗读的文本")
    parser.add_argument("--input-file", type=str, default="", help="包含要朗读文本的文件路径")
    parser.add_argument("--config", type=str, default=None, help="配置文件路径")
    args = parser.parse_args()

    input_text = args.text
    if args.input_file and os.path.isfile(args.input_file):
        try:
            with open(args.input_file, "r", encoding="utf-8") as f:
                input_text = f.read()
        except Exception as e:
            logger.error(f"读取输入文件失败: {e}")

    input_text = input_text.strip()
    if not input_text:
        return

    config = load_config(args.config)
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
        return

    concurrency = int(config.get("concurrency", 2))
    concurrency = max(1, min(concurrency, 10))
    semaphore = asyncio.Semaphore(concurrency)

    logger.info(f"待朗读文本: {repr(input_text)} -> {len(segments)} 个语境切片 [中:{zh_voice}, 英:{en_voice}] 并发={concurrency}")

    ready_events = [asyncio.Event() for _ in segments]
    result_files: list[str | None] = [None] * len(segments)

    # 1. 启动受控并发合成 Task (并发上限={concurrency})
    tasks = []
    for idx, (lang, seg_text) in enumerate(segments):
        voice = zh_voice if lang == "zh" else en_voice
        ext = ".wav" if (engine == "winrt" or voice.startswith("Microsoft ") or "Neural" not in voice) else ".mp3"
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
                )
            )
        )

    # 2. 流水线即时播放（首段就绪即开播）
    for idx in range(len(segments)):
        await ready_events[idx].wait()
        audio_path = result_files[idx]
        if audio_path and os.path.isfile(audio_path):
            # MCI play ... wait 会堵住事件循环；丢到线程里，合成任务才能继续排队。
            # 仍按片段下标顺序 await，音频不会乱序。
            await asyncio.to_thread(play_audio_file, audio_path)
        else:
            lang, seg_text = segments[idx]
            await asyncio.to_thread(play_sapi_fallback, seg_text)

    # 等待所有后台任务完成并执行 LRU 容量清理
    await asyncio.gather(*tasks, return_exceptions=True)
    prune_lru_cache(cache_dir, max_size_mb, max_files)

    logger.info("=== TTS Player 播放完成退出 ===")


def run_self_test() -> int:
    """纯函数/文件系统单测：不合成、不播放。"""
    import tempfile

    failed = 0

    def check(cond: bool, name: str) -> None:
        nonlocal failed
        if not cond:
            print(f"FAIL {name}", file=sys.stderr)
            failed += 1

    cfg = load_config(os.path.join(tempfile.gettempdir(), "lat3ncy-missing-tts.toml"))
    check(cfg["zh_voice"] == "Microsoft Yaoyao", "default zh_voice")
    check(cfg["en_voice"] == "Microsoft Zira", "default en_voice")
    check(1 <= int(cfg["concurrency"]) <= 10, "default concurrency range")

    with tempfile.TemporaryDirectory() as tmp:
        bad = os.path.join(tmp, "bad.toml")
        with open(bad, "w", encoding="utf-8") as handle:
            handle.write("concurrency = 99\n[cache]\nmax_size_mb = 0\nmax_files = -3\n")
        loaded = load_config(bad)
        check(loaded["concurrency"] == 10, "concurrency clamp high")
        check(loaded["cache"]["max_size_mb"] == 1, "max_size_mb clamp low")
        check(loaded["cache"]["max_files"] == 1, "max_files clamp low")

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

    segs = split_by_language("今天使用 Windows")
    check(len(segs) >= 2, "split mixed text")
    if failed:
        print(f"self-test failed: {failed}", file=sys.stderr)
        return 1
    print("PASS: tts self-test")
    return 0


def main() -> None:
    if "--self-test" in sys.argv:
        raise SystemExit(run_self_test())
    try:
        asyncio.run(main_async())
    except KeyboardInterrupt:
        pass
    except Exception as e:
        get_logger().error(f"TTS Player 顶层未捕获异常: {e}", exc_info=True)


if __name__ == "__main__":
    main()
