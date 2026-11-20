#!/usr/bin/env python3
"""tools/tts 单元测试：日志隐私、轮转、配置与自检。

约束：不联网、不合成、不播放；所有日志写入临时目录，绝不触碰仓库内的
``tools/tts/tts.log``。
"""

import io
import asyncio
import logging
import os
import shutil
import sys
import tempfile
import unittest
import uuid
import types
from unittest.mock import patch
from logging.handlers import RotatingFileHandler

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tts_player

MARKER = "LAT3NCY_PRIVACY_MARKER_7f3a9c"


def _make_temp_dir(prefix: str = "lat3ncy-tts-test-") -> str:
    """创建可写临时目录。

    不用 ``tempfile.mkdtemp``：部分 Windows 受限 ACL 环境会把这类目录收紧到
    仅属主可写。普通目录 + 唯一名称同样满足“测试只用临时日志路径”的要求。
    """
    path = os.path.join(tempfile.gettempdir(), f"{prefix}{uuid.uuid4().hex}")
    os.makedirs(path)
    return path


class TtsLoggingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = _make_temp_dir()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _new_logger(self, name: str = "tts-test.log") -> tuple[str, logging.Logger]:
        path = os.path.join(self.tmp, name)
        self.assertNotEqual(
            os.path.normcase(os.path.abspath(path)),
            os.path.normcase(os.path.abspath(tts_player.LOG_FILE)),
            "测试日志绝不能指向仓库内的 tools/tts/tts.log",
        )
        logger = tts_player.build_logger(path, stream=io.StringIO())
        self.addCleanup(tts_player.close_logger, logger)
        return path, logger

    @staticmethod
    def _read(path: str) -> str:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    def test_default_config_logs_metadata_without_source_text(self) -> None:
        cfg = tts_player.load_config(os.path.join(self.tmp, "missing.toml"))
        self.assertIs(cfg["log_text"], False)

        text = f"{MARKER} 今天使用 Windows 语音合成"
        segments = tts_player.split_by_language(text)
        self.assertGreaterEqual(len(segments), 2)

        path, logger = self._new_logger()
        tts_player.log_startup_summary(
            logger,
            text,
            segments,
            engine="winrt",
            zh_voice="Microsoft Yaoyao",
            en_voice="Microsoft Zira",
            concurrency=1,
            log_text=cfg["log_text"],
        )
        tts_player.log_segment_result(
            logger,
            0,
            segments[0][0],
            "cache_hit",
            text=segments[0][1],
            voice="Microsoft Yaoyao",
            duration_ms=1.5,
            log_text=cfg["log_text"],
        )
        tts_player.close_logger(logger)
        content = self._read(path)

        self.assertNotIn(MARKER, content)
        for _, segment_text in segments:
            self.assertNotIn(segment_text, content)
        for expected in (
            "TTS 启动摘要",
            "字符数=",
            "切片数=",
            "中=",
            "英=",
            "引擎=winrt",
            "中文音色=Microsoft Yaoyao",
            "英文音色=Microsoft Zira",
            "缓存命中",
            "耗时=1.5ms",
        ):
            self.assertIn(expected, content)

    def test_log_text_true_includes_source_text(self) -> None:
        text = f"{MARKER} 今天使用 Windows"
        segments = tts_player.split_by_language(text)
        path, logger = self._new_logger()

        tts_player.log_startup_summary(
            logger,
            text,
            segments,
            engine="edge",
            zh_voice="zh-CN-XiaoxiaoNeural",
            en_voice="en-US-JennyNeural",
            concurrency=2,
            log_text=True,
        )
        tts_player.log_segment_result(
            logger,
            0,
            segments[0][0],
            "synthesized",
            text=segments[0][1],
            voice="en-US-JennyNeural",
            duration_ms=2.0,
            log_text=True,
        )
        tts_player.close_logger(logger)
        content = self._read(path)

        self.assertIn(MARKER, content)
        self.assertIn(text, content)
        self.assertIn("文本=", content)

    def test_error_logging_redacts_source_text_by_default(self) -> None:
        text = f"{MARKER} 的完整原文"
        segments = tts_player.split_by_language(text)
        path, logger = self._new_logger()
        error = RuntimeError(f"合成失败：原文={text}；片段={MARKER}")

        tts_player.log_error(
            logger,
            "Edge TTS 合成异常",
            error,
            text=text,
            segments=segments,
            log_text=False,
        )
        tts_player.close_logger(logger)
        content = self._read(path)

        self.assertNotIn(MARKER, content)
        self.assertNotIn(text, content)
        self.assertIn("RuntimeError", content)
        self.assertIn("<text>", content)

    def test_error_logging_uses_registered_context_as_fallback(self) -> None:
        text = f"{MARKER} 的完整上下文原文"
        segments = tts_player.split_by_language(text)
        path, logger = self._new_logger()
        tts_player.set_redaction_context(text, segments)
        try:
            tts_player.log_error(
                logger,
                "合成异常",
                RuntimeError(f"底层异常消息里夹带了原文：{text}"),
                log_text=False,
            )
        finally:
            tts_player.clear_redaction_context()
        tts_player.close_logger(logger)
        content = self._read(path)

        self.assertNotIn(MARKER, content)
        self.assertNotIn(text, content)
        self.assertIn("<text>", content)

    def test_rotation_is_bounded_and_preserves_existing_content(self) -> None:
        path = os.path.join(self.tmp, "rotate.log")
        seed = "PREEXISTING_TTS_LOG_CONTENT"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(seed + "\n")
        self.assertNotEqual(
            os.path.normcase(os.path.abspath(path)),
            os.path.normcase(os.path.abspath(tts_player.LOG_FILE)),
            "测试日志绝不能指向仓库内的 tools/tts/tts.log",
        )
        logger = tts_player.build_logger(path, stream=io.StringIO())
        self.addCleanup(tts_player.close_logger, logger)
        handler = next(
            (
                item
                for item in logger.handlers
                if isinstance(item, RotatingFileHandler)
            ),
            None,
        )
        self.assertIsNotNone(handler)
        assert isinstance(handler, RotatingFileHandler)

        self.assertEqual(handler.mode, "a")
        self.assertGreater(handler.maxBytes, 0)
        self.assertGreater(handler.backupCount, 0)
        self.assertLessEqual(handler.maxBytes, 8 * 1024 * 1024)
        self.assertLessEqual(handler.backupCount, 5)

        logger.info("%s", "x" * (tts_player.LOG_MAX_BYTES + 1024))
        logger.info("AFTER_ROTATION")
        tts_player.close_logger(logger)

        self.assertTrue(os.path.isfile(path))
        names = os.listdir(self.tmp)
        backups = [name for name in names if name.startswith("rotate.log.")]
        self.assertTrue(backups, "写入超过上限后应产生 rotate.log.1/.2 备份")
        self.assertLessEqual(len(backups), handler.backupCount)

        combined = "\n".join(
            self._read(os.path.join(self.tmp, name))
            for name in names
            if name == "rotate.log" or name.startswith("rotate.log.")
        )
        self.assertIn(seed, combined)
        self.assertIn("AFTER_ROTATION", self._read(path))

    def test_load_config_defaults_log_text_to_false_and_respects_true(self) -> None:
        missing = os.path.join(self.tmp, "missing.toml")
        self.assertIs(tts_player.load_config(missing)["log_text"], False)

        opt_in = os.path.join(self.tmp, "opt-in.toml")
        with open(opt_in, "w", encoding="utf-8") as handle:
            handle.write("log_text = true\n")
        self.assertIs(tts_player.load_config(opt_in)["log_text"], True)

        opt_out = os.path.join(self.tmp, "opt-out.toml")
        with open(opt_out, "w", encoding="utf-8") as handle:
            handle.write("log_text = false\n")
        self.assertIs(tts_player.load_config(opt_out)["log_text"], False)

    def test_build_logger_uses_unique_names_for_distinct_paths(self) -> None:
        _, logger_a = self._new_logger("a.log")
        _, logger_b = self._new_logger("b.log")
        self.assertNotEqual(logger_a.name, logger_b.name)

    def test_existing_self_test_still_passes(self) -> None:
        self.assertEqual(tts_player.run_self_test(), 0)


