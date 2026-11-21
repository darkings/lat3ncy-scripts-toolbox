"""translate.py 的行为测试。

约束：不联网、不读 HKCU、不使用真实密钥。
- 每个测试都 patch 掉 http_json / read_user_env，并把 cache_dir 指到临时目录。
- 翻译路径统一 patch call_engine，用 stub 引擎。
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
import uuid
from collections.abc import Callable
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import translate as tr

REPO_ROOT = Path(__file__).resolve().parents[2]
TMP_ROOT = REPO_ROOT / ".lat3ncy-tools-tmp"


class TranslateTestBase(unittest.TestCase):
    """公共环境：断网、断 HKCU、临时缓存/工作目录。"""

    @staticmethod
    def _make_workspace_temp_dir() -> Path:
        """优先在仓库 .lat3ncy-tools-tmp 下建目录，避免依赖 TEMP 可写。"""
        try:
            TMP_ROOT.mkdir(parents=True, exist_ok=True)
        except OSError:
            return Path(tempfile.mkdtemp(prefix="translate-test-"))
        for _ in range(10):
            candidate = TMP_ROOT / f"translate-test-{uuid.uuid4().hex}"
            try:
                candidate.mkdir()
            except FileExistsError:
                continue
            except OSError:
                break
            return candidate
        return Path(tempfile.mkdtemp(prefix="translate-test-"))

    def setUp(self) -> None:
        # 注意：tempfile.TemporaryDirectory 用 mkdir(mode=0700)，在当前 Windows
        # 沙箱下会生成一个后续写不进去的 ACL；这里改成默认 mode 的目录。
        root = self._make_workspace_temp_dir()
        self.addCleanup(shutil.rmtree, root, True)
        self.work_dir = root / "work"
        self.cache_root = root / "cache"
        self.work_dir.mkdir()
        self.cache_root.mkdir()
        self._seq = 0

        # 测试禁止真实网络、HKCU 与真实缓存目录。
        self._patches = [
            mock.patch.object(tr, "read_user_env", return_value=""),
            mock.patch.object(
                tr,
                "http_json",
                side_effect=AssertionError("network disabled in tests"),
            ),
            mock.patch.object(tr, "cache_dir", return_value=self.cache_root),
        ]
        for patcher in self._patches:
            patcher.start()
            self.addCleanup(patcher.stop)

        # 清空可能存在于进程环境里的凭证，避免用真实密钥。
        self._env = mock.patch.dict(
            os.environ,
            {name: "" for name in tr.CREDENTIAL_ENV_NAMES},
            clear=False,
        )
        self._env.start()
        self.addCleanup(self._env.stop)

    # ---------- 文件与协议辅助 ----------

    def _next_path(self, prefix: str, suffix: str) -> Path:
        self._seq += 1
        return self.work_dir / f"{prefix}-{self._seq}{suffix}"

    def write_config(self, body: str) -> Path:
        path = self._next_path("config", ".toml")
        path.write_text(body, encoding="utf-8")
        return path

    @staticmethod
    def parse_output(raw: str) -> dict[str, str]:
        fields: dict[str, str] = {}
        lines = raw.splitlines()
        text_index = next(
            (index for index, line in enumerate(lines) if line.startswith("text=")),
            None,
        )
        head = lines if text_index is None else lines[:text_index]
        for line in head:
            key, separator, value = line.partition("=")
            if separator:
                fields[key] = value
        if text_index is not None:
            fields["text"] = "\n".join(
                [lines[text_index][len("text=") :]] + lines[text_index + 1 :]
            )
        return fields

    def invoke(
        self,
        text: str,
        config_body: str,
        fake_engine: Callable[..., str] | None = None,
        *,
        input_file: str | None = None,
    ) -> tuple[int, dict[str, str], str, Path]:
        config_path = self.write_config(config_body)
        output = self._next_path("out", ".txt")
        argv = ["--output-file", str(output)]
        if input_file is None:
            argv.extend(["--text", text])
        else:
            argv.extend(["--input-file", input_file])
        argv.extend(["--config", str(config_path)])
        if fake_engine is None:
            return_code = tr.main(argv)
        else:
            with mock.patch.object(tr, "call_engine", side_effect=fake_engine):
                return_code = tr.main(argv)
        raw = output.read_text(encoding="utf-8") if output.is_file() else ""
        return return_code, self.parse_output(raw), raw, output

    def config_body(
        self,
        *,
        engine: str = "tencent",
        fallback: bool = False,
        max_chars: int = 2000,
        timeout_s: float = 4,
        tencent_id: str = "test-id",
        tencent_key: str = "test-secret",
        region: str = "ap-guangzhou",
        endpoint: str = "tmt.tencentcloudapi.com",
        project_id: int = 0,
        aliyun_id: str = "",
        aliyun_key: str = "",
        aliyun_endpoint: str = "mt.cn-hangzhou.aliyuncs.com",
    ) -> str:
        return (
            f'engine = "{engine}"\n'
            f"fallback_without_credentials = {str(fallback).lower()}\n"
            f"max_chars = {max_chars}\n"
            f"timeout_s = {timeout_s}\n"
            "\n"
            "[cache]\n"
            "max_size_mb = 10\n"
            "max_files = 500\n"
            "\n"
            "[tencent]\n"
            f'secret_id = "{tencent_id}"\n'
            f'secret_key = "{tencent_key}"\n'
            f'region = "{region}"\n'
            f'endpoint = "{endpoint}"\n'
            f"project_id = {project_id}\n"
            "\n"
            "[aliyun]\n"
            f'access_key_id = "{aliyun_id}"\n'
            f'access_key_secret = "{aliyun_key}"\n'
            f'endpoint = "{aliyun_endpoint}"\n'
        )

    def tencent_cfg(self, **overrides: object) -> dict:
        section: dict[str, object] = {
            "secret_id": "test-id",
            "secret_key": "test-secret",
            "endpoint": tr.DEFAULT_TENCENT_ENDPOINT,
            "region": tr.DEFAULT_TENCENT_REGION,
            "project_id": 0,
        }
        section.update(overrides)
        return {"tencent": section}

    def cache_path(self, engine: str, direction: str, text: str, cfg: dict) -> Path:
        key = tr.cache_key(engine, direction, text, cfg)
        return self.cache_root / f"{key}{tr.CACHE_SUFFIX}"

    def write_cache_record(self, engine: str, direction: str, text: str, cfg: dict, record: object) -> Path:
        path = self.cache_path(engine, direction, text, cfg)
        path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        return path

    @staticmethod
    def assert_no_tmp_files(test: unittest.TestCase, folder: Path) -> None:
        leftovers = [item.name for item in folder.iterdir() if ".tmp." in item.name]
        test.assertEqual(leftovers, [], f"temporary cache files left behind: {leftovers}")


class EnginePlanTests(TranslateTestBase):
    def test_missing_cloud_credentials_is_config_error_by_default(self) -> None:
        cfg = {
            "fallback_without_credentials": False,
            "tencent": {"secret_id": "", "secret_key": ""},
            "aliyun": {"access_key_id": "", "access_key_secret": ""},
        }
        with self.assertRaises(tr.ConfigError) as tencent_error:
            tr.engine_order("tencent", cfg)
        self.assertIn("腾讯云", str(tencent_error.exception))
        with self.assertRaises(tr.ConfigError) as aliyun_error:
            tr.engine_order("aliyun", cfg)
        self.assertIn("阿里云", str(aliyun_error.exception))

        # 协议层：缺密钥必须 code=config，而不是偷偷用 google。
        body = self.config_body(tencent_id="", tencent_key="")
        return_code, fields, _raw, _output = self.invoke("hello", body)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "config")
        self.assertEqual(fields["engine"], "tencent")
        self.assertIn("密钥", fields["message"])
        self.assertIn("ConfigError", fields["detail"])

    def test_opt_in_fallback_without_credentials(self) -> None:
        cfg = {
            "fallback_without_credentials": True,
            "tencent": {"secret_id": "", "secret_key": ""},
            "aliyun": {"access_key_id": "", "access_key_secret": ""},
        }
        self.assertEqual(
            tr.engine_order("tencent", cfg),
            ["google_gtx", "mymemory"],
        )
        self.assertEqual(
            tr.engine_order("aliyun", cfg),
            ["google_gtx", "mymemory"],
        )

        calls: list[str] = []

        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            calls.append(name)
            return "免费译文"

        with mock.patch.object(tr, "call_engine", side_effect=fake):
            result = tr.translate_with_cache("tencent", "hello", "en-zh", 1, cfg)
        self.assertEqual(result.text, "免费译文")
        self.assertEqual(result.engine, "google_gtx")
        self.assertFalse(result.cached)
        self.assertEqual(calls, ["google_gtx"])

        body = self.config_body(tencent_id="", tencent_key="", fallback=True)
        # 换一段文本，避免命中上面直接调用写入的缓存。
        return_code, fields, _raw, _output = self.invoke("world", body, fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "ok")
        self.assertEqual(fields["engine"], "google_gtx")
        self.assertEqual(fields["cached"], "0")
        self.assertEqual(fields["text"], "免费译文")

    def test_auth_failure_never_falls_back(self) -> None:
        cfg = self.tencent_cfg()
        # 即使免费引擎有缓存，鉴权失败也不能拿它冒充成功。
        tr.cache_put("google_gtx", "en-zh", "hello", "旧免费译文", cfg)
        calls: list[str] = []

        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            calls.append(name)
            raise tr.AuthError("腾讯云密钥无效")

        with mock.patch.object(tr, "call_engine", side_effect=fake):
            with self.assertRaises(tr.AuthError):
                tr.translate_with_cache("tencent", "hello", "en-zh", 1, cfg)
        self.assertEqual(calls, ["tencent"])

        body = self.config_body(region="ap-guangzhou")
        return_code, fields, raw, _output = self.invoke("hello", body, fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "auth")
        self.assertEqual(fields["engine"], "tencent")
        self.assertEqual(fields["message"], "腾讯云密钥无效")
        self.assertNotIn("旧免费译文", raw)
        self.assertNotIn("test-secret", raw)

    def test_network_failure_falls_back_and_reports_actual_engine(self) -> None:
        cfg = self.tencent_cfg()
        calls: list[str] = []

        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            calls.append(name)
            if name == "tencent":
                raise urllib.error.URLError("offline")
            return "谷歌译文"

        with mock.patch.object(tr, "call_engine", side_effect=fake):
            result = tr.translate_with_cache("tencent", "hello", "en-zh", 1, cfg)
        self.assertEqual(result.text, "谷歌译文")
        self.assertEqual(result.engine, "google_gtx")
        self.assertFalse(result.cached)
        self.assertEqual(calls, ["tencent", "google_gtx"])

        body = self.config_body()
        # 换一段文本，避免直接调用写入的 google 缓存；这里要验证真实回退。
        return_code, fields, _raw, _output = self.invoke("world", body, fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "ok")
        self.assertEqual(fields["engine"], "google_gtx")
        self.assertEqual(fields["cached"], "0")
        self.assertEqual(fields["text"], "谷歌译文")

    def test_mymemory_error_status_is_not_returned_as_translation(self) -> None:
        error_text = "QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS"
        payload = {
            "responseStatus": 403,
            "responseDetails": error_text,
            "responseData": {"translatedText": error_text},
        }
        with mock.patch.object(tr, "http_json", return_value=payload):
            with self.assertRaises(ValueError):
                tr.translate_mymemory("x" * 600, "en", "zh", 1)

    def test_mymemory_success_payload_still_returns_text(self) -> None:
        payload = {"responseStatus": 200, "responseData": {"translatedText": " 你好 "}}
        with mock.patch.object(tr, "http_json", return_value=payload):
            self.assertEqual(tr.translate_mymemory("hello", "en", "zh", 1), "你好")

    def test_google_falls_back_to_mymemory(self) -> None:
        calls: list[str] = []

        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            calls.append(name)
            if name == "google_gtx":
                raise urllib.error.URLError("offline")
            return "MyMemory 译文"

        with mock.patch.object(tr, "call_engine", side_effect=fake):
            result = tr.translate_with_cache("google_gtx", "hello", "en-zh", 1, {})
        self.assertEqual(result.text, "MyMemory 译文")
        self.assertEqual(result.engine, "mymemory")
        self.assertEqual(calls, ["google_gtx", "mymemory"])

    def test_translate_text_wrapper_keeps_str_contract(self) -> None:
        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            return f"{name}:{text}"

        with mock.patch.object(tr, "call_engine", side_effect=fake):
            translated = tr.translate_text("google_gtx", "hello", "en-zh", 1, {})
        self.assertIsInstance(translated, str)
        self.assertEqual(translated, "google_gtx:hello")


class CacheTests(TranslateTestBase):
    def test_same_text_different_engines_are_isolated(self) -> None:
        cfg = self.tencent_cfg()
        tr.cache_put("tencent", "en-zh", "hello", "腾讯译文", cfg)
        self.assertEqual(tr.cache_get("tencent", "en-zh", "hello", cfg), "腾讯译文")
        self.assertIsNone(tr.cache_get("google_gtx", "en-zh", "hello", cfg))
        self.assertIsNone(tr.cache_get("aliyun", "en-zh", "hello", cfg))
        self.assertIsNone(tr.cache_get("tencent", "zh-en", "hello", cfg))
        self.assertIsNone(tr.cache_get("tencent", "en-zh", "hello!", cfg))

    def test_config_change_invalidates_output_scoped_cache(self) -> None:
        cfg = self.tencent_cfg()
        tr.cache_put("tencent", "en-zh", "hello", "旧译文", cfg)
        variants = [
            self.tencent_cfg(endpoint="tmt.ap-shanghai.tencentcloudapi.com"),
            self.tencent_cfg(region="ap-shanghai"),
            self.tencent_cfg(project_id=42),
        ]
        for changed in variants:
            self.assertIsNone(tr.cache_get("tencent", "en-zh", "hello", changed))
        # 协议里同一 host 的 scheme/尾斜杠差异不算配置变化。
        same_host = self.tencent_cfg(endpoint="https://tmt.tencentcloudapi.com/")
        self.assertEqual(tr.cache_get("tencent", "en-zh", "hello", same_host), "旧译文")

        aliyun_cfg = {"aliyun": {"endpoint": "mt.cn-hangzhou.aliyuncs.com"}}
        tr.cache_put("aliyun", "en-zh", "hello", "阿里译文", aliyun_cfg)
        changed_aliyun = {"aliyun": {"endpoint": "mt.ap-southeast-1.aliyuncs.com"}}
        self.assertIsNone(tr.cache_get("aliyun", "en-zh", "hello", changed_aliyun))

        # 免费引擎没有输出相关的配置项。
        tr.cache_put("google_gtx", "en-zh", "hello", "谷歌译文", cfg)
        for changed in variants:
            self.assertEqual(
                tr.cache_get("google_gtx", "en-zh", "hello", changed),
                "谷歌译文",
            )

    def test_old_txt_and_raw_text_json_are_never_read(self) -> None:
        cfg = self.tencent_cfg()
        # 1) 旧实现按 direction+text 命名 .txt。
        legacy_key = hashlib.sha256(b"en-zh\nhello").hexdigest()
        (self.cache_root / f"{legacy_key}.txt").write_text("旧格式译文", encoding="utf-8")
        # 2) 即便是新键名，.txt 后缀也不读。
        new_key = tr.cache_key("tencent", "en-zh", "hello", cfg)
        (self.cache_root / f"{new_key}.txt").write_text("旧格式译文2", encoding="utf-8")
        # 3) .json 路径里塞旧纯文本，解析失败必须当作未命中。
        (self.cache_root / f"{new_key}.json").write_text("旧纯文本", encoding="utf-8")
        self.assertIsNone(tr.cache_get("tencent", "en-zh", "hello", cfg))

    def test_cache_record_format_validation(self) -> None:
        cfg = self.tencent_cfg()
        valid = {
            "version": tr.CACHE_VERSION,
            "engine": "tencent",
            "direction": "en-zh",
            "translated": "你好",
        }
        self.write_cache_record("tencent", "en-zh", "hello", cfg, valid)
        self.assertEqual(tr.cache_get("tencent", "en-zh", "hello", cfg), "你好")

        invalid_records = [
            {**valid, "version": 1},
            {**valid, "version": None},
            {**valid, "engine": "aliyun"},
            {**valid, "direction": "zh-en"},
            {**valid, "translated": ""},
            {**valid, "translated": "   "},
            {**valid, "translated": 42},
            ["not", "a", "record"],
        ]
        for record in invalid_records:
            with self.subTest(record=record):
                self.write_cache_record("tencent", "en-zh", "hello", cfg, record)
                self.assertIsNone(tr.cache_get("tencent", "en-zh", "hello", cfg))

        # 记录只要求 version + engine；缺 direction 时仍可按键命中。
        without_direction = {"version": tr.CACHE_VERSION, "engine": "tencent", "translated": "你好"}
        self.write_cache_record("tencent", "en-zh", "hello", cfg, without_direction)
        self.assertEqual(tr.cache_get("tencent", "en-zh", "hello", cfg), "你好")

    def test_cache_put_is_atomic_and_cleans_temp_file(self) -> None:
        cfg = self.tencent_cfg()
        path = self.cache_path("tencent", "en-zh", "hello", cfg)
        tr.cache_put("tencent", "en-zh", "hello", "第一版", cfg)
        self.assertTrue(path.is_file())
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["translated"], "第一版")
        self.assert_no_tmp_files(self, self.cache_root)

        # os.replace 失败：旧文件保持完整，临时文件被清掉。
        with mock.patch.object(tr.os, "replace", side_effect=OSError("disk full")):
            tr.cache_put("tencent", "en-zh", "hello", "第二版", cfg)
        self.assertEqual(tr.cache_get("tencent", "en-zh", "hello", cfg), "第一版")
        self.assert_no_tmp_files(self, self.cache_root)

        # 首次写入就失败：不留下半成品目标文件。
        other_cfg = self.tencent_cfg(project_id=7)
        other_path = self.cache_path("tencent", "en-zh", "hello", other_cfg)
        with mock.patch.object(tr.os, "replace", side_effect=OSError("disk full")):
            tr.cache_put("tencent", "en-zh", "hello", "失败版", other_cfg)
        self.assertFalse(other_path.exists())
        self.assert_no_tmp_files(self, self.cache_root)

    def test_fallback_cache_only_consulted_after_primary_failure(self) -> None:
        cfg = self.tencent_cfg()
        # 免费引擎已有旧缓存：首选付费引擎成功时绝不能用它。
        tr.cache_put("google_gtx", "en-zh", "world", "旧免费译文", cfg)
        calls: list[str] = []

        def primary_ok(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            calls.append(name)
            if name != "tencent":
                raise AssertionError("fallback engine must not be called")
            return "腾讯新译"

        with mock.patch.object(tr, "call_engine", side_effect=primary_ok):
            result = tr.translate_with_cache("tencent", "hello", "en-zh", 1, cfg)
        self.assertEqual(result.text, "腾讯新译")
        self.assertEqual(result.engine, "tencent")
        self.assertFalse(result.cached)
        self.assertEqual(calls, ["tencent"])

        # 首选真的失败后，才轮到回退引擎的缓存（且不再打网络）。
        calls.clear()

        def primary_fail(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            calls.append(name)
            if name == "tencent":
                raise urllib.error.URLError("offline")
            raise AssertionError("fallback engine must come from cache")

        with mock.patch.object(tr, "call_engine", side_effect=primary_fail):
            result = tr.translate_with_cache("tencent", "world", "en-zh", 1, cfg)
        self.assertEqual(result.text, "旧免费译文")
        self.assertEqual(result.engine, "google_gtx")
        self.assertTrue(result.cached)
        self.assertEqual(calls, ["tencent"])

        # 协议层同样要报告回退缓存的真实来源与 cached=1。
        return_code, fields, _raw, _output = self.invoke(
            "world",
            self.config_body(),
            primary_fail,
        )
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "ok")
        self.assertEqual(fields["engine"], "google_gtx")
        self.assertEqual(fields["cached"], "1")
        self.assertEqual(fields["text"], "旧免费译文")

        # 鉴权失败连缓存回退也不允许。
        tr.cache_put("google_gtx", "en-zh", "auth", "旧免费译文", cfg)
        auth_calls: list[str] = []

        def primary_auth(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            auth_calls.append(name)
            raise tr.AuthError("腾讯云密钥无效")

        with mock.patch.object(tr, "call_engine", side_effect=primary_auth):
            with self.assertRaises(tr.AuthError):
                tr.translate_with_cache("tencent", "auth", "en-zh", 1, cfg)
        self.assertEqual(auth_calls, ["tencent"])

    def test_cached_result_reports_source_engine(self) -> None:
        cfg = self.tencent_cfg()
        tr.cache_put("tencent", "en-zh", "hello", "缓存译文", cfg)
        with mock.patch.object(
            tr,
            "call_engine",
            side_effect=AssertionError("cache hit must not call engine"),
        ):
            result = tr.translate_with_cache("tencent", "hello", "en-zh", 1, cfg)
        self.assertEqual(result.text, "缓存译文")
        self.assertEqual(result.engine, "tencent")
        self.assertTrue(result.cached)
        self.assertEqual(result.direction, "en-zh")


class ProtocolAndTruncationTests(TranslateTestBase):
    def test_too_long_boundary_is_exact(self) -> None:
        body = self.config_body(engine="google_gtx", max_chars=5)

        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            return "边界译文"

        return_code, fields, _raw, _output = self.invoke("abcde", body, fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "ok")
        self.assertEqual(fields["text"], "边界译文")

        # len == max + 1：不截断、不翻译，直接 too_long。
        return_code, fields, raw, _output = self.invoke("abcdef", body)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "too_long")
        self.assertEqual(fields["length"], "6")
        self.assertEqual(fields["max_chars"], "5")
        self.assertEqual(fields["engine"], "google_gtx")
        self.assertIn("过长", fields["message"])
        self.assertNotIn("text", fields)
        self.assertEqual(fields["detail"], "")
        # 原文不能被截成前 5 个字出现在输出里。
        self.assertNotIn("text=abcde", raw)

    def test_success_protocol_text_last_and_multiline(self) -> None:
        body = self.config_body()

        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            self.assertEqual(name, "tencent")
            self.assertEqual(text, "你好")
            return "第一行\n第二行"

        return_code, fields, raw, _output = self.invoke("你好", body, fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "ok")
        self.assertEqual(fields["direction"], "zh-en")
        self.assertEqual(fields["engine"], "tencent")
        self.assertEqual(fields["cached"], "0")
        self.assertEqual(fields["text"], "第一行\n第二行")
        lines = raw.splitlines()
        self.assertEqual(lines[0], "status=ok")
        self.assertEqual(lines[1], "direction=zh-en")
        self.assertEqual(lines[2], "engine=tencent")
        self.assertEqual(lines[3], "cached=0")
        self.assertEqual(lines[4], "text=第一行")
        self.assertEqual(lines[5], "第二行")
        self.assertEqual(len(lines), 6)

        # 第二次命中同一引擎缓存：cached=1，且引擎仍是实际来源。
        with mock.patch.object(
            tr,
            "call_engine",
            side_effect=AssertionError("cache hit must not call engine"),
        ):
            return_code, fields, raw, _output = self.invoke("你好", body)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "ok")
        self.assertEqual(fields["engine"], "tencent")
        self.assertEqual(fields["cached"], "1")
        self.assertEqual(fields["text"], "第一行\n第二行")

    def test_switch_engine_does_not_reuse_other_engine_cache(self) -> None:
        def tencent_fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            self.assertEqual(name, "tencent")
            return "腾讯译"

        return_code, fields, _raw, _output = self.invoke("hello", self.config_body(), tencent_fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["text"], "腾讯译")
        self.assertEqual(fields["engine"], "tencent")

        def google_fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            self.assertEqual(name, "google_gtx")
            return "谷歌译"

        return_code, fields, _raw, _output = self.invoke(
            "hello",
            self.config_body(engine="google_gtx"),
            google_fake,
        )
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["text"], "谷歌译")
        self.assertEqual(fields["engine"], "google_gtx")
        self.assertEqual(fields["cached"], "0")

        with mock.patch.object(
            tr,
            "call_engine",
            side_effect=AssertionError("cache hit must not call engine"),
        ):
            return_code, fields, _raw, _output = self.invoke(
                "hello",
                self.config_body(engine="google_gtx"),
            )
        self.assertEqual(fields["text"], "谷歌译")
        self.assertEqual(fields["engine"], "google_gtx")
        self.assertEqual(fields["cached"], "1")

    def test_same_engine_config_change_does_not_reuse_cache(self) -> None:
        def guangzhou(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            return "广州译"

        _rc, fields, _raw, _output = self.invoke(
            "hello",
            self.config_body(region="ap-guangzhou"),
            guangzhou,
        )
        self.assertEqual(fields["text"], "广州译")

        def shanghai(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            return "上海译"

        _rc, fields, _raw, _output = self.invoke(
            "hello",
            self.config_body(region="ap-shanghai"),
            shanghai,
        )
        self.assertEqual(fields["text"], "上海译")
        self.assertEqual(fields["cached"], "0")

    def test_error_protocol_redacts_source_and_secret(self) -> None:
        source_text = "机密原文"
        body = self.config_body(tencent_id="test-id", tencent_key="test-secret")

        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            secret = settings["tencent"]["secret_key"]
            raise ValueError(
                f"provider boom\nsource={text} secret={secret} Authorization: Bearer {secret}"
            )

        return_code, fields, raw, _output = self.invoke(source_text, body, fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "network")
        self.assertEqual(fields["engine"], "tencent")
        self.assertIn("ValueError", fields["detail"])
        self.assertIn("<text>", fields["detail"])
        self.assertIn("<redacted>", fields["detail"])
        self.assertNotIn("\n", fields["detail"])
        self.assertNotIn(source_text, raw)
        self.assertNotIn("test-secret", raw)
        self.assertNotIn("test-id", raw)
        self.assertNotIn("text", fields)


class ErrorClassificationTests(TranslateTestBase):
    def test_toml_decode_error_is_config(self) -> None:
        body = 'engine = "tencent"\n[tencent\n'
        return_code, fields, raw, _output = self.invoke("hello", body)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "config")
        self.assertEqual(fields["engine"], "tencent")
        self.assertEqual(fields["message"], "配置文件格式无效")
        self.assertIn("ConfigError", fields["detail"])
        self.assertNotIn("hello", raw)

        # 非 UTF-8 的 TOML 也属于配置错误，不是 internal/network。
        bad_utf8 = self.work_dir / "bad-utf8.toml"
        bad_utf8.write_bytes(b'engine = "tencent"\n\xff')
        output = self._next_path("out", ".txt")
        return_code = tr.main(
            [
                "--text",
                "hello",
                "--output-file",
                str(output),
                "--config",
                str(bad_utf8),
            ]
        )
        self.assertEqual(return_code, 0)
        fields = self.parse_output(output.read_text(encoding="utf-8"))
        self.assertEqual(fields["code"], "config")

    def test_invalid_numeric_config_is_config(self) -> None:
        cases = {
            "max_chars string": 'engine = "google_gtx"\nmax_chars = "2000"\n',
            "max_chars zero": 'engine = "google_gtx"\nmax_chars = 0\n',
            "timeout string": 'engine = "google_gtx"\ntimeout_s = "fast"\n',
            "timeout zero": 'engine = "google_gtx"\ntimeout_s = 0\n',
            "timeout negative": 'engine = "google_gtx"\ntimeout_s = -1\n',
            "project id": 'engine = "google_gtx"\n[tencent]\nproject_id = "zero"\n',
            "fallback flag": 'engine = "google_gtx"\nfallback_without_credentials = "false"\n',
        }
        for label, body in cases.items():
            with self.subTest(case=label):
                return_code, fields, _raw, _output = self.invoke("hello", body)
                self.assertEqual(return_code, 0)
                self.assertEqual(fields["status"], "error")
                self.assertEqual(fields["code"], "config")
                self.assertIn("无效", fields["message"])

    def test_free_engine_limit_is_reported_as_too_long(self) -> None:
        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            raise tr.FreeEngineLimitError("免费引擎 mymemory 上限 480 字节，当前 6000 字节")

        body = self.config_body(engine="google_gtx", fallback=True)
        return_code, fields, raw, _output = self.invoke("hello", body, fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "error")
        # 云引擎不可用 + 免费兜底装不下：真实原因是「太长」，不能报 network。
        self.assertEqual(fields["code"], "too_long")
        self.assertIn("480", fields["message"])
        self.assertNotIn("hello", raw)

    def test_free_engine_budget_rejects_before_any_request(self) -> None:
        with self.assertRaises(tr.FreeEngineLimitError):
            tr.translate_mymemory("x" * 600, "en", "zh", 1)
        with self.assertRaises(tr.FreeEngineLimitError):
            tr.translate_google_gtx("长" * 2000, "zh", "en", 1)

    def test_auth_error_is_auth(self) -> None:
        def fake(name: str, text: str, source: str, target: str, timeout: float, settings: dict) -> str:
            raise tr.AuthError("腾讯云密钥无效")

        return_code, fields, raw, _output = self.invoke("hello", self.config_body(), fake)
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["code"], "auth")
        self.assertEqual(fields["message"], "腾讯云密钥无效")
        self.assertIn("AuthError", fields["detail"])
        self.assertNotIn("test-secret", raw)

    def test_timeout_is_timeout(self) -> None:
        errors: list[Exception] = [
            TimeoutError("timed out"),
            urllib.error.URLError(TimeoutError("timed out")),
        ]
        for error in errors:
            with self.subTest(error=type(error).__name__):
                def fake(
                    name: str,
                    text: str,
                    source: str,
                    target: str,
                    timeout: float,
                    settings: dict,
                    exc: Exception = error,
                ) -> str:
                    raise exc

                return_code, fields, _raw, _output = self.invoke(
                    "hello",
                    self.config_body(engine="google_gtx"),
                    fake,
                )
                self.assertEqual(return_code, 0)
                self.assertEqual(fields["code"], "timeout")
                self.assertEqual(fields["message"], "翻译超时")

    def test_network_is_network(self) -> None:
        errors: list[Exception] = [
            urllib.error.URLError("offline"),
            ValueError("FailedOperation.NoFreeAmount free quota exceeded"),
        ]
        for error in errors:
            with self.subTest(error=type(error).__name__):
                def fake(
                    name: str,
                    text: str,
                    source: str,
                    target: str,
                    timeout: float,
                    settings: dict,
                    exc: Exception = error,
                ) -> str:
                    raise exc

                return_code, fields, _raw, _output = self.invoke(
                    "hello",
                    self.config_body(engine="google_gtx"),
                    fake,
                )
                self.assertEqual(return_code, 0)
                self.assertEqual(fields["code"], "network")
                self.assertEqual(fields["message"], "网络请求失败")

    def test_io_read_failure_is_io(self) -> None:
        missing = self.work_dir / "missing-input.txt"
        return_code, fields, _raw, _output = self.invoke(
            "",
            self.config_body(engine="google_gtx"),
            input_file=str(missing),
        )
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "io")
        self.assertEqual(fields["message"], "读取文本失败")
        self.assertIn("FileNotFoundError", fields["detail"])

        bad_utf8 = self.work_dir / "bad-utf8.txt"
        bad_utf8.write_bytes(b"\xff\xfe\x00")
        return_code, fields, _raw, _output = self.invoke(
            "",
            self.config_body(engine="google_gtx"),
            input_file=str(bad_utf8),
        )
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["code"], "io")

    def test_io_read_failure_mocked(self) -> None:
        config_path = self.write_config(self.config_body(engine="google_gtx"))
        input_path = self.work_dir / "exists-input.txt"
        input_path.write_text("hello", encoding="utf-8")
        output = self._next_path("out", ".txt")
        with mock.patch.object(Path, "read_text", side_effect=OSError("disk error")):
            return_code = tr.main(
                [
                    "--input-file",
                    str(input_path),
                    "--output-file",
                    str(output),
                    "--config",
                    str(config_path),
                ]
            )
        self.assertEqual(return_code, 0)
        fields = self.parse_output(output.read_text(encoding="utf-8"))
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "io")
        self.assertEqual(fields["message"], "读取文本失败")
        self.assertIn("OSError", fields["detail"])

    def test_unexpected_exception_outside_translation_is_internal(self) -> None:
        with mock.patch.object(
            tr,
            "detect_direction",
            side_effect=RuntimeError("boom\n机密\n原文"),
        ):
            return_code, fields, raw, _output = self.invoke(
                "机密\n原文",
                self.config_body(engine="google_gtx"),
            )
        self.assertEqual(return_code, 0)
        self.assertEqual(fields["code"], "internal")
        self.assertEqual(fields["message"], "翻译失败")
        self.assertIn("<text>", fields["detail"])
        self.assertNotIn("机密", raw)
        self.assertNotIn("原文", raw)

    def test_sanitize_detail_redacts_multiline_source(self) -> None:
        detail = tr.sanitize_detail(
            ValueError("boom\n机密\n原文\nend"),
            source_text="机密\n原文",
            cfg=None,
        )
        self.assertNotIn("机密", detail)
        self.assertNotIn("原文", detail)
        self.assertIn("<text>", detail)
        self.assertNotIn("\n", detail)

    def test_unexpected_exception_is_internal_and_redacted(self) -> None:
        config_path = self.write_config(self.config_body(engine="google_gtx"))
        output = self._next_path("out", ".txt")
        with mock.patch.object(
            tr,
            "translate_with_cache",
            side_effect=RuntimeError("boom 机密原文"),
        ):
            return_code = tr.main(
                [
                    "--text",
                    "机密原文",
                    "--output-file",
                    str(output),
                    "--config",
                    str(config_path),
                ]
            )
        self.assertEqual(return_code, 0)
        raw = output.read_text(encoding="utf-8")
        fields = self.parse_output(raw)
        self.assertEqual(fields["status"], "error")
        self.assertEqual(fields["code"], "internal")
        self.assertEqual(fields["message"], "翻译失败")
        self.assertIn("RuntimeError", fields["detail"])
        self.assertNotIn("机密原文", raw)

    def test_self_test_runs_offline(self) -> None:
        self.assertEqual(tr.run_self_test(), 0)


if __name__ == "__main__":
    unittest.main()