class UniqueTempPathTests(unittest.TestCase):
    """重复片段并发合成同一个缓存条目时，临时文件不能撞名。"""

    def test_same_cache_entry_gets_distinct_temp_paths(self) -> None:
        cache_path = os.path.join("cache", "deadbeef.mp3")
        paths = {tts_player.unique_temp_path(cache_path, ".mp3") for _ in range(64)}
        self.assertEqual(64, len(paths))
        for path in paths:
            self.assertTrue(path.startswith(cache_path + ".tmp."))
            self.assertTrue(path.endswith(".mp3"))

    def test_temp_paths_stay_inside_the_cache_directory(self) -> None:
        cache_path = os.path.join("cache", "sub", "deadbeef.wav")
        path = tts_player.unique_temp_path(cache_path, ".wav")
        self.assertEqual(os.path.dirname(cache_path), os.path.dirname(path))

    def test_download_failure_cleans_partial_audio(self) -> None:
        async def fail_after_write(path):
            with open(path, "wb") as handle:
                handle.write(b"partial audio")
            raise OSError("connection reset")
        fake = types.SimpleNamespace(Communicate=lambda *a, **k: types.SimpleNamespace(save=fail_after_write))
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(sys.modules, {"edge_tts": fake}), \
                patch.object(tts_player, "get_logger"), patch.object(tts_player, "log_error"):
            path = os.path.join(directory, "cache.mp3")
            self.assertFalse(asyncio.run(tts_player.synthesize_edge_segment(
                "voice", "hello", "+0%", "+0Hz", "+0%", path)))
            self.assertEqual([], os.listdir(directory))

    def test_cancelled_download_cleans_partial_audio(self) -> None:
        async def cancel_after_write(path):
            with open(path, "wb") as handle:
                handle.write(b"partial audio")
            raise asyncio.CancelledError()
        fake = types.SimpleNamespace(Communicate=lambda *a, **k: types.SimpleNamespace(save=cancel_after_write))
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, {"edge_tts": fake}):
            path = os.path.join(directory, "cache.mp3")
            with self.assertRaises(asyncio.CancelledError):
                asyncio.run(tts_player.synthesize_edge_segment("voice", "hello", "+0%", "+0Hz", "+0%", path))
            self.assertEqual([], os.listdir(directory))


if __name__ == "__main__":
    unittest.main()
