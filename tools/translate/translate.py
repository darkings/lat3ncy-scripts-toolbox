#!/usr/bin/env python3
"""划词翻译 one-shot helper。

只使用标准库：判定中英方向、读缓存、请求翻译、把结果写到 --output-file。
AHK 负责选区和光标气泡；本进程平时不驻留。
默认走腾讯云机器翻译 TMT，失败再回退 Google / MyMemory。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import math
import os
import re
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn

sys.path.insert(0, str(Path(__file__).resolve().parent))
import auth_cooldown
import engine_trace
import long_translation as long_text

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from toolbox_preferences import apply_overlay, PreferenceError

ZH_CHAR_PATTERN = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff]")
EN_CHAR_PATTERN = re.compile(r"[A-Za-z]")

# 诊断信息脱敏：密钥键值、URL 里的原文、Authorization/Bearer。
_CREDENTIAL_PATTERN = re.compile(
    r"(?i)\b(secret[_-]?(?:id|key)|access[_-]?key(?:[_-]?(?:id|secret))?"
    r"|credential|authorization|signature|password|token)\b\s*[=:]\s*[^\s,;]+"
)
_SOURCE_QUERY_PATTERN = re.compile(r"(?i)([?&](?:q|sourceText)=)[^&\s]+")
_BEARER_PATTERN = re.compile(r"(?i)\bbearer\s+\S+")

DEFAULT_ENGINE = "tencent"
DEFAULT_MAX_CHARS = 2000
DEFAULT_TIMEOUT_S = 4.0
DEFAULT_CACHE_MAX_SIZE_MB = 10
DEFAULT_CACHE_MAX_FILES = 500
DEFAULT_TENCENT_ENDPOINT = "tmt.tencentcloudapi.com"
DEFAULT_TENCENT_REGION = "ap-guangzhou"
DEFAULT_TENCENT_PROJECT_ID = 0
DEFAULT_ALIYUN_ENDPOINT = "mt.cn-hangzhou.aliyuncs.com"

# 缓存格式版本。旧版是无结构的 .txt 纯文本；现在只认 .json 记录。
CACHE_VERSION = 2
CACHE_SUFFIX = ".json"
LEGACY_CACHE_SUFFIX = ".txt"
DETAIL_MAX_LEN = 200

# 这些环境变量可能包含密钥，诊断信息里出现时必须打码。
CREDENTIAL_ENV_NAMES = (
    "ALIBABA_CLOUD_ACCESS_KEY_ID",
    "ALIBABA_CLOUD_ACCESS_KEY_SECRET",
    "ALIYUN_ACCESS_KEY_ID",
    "ALIYUN_ACCESS_KEY_SECRET",
    "ALIBABA_ACCESS_KEY_ID",
    "ALIBABA_ACCESS_KEY_SECRET",
    "TENCENTCLOUD_SECRET_ID",
    "TENCENTCLOUD_SECRET_KEY",
    "TENCENT_SECRET_ID",
    "TENCENT_SECRET_KEY",
    "QCLOUD_SECRET_ID",
    "QCLOUD_SECRET_KEY",
)

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)

# 引擎别名：配置里写 tmt / ali / google 也能认。
ENGINE_ALIASES = {
    "google": "google_gtx",
    "gtx": "google_gtx",
    "ali": "aliyun",
    "alibaba": "aliyun",
    "alimt": "aliyun",
    "aliyun_mt": "aliyun",
    "tmt": "tencent",
    "qcloud": "tencent",
    "tencentcloud": "tencent",
    "tencent_mt": "tencent",
}
# 首选引擎之外，网络错误只回退这两个免费接口。
# 不把另一家云 MT 塞进默认回退，避免无效密钥把「网络失败」变成鉴权 Toast。
KNOWN_ENGINES = ("tencent", "aliyun", "google_gtx", "mymemory")
FALLBACK_ENGINES = ("google_gtx", "mymemory")
CLOUD_ENGINES = ("tencent", "aliyun")
# 可回退的失败：网络 / 超时 / 配额 / 服务端与响应格式。鉴权需显式配置才回退。
FALLBACK_ERRORS = (
    urllib.error.URLError,
    urllib.error.HTTPError,
    TimeoutError,
    OSError,
    ValueError,
)
# 阿里云鉴权失败：密钥错/签名错，由显式回退策略决定是否使用免费引擎。
ALIYUN_AUTH_MARKERS = (
    "invalidaccesskeyid",
    "signaturedoesnotmatch",
    "incompletesignature",
    "invalidsecuritytoken",
    "forbidden.ram",
    "specified access key",
    "access key id",
    "request signature does not conform",
    "未配置 accesskey",
)
# 腾讯云 TC3 鉴权失败，使用相同的显式回退策略。
TENCENT_AUTH_MARKERS = (
    "authfailure",
    "secretidnotfound",
    "secretidmalformed",
    "signaturefailure",
    "signatureexpire",
    "invalidcredential",
    "unauthorizedoperation",
    "authfailure.tokenfailure",
    "missingsecretid",
    "未配置密钥",
    "secretid",
    "secretkey",
)


class ConfigError(Exception):
    """配置缺失或取值非法。必须报 config，不能伪装成网络错误。"""


class AuthError(ValueError):
    """云厂商密钥或签名无效；默认报错，显式开启后可回退。"""


class FreeEngineLimitError(ValueError):
    """免费回退引擎只走 GET，查询串有硬上限：超长必须报 too_long，不能伪装成网络错误。"""


# 免费回退引擎的 UTF-8 字节上限。超过必然 414 / 查不到，先验比发出去再失败清楚得多。
#   mymemory：q 参数官方上限约 500 字节。
#   google_gtx：GET URL 长度上限，留 4 KB 余量（汉字 3 字节/字）。
FREE_ENGINE_MAX_BYTES = {"google_gtx": 4000, "mymemory": 480}


def free_engine_limit(engine: str) -> int:
    return FREE_ENGINE_MAX_BYTES.get(engine, 0)


def require_free_engine_budget(engine: str, text: str) -> None:
    """超长直接抛 FreeEngineLimitError；调用方会把它归类成 too_long。"""
    limit = free_engine_limit(engine)
    if limit <= 0:
        return
    used = len(text.encode("utf-8"))
    if used > limit:
        raise FreeEngineLimitError(
            f"免费引擎 {engine} 单次上限 {limit} 字节，当前 {used} 字节"
        )


@dataclass(frozen=True)
class Settings:
    """校验后的运行期配置。数值非法时在 load_settings 直接报 ConfigError。"""

    engine: str
    max_chars: int
    timeout_s: float
    max_size_mb: int
    max_files: int
    fallback_without_credentials: bool
    source_language: str = "auto"
    target_language: str = "auto"
    fallback_on_auth_error: bool = False
    long_text_enabled: bool = False


@dataclass(frozen=True)
class TranslationResult:
    """带来源的翻译结果：实际使用的引擎与是否命中缓存。"""

    text: str
    engine: str
    cached: bool
    direction: str
    preferred_engine: str = ""
    fallback_reason: str = ""


def detect_direction(text: str) -> str | None:
    """汉字数 >= 拉丁字母数 → zh-en，否则 en-zh；两边都是 0 则无法判定。"""
    zh = len(ZH_CHAR_PATTERN.findall(text))
    en = len(EN_CHAR_PATTERN.findall(text))
    if zh == 0 and en == 0:
        return None
    return "zh-en" if zh >= en else "en-zh"


def direction_langs(direction: str) -> tuple[str, str]:
    pairs = {"en-zh": ("en", "zh-CN"), "zh-en": ("zh-CN", "en"),
             "en-en": ("en", "en"), "zh-zh": ("zh-CN", "zh-CN")}
    if direction not in pairs:
        raise ConfigError("翻译方向无效")
    return pairs[direction]


def normalize_language(value: object, label: str) -> str:
    """This release supports Chinese/English only; never guess an unknown code."""
    if not isinstance(value, str):
        raise ConfigError(f"配置项 {label} 无效")
    code = value.strip().lower()
    code = {"zh-cn": "zh", "zh-hans": "zh"}.get(code, code)
    if code not in {"auto", "zh", "en"}:
        raise ConfigError(f"配置项 {label} 无效（支持 auto / zh / en）")
    return code


def resolve_direction(text: str, settings: Settings) -> str | None:
    detected = detect_direction(text)
    if detected is None:
        return None
    source = detected.split("-", 1)[0] if settings.source_language == "auto" else settings.source_language
    target = ("en" if source == "zh" else "zh") if settings.target_language == "auto" else settings.target_language
    return f"{source}-{target}"


def _cfg_value(cfg: dict, key: str, default: object) -> object:
    value = cfg.get(key, default)
    return default if value is None else value


def _require_int(value: object, label: str, *, minimum: int = 1) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"配置项 {label} 无效")
    if value < minimum:
        raise ConfigError(f"配置项 {label} 无效")
    return value


def _require_positive_float(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError(f"配置项 {label} 无效")
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise ConfigError(f"配置项 {label} 无效")
    return parsed


def _section_dict(cfg: dict, name: str) -> dict:
    value = cfg.get(name)
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ConfigError(f"配置节 {name} 无效")
    return value


def load_config(config_path: str | None) -> dict:
    cfg: dict = {
        "engine": DEFAULT_ENGINE,
        "source_language": "auto",
        "target_language": "auto",
        "fallback_without_credentials": False,
        "fallback_on_auth_error": False,
        "timeout_s": int(DEFAULT_TIMEOUT_S),
        "max_chars": DEFAULT_MAX_CHARS,
        "cache": {
            "max_size_mb": DEFAULT_CACHE_MAX_SIZE_MB,
            "max_files": DEFAULT_CACHE_MAX_FILES,
        },
        "aliyun": {
            "access_key_id": "",
            "access_key_secret": "",
            "endpoint": DEFAULT_ALIYUN_ENDPOINT,
        },
        "tencent": {
            "secret_id": "",
            "secret_key": "",
            "region": DEFAULT_TENCENT_REGION,
            "endpoint": DEFAULT_TENCENT_ENDPOINT,
            "project_id": DEFAULT_TENCENT_PROJECT_ID,
        },
    }
    path = Path(config_path) if config_path else Path(__file__).with_name("config.toml")
    if not path.is_file():
        return _apply_preferences(cfg, path)
    try:
        with path.open("rb") as handle:
            loaded = tomllib.load(handle)
    except (tomllib.TOMLDecodeError, UnicodeError) as exc:
        # 配置语法/编码错误必须报 config；不能落到 main 的 network 兜底。
        raise ConfigError("配置文件格式无效") from exc
    except OSError:
        # 文件读不了时保持旧行为：忽略并使用默认值。
        return _apply_preferences(cfg, path)
    if not isinstance(loaded, dict):
        raise ConfigError("配置文件格式无效")
    defaults = {name: dict(cfg[name]) for name in ("cache", "aliyun", "tencent")}
    cfg.update(loaded)
    for name, default in defaults.items():
        value = cfg.get(name)
        if not isinstance(value, dict):
            raise ConfigError(f"配置节 {name} 无效")
        merged = dict(default)
        merged.update(value)
        cfg[name] = merged
    return _apply_preferences(cfg, path)


def _apply_preferences(cfg: dict, path: Path) -> dict:
    try:
        return apply_overlay("translate", cfg, path)
    except (PreferenceError, OSError) as exc:
        raise ConfigError("本地偏好设置无效或无法读取") from exc


def load_settings(cfg: dict) -> Settings:
    """校验并归一化数值及中英语言策略；非法值直接抛 ConfigError。"""
    raw_engine = _cfg_value(cfg, "engine", DEFAULT_ENGINE)
    if not isinstance(raw_engine, str):
        raise ConfigError("配置项 engine 无效")
    max_chars = _require_int(
        _cfg_value(cfg, "max_chars", DEFAULT_MAX_CHARS),
        "max_chars",
        minimum=1,
    )
    timeout_s = _require_positive_float(
        _cfg_value(cfg, "timeout_s", DEFAULT_TIMEOUT_S),
        "timeout_s",
    )
    cache_section = _section_dict(cfg, "cache")
    max_size_mb = _require_int(
        _cfg_value(cache_section, "max_size_mb", DEFAULT_CACHE_MAX_SIZE_MB),
        "cache.max_size_mb",
        minimum=0,
    )
    max_files = _require_int(
        _cfg_value(cache_section, "max_files", DEFAULT_CACHE_MAX_FILES),
        "cache.max_files",
        minimum=0,
    )
    fallback_raw = _cfg_value(cfg, "fallback_without_credentials", False)
    if not isinstance(fallback_raw, bool):
        raise ConfigError("配置项 fallback_without_credentials 无效")
    auth_fallback = _cfg_value(cfg, "fallback_on_auth_error", False)
    if not isinstance(auth_fallback, bool):
        raise ConfigError("配置项 fallback_on_auth_error 无效")
    long_enabled = _cfg_value(cfg, "long_text_enabled", False)
    if not isinstance(long_enabled, bool):
        raise ConfigError("配置项 long_text_enabled 无效")
    tencent_section = _section_dict(cfg, "tencent")
    _require_int(
        _cfg_value(tencent_section, "project_id", DEFAULT_TENCENT_PROJECT_ID),
        "tencent.project_id",
        minimum=0,
    )
    _section_dict(cfg, "aliyun")
    return Settings(
        engine=normalize_engine(raw_engine),
        max_chars=max_chars,
        timeout_s=timeout_s,
        max_size_mb=max_size_mb,
        max_files=max_files,
        fallback_without_credentials=fallback_raw,
        source_language=normalize_language(_cfg_value(cfg, "source_language", "auto"), "source_language"),
        target_language=normalize_language(_cfg_value(cfg, "target_language", "auto"), "target_language"),
        fallback_on_auth_error=auth_fallback,
        long_text_enabled=long_enabled,
    )


def text_is_too_long(text: str, max_chars: int) -> bool:
    """边界严格：len == max_chars 可以翻，len == max_chars + 1 就报错。"""
    return len(text) > max_chars


def cache_dir() -> Path:
    root = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
    path = Path(root) / "lat3ncy-toolbox" / "translate-cache"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _section(cfg: dict | None, name: str) -> dict:
    if not isinstance(cfg, dict):
        return {}
    value = cfg.get(name)
    return value if isinstance(value, dict) else {}


def _clean_endpoint(value: object, default: str) -> str:
    """统一成真正生效的 host，避免 scheme/trailing slash 制造重复缓存键。"""
    host = str(value or default).strip()
    host = host.replace("https://", "").replace("http://", "").strip("/")
    return host or default


def cache_scope(engine: str, cfg: dict | None = None) -> dict[str, object]:
    """参与缓存键、且会影响该引擎输出的配置字段。"""
    name = normalize_engine(engine)
    if name == "tencent":
        section = _section(cfg, "tencent")
        project_id: object = section.get("project_id", DEFAULT_TENCENT_PROJECT_ID)
        if project_id is None:
            project_id = DEFAULT_TENCENT_PROJECT_ID
        if isinstance(project_id, bool) or not isinstance(project_id, int):
            project_id = str(project_id)
        return {
            "endpoint": _clean_endpoint(section.get("endpoint"), DEFAULT_TENCENT_ENDPOINT),
            "region": str(section.get("region") or DEFAULT_TENCENT_REGION).strip()
            or DEFAULT_TENCENT_REGION,
            "project_id": project_id,
        }
    if name == "aliyun":
        return {
            "endpoint": _clean_endpoint(
                _section(cfg, "aliyun").get("endpoint"),
                DEFAULT_ALIYUN_ENDPOINT,
            )
        }
    # 免费引擎没有影响输出的配置。
    return {}


def cache_key(
    engine: str,
    direction: str,
    text: str,
    cfg: dict | None = None,
) -> str:
    payload = json.dumps(
        {
            "version": CACHE_VERSION,
            "engine": normalize_engine(engine),
            "direction": direction,
            "text": text,
            "scope": cache_scope(engine, cfg),
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _cache_record(engine: str, direction: str, translated: str) -> dict[str, object]:
    return {
        "version": CACHE_VERSION,
        "engine": normalize_engine(engine),
        "direction": direction,
        "translated": translated,
    }


def _cache_record_valid(record: object, engine: str, direction: str) -> bool:
    if not isinstance(record, dict):
        return False
    if record.get("version") != CACHE_VERSION:
        return False
    if record.get("engine") != normalize_engine(engine):
        return False
    stored_direction = record.get("direction", direction)
    if stored_direction != direction:
        return False
    translated = record.get("translated")
    return isinstance(translated, str) and bool(translated.strip())


def cache_get(
    engine: str,
    direction: str,
    text: str,
    cfg: dict | None = None,
) -> str | None:
    """只读新格式 .json；旧 .txt 与损坏记录一律当作未命中。"""
    try:
        folder = Path(cache_dir())
    except OSError:
        return None
    path = folder / f"{cache_key(engine, direction, text, cfg)}{CACHE_SUFFIX}"
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    try:
        record = json.loads(raw)
    except ValueError:
        return None
    if not _cache_record_valid(record, engine, direction):
        return None
    translated = record.get("translated") if isinstance(record, dict) else None
    if not isinstance(translated, str):
        return None
    try:
        os.utime(path, None)
    except OSError:
        pass
    return translated


def cache_put(
    engine: str,
    direction: str,
    text: str,
    translated: str,
    cfg: dict | None = None,
) -> None:
    """同目录临时文件 + os.replace 原子落盘，读者永远看不到半个文件。"""
    name = normalize_engine(engine)
    try:
        folder = Path(cache_dir())
    except OSError:
        return
    path = folder / f"{cache_key(name, direction, text, cfg)}{CACHE_SUFFIX}"
    try:
        payload = json.dumps(
            _cache_record(name, direction, translated),
            ensure_ascii=False,
            separators=(",", ":"),
        )
    except (TypeError, ValueError):
        return
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}.{uuid.uuid4().hex}")
    try:
        tmp.write_text(payload, encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def prune_cache(max_size_mb: int = 10, max_files: int = 500) -> None:
    try:
        folder = Path(cache_dir())
    except OSError:
        return
    try:
        entries: list[tuple[float, int, Path]] = []
        total = 0
        for item in folder.iterdir():
            # 顺带清理旧版 .txt 纯文本缓存；临时文件后缀不同，不受影响。
            if not item.is_file() or item.suffix not in (CACHE_SUFFIX, LEGACY_CACHE_SUFFIX):
                continue
            stat = item.stat()
            total += stat.st_size
            entries.append((stat.st_atime, stat.st_size, item))
        max_bytes = max_size_mb * 1024 * 1024
        if total <= max_bytes and len(entries) <= max_files:
            return
        entries.sort(key=lambda row: row[0])
        target_bytes = int(max_bytes * 0.85)
        target_files = int(max_files * 0.85)
        remaining = len(entries)
        for _atime, size, path in entries:
            if total <= target_bytes and remaining <= target_files:
                break
            try:
                path.unlink()
                total -= size
                remaining -= 1
            except OSError:
                pass
    except OSError:
        pass


def http_json(
    url: str,
    timeout: float,
    *,
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
    method: str = "GET",
) -> object:
    """GET/POST JSON。HTTP 错误体也尝试当 JSON 读，方便解析云厂商 Message。"""
    hdrs = {"User-Agent": USER_AGENT}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        message = f"HTTP {exc.code}"
        if raw:
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, dict):
                code = str(parsed.get("Code") or parsed.get("code") or "").strip()
                detail = str(
                    parsed.get("Message") or parsed.get("message") or ""
                ).strip()
                # 腾讯云错误在 Response.Error 里，HTTP 4xx 时也尽量抽出。
                response = parsed.get("Response")
                if isinstance(response, dict):
                    error = response.get("Error")
                    if isinstance(error, dict):
                        code = str(error.get("Code") or code).strip()
                        detail = str(error.get("Message") or detail).strip()
                combined = " ".join(part for part in (code, detail) if part)
                if combined:
                    message = combined
        raise ValueError(message) from exc
    return json.loads(raw)


def http_get_json(url: str, timeout: float) -> object:
    return http_json(url, timeout)


def translate_google_gtx(text: str, source: str, target: str, timeout: float) -> str:
    require_free_engine_budget("google_gtx", text)
    query = urllib.parse.urlencode(
        {
            "client": "gtx",
            "sl": source,
            "tl": target,
            "dt": "t",
            "q": text,
        }
    )
    url = "https://translate.googleapis.com/translate_a/single?" + query
    data = http_get_json(url, timeout)
    if not isinstance(data, list) or not data or not isinstance(data[0], list):
        raise ValueError("google_gtx 返回格式无效")
    parts: list[str] = []
    for item in data[0]:
        if isinstance(item, list) and item and isinstance(item[0], str):
            parts.append(item[0])
    translated = "".join(parts).strip()
    if not translated:
        raise ValueError("google_gtx 返回空译文")
    return translated


def translate_mymemory(text: str, source: str, target: str, timeout: float) -> str:
    require_free_engine_budget("mymemory", text)
    pair_source = "zh-CN" if source.lower().startswith("zh") else source
    pair_target = "zh-CN" if target.lower().startswith("zh") else target
    query = urllib.parse.urlencode(
        {
            "q": text,
            "langpair": f"{pair_source}|{pair_target}",
        }
    )
    url = "https://api.mymemory.translated.net/get?" + query
    data = http_get_json(url, timeout)
    if not isinstance(data, dict):
        raise ValueError("mymemory 返回格式无效")
    status_text = str(data.get("responseStatus") or "").strip()
    details_text = str(data.get("responseDetails") or "").strip()
    try:
        status_code = int(status_text) if status_text else 200
    except ValueError:
        status_code = 200
    if status_code != 200:
        # MyMemory 用 HTTP 200 + responseStatus != 200 表达「超长 / 超额 / 无配额」，
        # 此时 responseData.translatedText 里放的是一句错误说明。当成译文返回会被
        # translate_with_cache 写进缓存，之后每次都命中这句错误。
        raise ValueError(details_text or f"mymemory responseStatus={status_text}")
    payload = data.get("responseData")
    if not isinstance(payload, dict):
        raise ValueError("mymemory 缺少 responseData")
    translated = str(payload.get("translatedText") or "").strip()
    if not translated:
        raise ValueError("mymemory 返回空译文")
    if translated.upper().startswith("MYMEMORY WARNING"):
        raise ValueError(translated)
    return translated


def is_aliyun_auth_error(code: str = "", message: str = "") -> bool:
    blob = f"{code} {message}".strip().lower()
    if not blob:
        return False
    return any(marker in blob for marker in ALIYUN_AUTH_MARKERS)


def is_tencent_auth_error(code: str = "", message: str = "") -> bool:
    blob = f"{code} {message}".strip().lower()
    if not blob:
        return False
    return any(marker in blob for marker in TENCENT_AUTH_MARKERS)


def raise_aliyun_error(code: str, message: str) -> NoReturn:
    text = (message or code or "aliyun 请求失败").strip()
    if is_aliyun_auth_error(code, text):
        raise AuthError("阿里云密钥无效")
    raise ValueError(text)


def raise_tencent_error(code: str, message: str) -> NoReturn:
    text = (message or code or "tencent 请求失败").strip()
    if is_tencent_auth_error(code, text):
        raise AuthError("腾讯云密钥无效")
    raise ValueError(text)


def aliyun_lang(code: str) -> str:
    """阿里云通用翻译只要 zh / en，不要 zh-CN。"""
    lowered = code.strip().lower()
    if lowered.startswith("zh"):
        return "zh"
    return "en"


def tencent_lang(code: str) -> str:
    """腾讯云 TMT 只要 zh / en，不要 zh-CN。"""
    lowered = code.strip().lower()
    if lowered.startswith("zh"):
        return "zh"
    return "en"


def aliyun_percent_encode(value: str) -> str:
    """阿里云 RPC 签名用的百分号编码：空格=%20，*=%2A，~ 不编码。"""
    return (
        urllib.parse.quote(str(value), safe="-_.~")
        .replace("+", "%20")
        .replace("*", "%2A")
        .replace("%7E", "~")
    )


def aliyun_sign(secret: str, method: str, params: dict[str, str]) -> str:
    """HMAC-SHA1 RPC 签名。密钥侧固定追加 &。"""
    items = sorted((key, val) for key, val in params.items() if key != "Signature")
    canonical = "&".join(
        f"{aliyun_percent_encode(key)}={aliyun_percent_encode(val)}" for key, val in items
    )
    string_to_sign = (
        method.upper()
        + "&"
        + aliyun_percent_encode("/")
        + "&"
        + aliyun_percent_encode(canonical)
    )
    digest = hmac.new(
        (secret + "&").encode("utf-8"),
        string_to_sign.encode("utf-8"),
        hashlib.sha1,
    ).digest()
    return base64.b64encode(digest).decode("ascii")


def tencent_tc3_headers(
    secret_id: str,
    secret_key: str,
    *,
    service: str,
    host: str,
    action: str,
    version: str,
    region: str,
    payload: str,
    timestamp: int | None = None,
) -> dict[str, str]:
    """构造腾讯云 TC3-HMAC-SHA256 请求头。payload 必须与 POST 正文完全一致。"""
    ts = int(time.time()) if timestamp is None else int(timestamp)
    date = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")
    content_type = "application/json; charset=utf-8"
    # 规范头要求小写、按 ASCII 排序：content-type、host、x-tc-action。
    canonical_headers = (
        f"content-type:{content_type}\n"
        f"host:{host}\n"
        f"x-tc-action:{action.lower()}\n"
    )
    signed_headers = "content-type;host;x-tc-action"
    hashed_payload = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    canonical_request = (
        "POST\n"
        "/\n"
        "\n"
        f"{canonical_headers}\n"
        f"{signed_headers}\n"
        f"{hashed_payload}"
    )
    algorithm = "TC3-HMAC-SHA256"
    credential_scope = f"{date}/{service}/tc3_request"
    hashed_canonical = hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    string_to_sign = f"{algorithm}\n{ts}\n{credential_scope}\n{hashed_canonical}"
    secret_date = hmac.new(
        ("TC3" + secret_key).encode("utf-8"),
        date.encode("utf-8"),
        hashlib.sha256,
    ).digest()
    secret_service = hmac.new(secret_date, service.encode("utf-8"), hashlib.sha256).digest()
    secret_signing = hmac.new(secret_service, b"tc3_request", hashlib.sha256).digest()
    signature = hmac.new(
        secret_signing,
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    authorization = (
        f"{algorithm} Credential={secret_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    return {
        "Authorization": authorization,
        "Content-Type": content_type,
        "Host": host,
        "X-TC-Action": action,
        "X-TC-Timestamp": str(ts),
        "X-TC-Version": version,
        "X-TC-Region": region,
    }


def _first_nonempty(*values: object) -> str:
    """返回第一个非空字符串；用于环境变量优先、配置文件兜底。"""
    for value in values:
        cleaned = str(value or "").strip()
        if cleaned:
            return cleaned
    return ""


def read_user_env(name: str) -> str:
    """读当前用户环境变量。

    AHK 常驻进程可能仍是登录时的旧环境；翻译 helper 每次启动时
    直接读 HKCU\\Environment，避免必须重启 AHK 才能拿到新密钥。
    """
    if sys.platform != "win32":
        return ""
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            value, _ = winreg.QueryValueEx(key, name)
        return str(value or "").strip()
    except OSError:
        return ""


def env_lookup(name: str) -> str:
    """进程环境优先，没有再读用户环境。不把值写进日志。"""
    return _first_nonempty(os.environ.get(name), read_user_env(name))


def resolve_aliyun_keys(cfg: dict) -> tuple[str, str]:
    """环境变量优先，未设置时才读配置文件。不把密钥写进日志。"""
    section = cfg.get("aliyun", {}) if isinstance(cfg.get("aliyun"), dict) else {}
    # 官方 SDK 名优先，再兼容 ALIYUN_* / ALIBABA_*；最后才用 config.toml。
    key_id = _first_nonempty(
        env_lookup("ALIBABA_CLOUD_ACCESS_KEY_ID"),
        env_lookup("ALIYUN_ACCESS_KEY_ID"),
        env_lookup("ALIBABA_ACCESS_KEY_ID"),
        section.get("access_key_id"),
    )
    key_secret = _first_nonempty(
        env_lookup("ALIBABA_CLOUD_ACCESS_KEY_SECRET"),
        env_lookup("ALIYUN_ACCESS_KEY_SECRET"),
        env_lookup("ALIBABA_ACCESS_KEY_SECRET"),
        section.get("access_key_secret"),
    )
    return key_id, key_secret


def resolve_tencent_keys(cfg: dict) -> tuple[str, str]:
    """腾讯云密钥：进程环境 → 用户环境 → config.toml。"""
    section = cfg.get("tencent", {}) if isinstance(cfg.get("tencent"), dict) else {}
    secret_id = _first_nonempty(
        env_lookup("TENCENTCLOUD_SECRET_ID"),
        env_lookup("TENCENT_SECRET_ID"),
        env_lookup("QCLOUD_SECRET_ID"),
        section.get("secret_id"),
    )
    secret_key = _first_nonempty(
        env_lookup("TENCENTCLOUD_SECRET_KEY"),
        env_lookup("TENCENT_SECRET_KEY"),
        env_lookup("QCLOUD_SECRET_KEY"),
        section.get("secret_key"),
    )
    return secret_id, secret_key


def normalize_engine(engine: str) -> str:
    preferred = (engine or "tencent").strip().lower()
    preferred = ENGINE_ALIASES.get(preferred, preferred)
    if preferred not in KNOWN_ENGINES:
        return "tencent"
    return preferred


def _has_credentials(engine: str, cfg: dict) -> bool:
    if engine == "aliyun":
        key_id, key_secret = resolve_aliyun_keys(cfg)
        return bool(key_id and key_secret)
    if engine == "tencent":
        secret_id, secret_key = resolve_tencent_keys(cfg)
        return bool(secret_id and secret_key)
    return True


def _missing_credentials_message(engine: str) -> str:
    if engine == "aliyun":
        return "未配置阿里云 AccessKey"
    return "未配置腾讯云密钥"


def _fallback_allowed(cfg: dict) -> bool:
    # 只有显式写 true 才允许「没密钥也走免费接口」。
    return cfg.get("fallback_without_credentials", False) is True


def engine_order(preferred: str, cfg: dict) -> list[str]:
    """首选在前；云引擎缺密钥时默认报配置错误，只有显式 opt-in 才回退。

    鉴权失败（AuthError）由 translate_with_cache 按显式开关处理；
    网络 / 超时 / 配额错误才继续走 google_gtx -> mymemory。
    """
    name = normalize_engine(preferred)
    if name in CLOUD_ENGINES:
        if not _has_credentials(name, cfg):
            if not _fallback_allowed(cfg):
                raise ConfigError(_missing_credentials_message(name))
            return list(FALLBACK_ENGINES)
        return [name, *FALLBACK_ENGINES]
    return [name, *[item for item in FALLBACK_ENGINES if item != name]]


def translate_aliyun(
    text: str,
    source: str,
    target: str,
    timeout: float,
    cfg: dict,
) -> str:
    """阿里云机器翻译 TranslateGeneral。POST，避免长文本撑爆 URL。"""
    key_id, key_secret = resolve_aliyun_keys(cfg)
    if not key_id or not key_secret:
        raise AuthError("阿里云未配置 AccessKey")
    section = cfg.get("aliyun", {}) if isinstance(cfg.get("aliyun"), dict) else {}
    endpoint = _clean_endpoint(section.get("endpoint"), DEFAULT_ALIYUN_ENDPOINT)
    params = {
        "Format": "JSON",
        "Version": "2018-10-12",
        "AccessKeyId": key_id,
        "SignatureMethod": "HMAC-SHA1",
        "Timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "SignatureVersion": "1.0",
        "SignatureNonce": uuid.uuid4().hex,
        "Action": "TranslateGeneral",
        "FormatType": "text",
        "SourceLanguage": aliyun_lang(source),
        "TargetLanguage": aliyun_lang(target),
        "SourceText": text,
        "Scene": "general",
    }
    params["Signature"] = aliyun_sign(key_secret, "POST", params)
    body = urllib.parse.urlencode(params).encode("utf-8")
    try:
        data = http_json(
            f"https://{endpoint}/",
            timeout,
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
    except ValueError as exc:
        raise_aliyun_error("", str(exc))
    if not isinstance(data, dict):
        raise ValueError("aliyun 返回格式无效")
    code = str(data.get("Code") or "").strip()
    if code and code not in {"200", "OK", "ok"}:
        raise_aliyun_error(code, str(data.get("Message") or code))
    payload = data.get("Data")
    if not isinstance(payload, dict):
        raise ValueError("aliyun 缺少 Data")
    translated = str(payload.get("Translated") or "").strip()
    if not translated:
        raise ValueError("aliyun 返回空译文")
    return translated


def translate_tencent(
    text: str,
    source: str,
    target: str,
    timeout: float,
    cfg: dict,
) -> str:
    """腾讯云机器翻译 TextTranslate。TC3 签名 + JSON POST。"""
    secret_id, secret_key = resolve_tencent_keys(cfg)
    if not secret_id or not secret_key:
        raise AuthError("腾讯云未配置密钥")
    section = cfg.get("tencent", {}) if isinstance(cfg.get("tencent"), dict) else {}
    host = _clean_endpoint(section.get("endpoint"), DEFAULT_TENCENT_ENDPOINT)
    region = str(section.get("region") or DEFAULT_TENCENT_REGION).strip()
    region = region or DEFAULT_TENCENT_REGION
    # 不静默夹紧：非法 project_id 属于配置错误。
    project_id = _require_int(
        _cfg_value(section, "project_id", DEFAULT_TENCENT_PROJECT_ID),
        "tencent.project_id",
        minimum=0,
    )
    # separators 固定，保证签名哈希的正文和实际发送的正文一致。
    payload = json.dumps(
        {
            "SourceText": text,
            "Source": tencent_lang(source),
            "Target": tencent_lang(target),
            "ProjectId": project_id,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
    headers = tencent_tc3_headers(
        secret_id,
        secret_key,
        service="tmt",
        host=host,
        action="TextTranslate",
        version="2018-03-21",
        region=region,
        payload=payload,
    )
    try:
        data = http_json(
            f"https://{host}/",
            timeout,
            data=payload.encode("utf-8"),
            headers=headers,
            method="POST",
        )
    except ValueError as exc:
        raise_tencent_error("", str(exc))
    if not isinstance(data, dict):
        raise ValueError("tencent 返回格式无效")
    response = data.get("Response")
    if not isinstance(response, dict):
        raise ValueError("tencent 缺少 Response")
    error = response.get("Error")
    if isinstance(error, dict):
        raise_tencent_error(
            str(error.get("Code") or ""),
            str(error.get("Message") or ""),
        )
    translated = str(response.get("TargetText") or "").strip()
    if not translated:
        raise ValueError("tencent 返回空译文")
    return translated


def call_engine(
    name: str,
    text: str,
    source: str,
    target: str,
    timeout: float,
    cfg: dict,
) -> str:
    """单引擎调用。测试与自测只替换这个函数即可完全断网。"""
    if name == "tencent":
        return translate_tencent(text, source, target, timeout, cfg)
    if name == "aliyun":
        return translate_aliyun(text, source, target, timeout, cfg)
    if name == "google_gtx":
        return translate_google_gtx(text, source, target, timeout)
    if name == "mymemory":
        return translate_mymemory(text, source, target, timeout)
    raise ValueError(f"未知翻译引擎：{name}")


def _request_engine(name: str, text: str, source: str, target: str, timeout: float, cfg: dict) -> str:
    if "_long_deadline" not in cfg:
        return call_engine(name, text, source, target, timeout, cfg)
    limit = free_engine_limit(name)
    pieces = long_text.split_segments(text, max_chars=len(text) or 1, max_bytes=limit) if limit and len(text.encode("utf-8")) > limit else [text]
    results = []
    for piece in pieces:
        remaining = cfg["_long_deadline"] - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("translation_budget_exhausted")
        if not piece.strip():
            value = piece
        else:
            value = call_engine(name, piece, source, target, min(timeout, remaining), cfg)
            if not value.strip():
                raise ValueError("empty_translation")
        results.append({"text": value})
    return long_text.join_results(pieces, results, hard_separator=" " if target == "en" and source != target else "")


def _record_engine(cfg: dict, name: str, outcome: str, *, elapsed_ms: int = 0, kind: str = 'none') -> None:
    trace = cfg.get('_engine_trace')
    if isinstance(trace, engine_trace.EngineTrace):
        trace.record(name, outcome, elapsed_ms=elapsed_ms, kind=kind)


def translate_with_cache(
    engine: str,
    text: str,
    direction: str,
    timeout: float,
    cfg: dict | None = None,
) -> TranslationResult:
    """按引擎计划翻译，缓存始终按实际引擎隔离。

    缓存读取规则：计划里的第一个引擎先查缓存；后续回退引擎只在前面
    真的失败后才查自己的缓存，避免免费引擎的旧缓存遮住可用的付费引擎。
    """
    settings = cfg if cfg is not None else {}
    source, target = direction_langs(direction)
    # A fixed target can already match the input. Do not contact a provider or
    # read credentials/cache merely to return the same text.
    if source == target:
        return TranslationResult(text=text, engine="identity", cached=False, direction=direction)
    engines = engine_order(engine, settings)
    preferred = normalize_engine(engine)
    reason = "credentials" if engines[0] != preferred else ""
    if reason:
        _record_engine(settings, preferred, 'skipped', kind='credentials')

    cooldown_path = None
    cooldown_identity = ""
    if preferred == "tencent" and settings.get("fallback_on_auth_error") is True and preferred in engines:
        cooldown_identity = auth_cooldown.identity(resolve_tencent_keys(settings), _section_dict(settings, "tencent"))
        try:
            cooldown_path = auth_cooldown.state_path(cache_dir())
        except OSError:
            pass

    last_error: Exception | None = None
    for name in engines:
        cached = cache_get(name, direction, text, settings)
        if cached is not None:
            _record_engine(settings, name, 'cached')
            return TranslationResult(
                text=cached,
                engine=name,
                cached=True,
                direction=direction,
                preferred_engine=preferred,
                fallback_reason=reason,
            )
        started = time.monotonic()
        try:
            if name == "tencent" and cooldown_path is not None and auth_cooldown.active(cooldown_path, cooldown_identity):
                reason = "auth"
                _record_engine(settings, name, 'skipped', kind='cooldown')
                continue
            translated = _request_engine(name, text, source, target, timeout, settings)
        except AuthError as exc:
            _record_engine(settings, name, 'failed', elapsed_ms=round((time.monotonic() - started) * 1000), kind='auth')
            if settings.get("fallback_on_auth_error", False) is not True:
                raise
            last_error = exc
            if name == "tencent" and cooldown_path is not None:
                auth_cooldown.record_failure(cooldown_path, cooldown_identity)
            reason = reason or "auth"
            continue
        except FALLBACK_ERRORS as exc:
            kind = 'timeout' if _is_timeout(exc) else 'too_long' if isinstance(exc, FreeEngineLimitError) else engine_trace.failure_kind(exc)
            _record_engine(settings, name, 'failed', elapsed_ms=round((time.monotonic() - started) * 1000), kind=kind)
            last_error = exc
            reason = reason or ("timeout" if _is_timeout(exc) else "too_long" if isinstance(exc, FreeEngineLimitError) else "network")
            continue
        except Exception:
            _record_engine(settings, name, 'failed', elapsed_ms=round((time.monotonic() - started) * 1000), kind='internal')
            raise
        if not translated.strip():
            _record_engine(settings, name, 'failed', elapsed_ms=round((time.monotonic() - started) * 1000), kind='response')
            last_error = ValueError(f"{name} 返回空译文")
            reason = reason or "network"
            continue
        _record_engine(settings, name, 'ok', elapsed_ms=round((time.monotonic() - started) * 1000))
        cache_put(name, direction, text, translated, settings)
        if name == "tencent" and cooldown_path is not None:
            auth_cooldown.clear(cooldown_path, cooldown_identity)
        return TranslationResult(
            text=translated,
            engine=name,
            cached=False,
            direction=direction,
            preferred_engine=preferred,
            fallback_reason=reason,
        )
    if last_error is not None:
        raise last_error
    raise ConfigError("没有可用的翻译引擎")


def translate_text(
    engine: str,
    text: str,
    direction: str,
    timeout: float,
    cfg: dict | None = None,
) -> str:
    """兼容旧调用：只要译文，不关心来源引擎和缓存状态。"""
    return translate_with_cache(engine, text, direction, timeout, cfg).text


def _single_line(value: str) -> str:
    return value.replace("\r", " ").replace("\n", " ")


def write_output(path: str, status: str, **fields: str) -> None:
    """key=value 协议；text 永远最后，其它字段强制单行。"""
    lines = [f"status={_single_line(status)}"]
    body: str | None = None
    for key, value in fields.items():
        if key == "text":
            body = value.replace("\r\n", "\n").replace("\r", "\n")
            continue
        lines.append(f"{key}={_single_line(value)}")
    if body is not None:
        lines.append("text=" + body)
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def _credential_values(cfg: dict | None) -> list[str]:
    values: list[str] = []
    for section_name, keys in (
        ("tencent", ("secret_id", "secret_key")),
        ("aliyun", ("access_key_id", "access_key_secret")),
    ):
        section = _section(cfg, section_name)
        for key in keys:
            value = section.get(key)
            if isinstance(value, str) and value.strip():
                values.append(value.strip())
    # 只读进程环境，不读 HKCU；避免错误路径再触发环境读取。
    for name in CREDENTIAL_ENV_NAMES:
        value = os.environ.get(name, "").strip()
        if value:
            values.append(value)
    return values


def _source_variants(source_text: str) -> list[str]:
    """原文可能以 LF/CRLF、URL 编码或折成单行的形式出现在异常里。"""
    variants = {
        source_text,
        source_text.replace("\r\n", "\n").replace("\r", "\n"),
        " ".join(source_text.split()),
        urllib.parse.quote(source_text, safe=""),
        urllib.parse.quote_plus(source_text),
    }
    return sorted((item for item in variants if item), key=len, reverse=True)


def sanitize_detail(
    exc: BaseException,
    *,
    source_text: str = "",
    cfg: dict | None = None,
) -> str:
    """异常类型 + 截断消息，单行；原文和密钥一律打码。"""
    raw = f"{type(exc).__name__}: {exc}"
    for secret in _credential_values(cfg):
        if secret:
            raw = raw.replace(secret, "<redacted>")
    # 必须在压成单行之前替换，否则多行原文会变成 "line1 line2" 而漏网。
    for variant in _source_variants(source_text):
        raw = raw.replace(variant, "<text>")
    detail = " ".join(raw.split())
    # Bearer 先处理，否则 Authorization 规则会只吃掉 "Bearer" 留下 token。
    detail = _BEARER_PATTERN.sub("Bearer <redacted>", detail)
    detail = _CREDENTIAL_PATTERN.sub(r"\1=<redacted>", detail)
    detail = _SOURCE_QUERY_PATTERN.sub(r"\1<redacted>", detail)
    if not detail:
        detail = type(exc).__name__
    return detail[:DETAIL_MAX_LEN]


def _is_timeout(exc: BaseException) -> bool:
    if isinstance(exc, TimeoutError):
        return True
    if isinstance(exc, urllib.error.URLError):
        reason = exc.reason
        return isinstance(reason, TimeoutError) or "timed out" in str(reason).lower()
    return False


def _engine_label(cfg: dict | None) -> str:
    if not isinstance(cfg, dict):
        return DEFAULT_ENGINE
    raw = cfg.get("engine", DEFAULT_ENGINE)
    if isinstance(raw, str) and raw.strip():
        return normalize_engine(raw)
    return DEFAULT_ENGINE


def write_error(
    path: str,
    code: str,
    message: str,
    engine: str,
    detail: str = "",
    **extra: str,
) -> int:
    """写错误协议并返回进程码；写不了文件只能返回 1。"""
    try:
        write_output(
            path,
            "error",
            code=code,
            message=message,
            engine=engine,
            detail=detail,
            **extra,
        )
    except OSError:
        return 1
    return 0


def run_self_test() -> int:
    """离线自测：不联网、不读 HKCU、不写真实缓存。"""
    failed = 0

    def check(condition: bool, message: str) -> None:
        nonlocal failed
        if not condition:
            print(f"FAIL {message}", file=sys.stderr)
            failed += 1

    cases = [
        ("你好", "zh-en"),
        ("Hello world", "en-zh"),
        # 4 个汉字 vs 7 个字母 → 英文多数派
        ("今天使用 Windows", "en-zh"),
        # 6 个汉字 vs 5 个字母 → 中文多数派
        ("这是一段中文 Hello", "zh-en"),
        ("Windows 你好", "en-zh"),
        ("12345", None),
        ("   ", None),
        ("!@#$%", None),
    ]
    for text, expected in cases:
        actual = detect_direction(text)
        check(actual == expected, f"detect {text!r}: expected {expected!r} got {actual!r}")
    source, target = direction_langs("zh-en")
    check(source == "zh-CN" and target == "en", f"langs zh-en: {source} {target}")
    source, target = direction_langs("en-zh")
    check(source == "en" and target == "zh-CN", f"langs en-zh: {source} {target}")
    check(aliyun_lang("zh-CN") == "zh" and aliyun_lang("en") == "en", "aliyun_lang")
    check(tencent_lang("zh-CN") == "zh" and tencent_lang("en") == "en", "tencent_lang")
    encoded = aliyun_percent_encode("a b*c~d")
    check(encoded == "a%20b%2Ac~d", f"aliyun_percent_encode: {encoded}")

    # 截断边界：等于上限可以翻，多一个字就必须报 too_long。
    check(not text_is_too_long("abcde", 5), "text_is_too_long len == max")
    check(text_is_too_long("abcdef", 5), "text_is_too_long len == max + 1")

    # 非法数值配置必须是 ConfigError，不能静默夹紧。
    for bad in (
        {"max_chars": "2000"},
        {"max_chars": 0},
        {"timeout_s": "fast"},
        {"timeout_s": 0},
        {"tencent": {"project_id": "zero"}},
        {"fallback_without_credentials": "false"},
    ):
        try:
            load_settings(bad)
            print(f"FAIL load_settings accepted invalid config: {bad}", file=sys.stderr)
            failed += 1
        except ConfigError:
            pass
    valid_settings = load_settings(
        {
            "max_chars": 5,
            "timeout_s": 2.5,
            "fallback_without_credentials": True,
        }
    )
    check(valid_settings.max_chars == 5, "load_settings max_chars")
    check(valid_settings.timeout_s == 2.5, "load_settings timeout_s")
    check(valid_settings.fallback_without_credentials, "load_settings fallback flag")

    empty_cfg: dict = {
        "aliyun": {"access_key_id": "", "access_key_secret": ""},
        "tencent": {"secret_id": "", "secret_key": ""},
    }
    # 本机可能已有云厂商环境变量 / 用户环境；自测必须临时摘掉。
    env_backup = {name: os.environ.pop(name, None) for name in CREDENTIAL_ENV_NAMES}
    original_read_user_env = read_user_env

    def _no_user_env(_name: str) -> str:
        return ""

    globals()["read_user_env"] = _no_user_env
    try:
        # 缺密钥默认必须报配置错误，而不是悄悄换成 Google。
        try:
            engine_order("tencent", empty_cfg)
            print("FAIL missing tencent keys did not raise", file=sys.stderr)
            failed += 1
        except ConfigError:
            pass
        try:
            engine_order("aliyun", empty_cfg)
            print("FAIL missing aliyun keys did not raise", file=sys.stderr)
            failed += 1
        except ConfigError:
            pass
        opt_in_cfg = dict(empty_cfg)
        opt_in_cfg["fallback_without_credentials"] = True
        check(
            engine_order("tencent", opt_in_cfg) == ["google_gtx", "mymemory"],
            "opt-in fallback order",
        )
        keyed_tencent = {
            "tencent": {
                "secret_id": "id",
                "secret_key": "secret",
                "endpoint": DEFAULT_TENCENT_ENDPOINT,
                "region": DEFAULT_TENCENT_REGION,
                "project_id": 0,
            }
        }
        keyed_aliyun = {"aliyun": {"access_key_id": "id", "access_key_secret": "secret"}}
        check(engine_order("tencent", keyed_tencent)[0] == "tencent", "tencent preferred")
        check(engine_order("aliyun", keyed_aliyun)[0] == "aliyun", "aliyun preferred")
        check(engine_order("google", keyed_tencent)[0] == "google_gtx", "google alias")
        check(engine_order("tmt", keyed_tencent)[0] == "tencent", "tmt alias")
        check(
            engine_order("mymemory", keyed_tencent)[:2] == ["mymemory", "google_gtx"],
            "mymemory fallback order",
        )
        file_id, file_secret = resolve_tencent_keys(keyed_tencent)
        check(
            file_id == "id" and file_secret == "secret",
            "config keys used when env empty",
        )
        os.environ["TENCENTCLOUD_SECRET_ID"] = "env-id"
        os.environ["TENCENTCLOUD_SECRET_KEY"] = "env-secret"
        env_id, env_secret = resolve_tencent_keys(keyed_tencent)
        check(
            env_id == "env-id" and env_secret == "env-secret",
            f"env keys override config: {env_id!r} {env_secret!r}",
        )
    finally:
        globals()["read_user_env"] = original_read_user_env
        for name, value in env_backup.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    # 缓存键必须按实际引擎 + 影响输出的配置隔离。
    other_tencent = {
        "tencent": {
            "secret_id": "id",
            "secret_key": "secret",
            "endpoint": DEFAULT_TENCENT_ENDPOINT,
            "region": "ap-shanghai",
            "project_id": 0,
        }
    }
    tencent_key = cache_key("tencent", "en-zh", "hello", keyed_tencent)
    check(
        tencent_key != cache_key("tencent", "en-zh", "hello", other_tencent),
        "cache key must include tencent region",
    )
    check(
        tencent_key != cache_key("google_gtx", "en-zh", "hello", keyed_tencent),
        "cache key must include engine",
    )
    check(
        cache_key("google_gtx", "en-zh", "hello", keyed_tencent)
        == cache_key("google_gtx", "en-zh", "hello", other_tencent),
        "free engine cache key ignores cloud config",
    )
    record = _cache_record("tencent", "en-zh", "你好")
    check(_cache_record_valid(record, "tencent", "en-zh"), "cache record valid")
    check(
        not _cache_record_valid({"version": 1, "engine": "tencent", "translated": "x"}, "tencent", "en-zh"),
        "old cache version rejected",
    )
    check(
        not _cache_record_valid(
            {"version": CACHE_VERSION, "engine": "aliyun", "translated": "x"},
            "tencent",
            "en-zh",
        ),
        "cache engine mismatch rejected",
    )

    # 诊断信息必须单行、无原文、无密钥。
    detail = sanitize_detail(
        ValueError("boom 机密原文 AKIDselftest"),
        source_text="机密原文",
        cfg={"tencent": {"secret_id": "AKIDselftest"}},
    )
    check("机密原文" not in detail, f"detail leaked source: {detail}")
    check("AKIDselftest" not in detail, f"detail leaked secret: {detail}")
    check("\n" not in detail, "detail must be single line")
    check(
        sanitize_detail(ValueError("Authorization: Bearer abcdef")).find("abcdef") < 0,
        "detail must redact bearer token",
    )
    check(_is_timeout(TimeoutError("x")), "TimeoutError classified as timeout")
    check(_is_timeout(urllib.error.URLError(TimeoutError("x"))), "URLError timeout reason")
    check(not _is_timeout(urllib.error.URLError("offline")), "plain URLError is not timeout")

    signed = aliyun_sign("secret", "POST", {"AccessKeyId": "id", "Action": "TranslateGeneral"})
    check(bool(signed), "aliyun_sign empty")
    headers = tencent_tc3_headers(
        "AKIDtest",
        "secret",
        service="tmt",
        host="tmt.tencentcloudapi.com",
        action="TextTranslate",
        version="2018-03-21",
        region="ap-guangzhou",
        payload='{"SourceText":"hello","Source":"en","Target":"zh","ProjectId":0}',
        timestamp=1700000000,
    )
    auth = headers.get("Authorization", "")
    check(auth.startswith("TC3-HMAC-SHA256 Credential=AKIDtest/"), f"tencent auth prefix: {auth[:80]}")
    check(
        "Signature=" in auth and len(auth.rsplit("Signature=", 1)[-1]) == 64,
        "tencent signature length",
    )
    again = tencent_tc3_headers(
        "AKIDtest",
        "secret",
        service="tmt",
        host="tmt.tencentcloudapi.com",
        action="TextTranslate",
        version="2018-03-21",
        region="ap-guangzhou",
        payload='{"SourceText":"hello","Source":"en","Target":"zh","ProjectId":0}',
        timestamp=1700000000,
    )
    check(again.get("Authorization") == auth, "tencent signature not stable")
    check(headers.get("X-TC-Action") == "TextTranslate", "tencent action header")
    check(is_aliyun_auth_error("InvalidAccessKeyId.NotFound", ""), "auth detect InvalidAccessKeyId")
    check(
        is_aliyun_auth_error("", "Specified access key is not found."),
        "auth detect access key message",
    )
    check(
        not is_aliyun_auth_error("Throttling", "Request was denied due to throttling"),
        "throttling is not auth",
    )
    check(is_tencent_auth_error("AuthFailure.SecretIdNotFound", ""), "tencent SecretIdNotFound")
    check(
        is_tencent_auth_error(
            "AuthFailure.SignatureFailure",
            "The provided credentials could not be validated",
        ),
        "tencent SignatureFailure",
    )
    check(
        not is_tencent_auth_error("FailedOperation.NoFreeAmount", "free quota exceeded"),
        "tencent quota is not auth",
    )
    try:
        raise_aliyun_error("InvalidAccessKeyId.NotFound", "Specified access key is not found.")
        print("FAIL raise_aliyun_error did not raise", file=sys.stderr)
        failed += 1
    except AuthError:
        pass
    except Exception as exc:
        print(f"FAIL raise_aliyun_error type: {type(exc)}", file=sys.stderr)
        failed += 1
    try:
        raise_aliyun_error("Throttling", "Request was denied due to throttling")
        print("FAIL throttling did not raise", file=sys.stderr)
        failed += 1
    except AuthError:
        print("FAIL throttling raised AuthError", file=sys.stderr)
        failed += 1
    except ValueError:
        pass
    try:
        raise_tencent_error("AuthFailure.SecretIdNotFound", "The SecretId is not found")
        print("FAIL raise_tencent_error did not raise", file=sys.stderr)
        failed += 1
    except AuthError as exc:
        check(str(exc) == "腾讯云密钥无效", f"tencent auth message: {exc}")
    except Exception as exc:
        print(f"FAIL raise_tencent_error type: {type(exc)}", file=sys.stderr)
        failed += 1
    if failed:
        print(f"self-test failed: {failed}", file=sys.stderr)
        return 1
    print("PASS: translate self-test")
    return 0


def _state_source_text(state: dict[str, object]) -> str:
    value = state.get("text")
    return value if isinstance(value, str) else ""


def _atomic_long_output(output: str, status: str, **fields: str) -> None:
    target = Path(output)
    temporary = target.with_name(target.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        write_output(str(temporary), status, **fields)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def _run_long_translation(args, output: str, settings: Settings, cfg: dict, text: str, direction: str) -> int:
    if len(text) > long_text.MAX_TOTAL_CHARS:
        return write_error(output, "too_long", "长文超过总上限", settings.engine,
                           length=str(len(text)), max_chars=str(long_text.MAX_TOTAL_CHARS))
    segments = long_text.split_segments(text, max_chars=settings.max_chars, max_bytes=4000)
    if len(segments) > long_text.MAX_SEGMENTS:
        return write_error(output, "too_long", "长文分段数量超过上限", settings.engine)
    key = long_text.checkpoint_key(text, direction, settings.engine, cache_scope(settings.engine, cfg), segments)
    results = long_text.load_checkpoint(args.resume_file, key, len(segments))
    initial_completed = sum(result is not None for result in results)
    request = args.request_id or uuid.uuid4().hex
    base = {"version": "1", "request_id": request, "total": str(len(segments))}
    runtime = {**cfg, "_long_deadline": time.monotonic() + long_text.TASK_BUDGET_SECONDS}
    failures = 0
    last_code = "network"

    def progress():
        _atomic_long_output(output, "progress", **base,
                            completed=str(sum(result is not None for result in results)), failed=str(failures))

    progress()
    for index, segment in enumerate(segments):
        if results[index] is not None:
            continue
        if time.monotonic() >= runtime["_long_deadline"]:
            last_code = "timeout"
            break
        fatal = False
        try:
            result = (translate_with_cache(settings.engine, segment, direction, settings.timeout_s, runtime)
                      if segment.strip() else TranslationResult(segment, "identity", False, direction))
            if len(result.text) > 100000 or len(result.text) + sum(len(value["text"]) for value in results if value is not None) > long_text.MAX_OUTPUT_CHARS:
                raise ValueError("translation_output_limit")
            results[index] = {"text": result.text, "engine": result.engine, "cached": result.cached,
                              "fallback_reason": result.fallback_reason}
            long_text.save_checkpoint(args.resume_file, key, results)
        except AuthError:
            last_code, fatal = "auth", True
        except ConfigError:
            last_code, fatal = "config", True
        except Exception as exc:
            last_code = "timeout" if _is_timeout(exc) else "network" if isinstance(exc, FALLBACK_ERRORS) else "internal"
        if results[index] is None:
            failures += 1
        progress()
        if fatal:
            break
    completed = sum(result is not None for result in results)
    failed = len(segments) - completed
    successful = [result for result in results if result is not None]
    engines = {result["engine"] for result in successful if result["engine"] != "identity"}
    if not engines and successful:
        engines = {"identity"}
    engine = next(iter(engines)) if len(engines) == 1 else "mixed" if engines else settings.engine
    fields = {**base, "completed": str(completed), "failed": str(failed), "resumed": str(initial_completed),
              "direction": direction, "engine": engine,
              "cached": "1" if successful and all(result["cached"] for result in successful) else "0"}
    reasons = [result["fallback_reason"] for result in successful if result["fallback_reason"]]
    if reasons:
        fields.update(preferred_engine=settings.engine, fallback_reason=reasons[0])
    source_language, target_language = direction_langs(direction)
    body = long_text.join_results(segments, results, hard_separator=" " if target_language == "en" and source_language != target_language else "")
    if failed:
        fields.update(code=last_code, message=f"翻译未完成（{completed}/{len(segments)} 段）；可重试失败段")
        body = fields["message"] + "\n\n" + body
    fields["text"] = body
    _atomic_long_output(output, "partial" if failed else "ok", **fields)
    if not failed:
        try:
            prune_cache(max_size_mb=settings.max_size_mb, max_files=settings.max_files)
        except OSError:
            pass
    return 0


def _run_translation(
    args: argparse.Namespace,
    output: str,
    settings: Settings,
    cfg: dict,
    engine_label: str,
    state: dict[str, object],
) -> int:
    # 2) 输入：读失败归 io。
    text = args.text
    state["text"] = text
    if args.input_file:
        try:
            text = Path(args.input_file).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            return write_error(
                output,
                "io",
                "读取文本失败",
                engine_label,
                sanitize_detail(exc),
            )
        state["text"] = text
        try:
            Path(args.input_file).unlink(missing_ok=True)
        except OSError:
            pass
    text = text.lstrip("\ufeff").strip()
    state["text"] = text

    if not text:
        return write_error(output, "empty", "未包含可翻译文字", engine_label)
    # 3) 超长直接报错，不再静默截断；AHK 面板仍显示完整原文。
    if not settings.long_text_enabled and text_is_too_long(text, settings.max_chars):
        return write_error(
            output,
            "too_long",
            f"文本过长（上限 {settings.max_chars} 字符）",
            engine_label,
            "",
            length=str(len(text)),
            max_chars=str(settings.max_chars),
        )
    direction = resolve_direction(text, settings)
    if direction is None:
        return write_error(output, "detect", "未包含可翻译文字", engine_label)
    if settings.long_text_enabled:
        return _run_long_translation(args, output, settings, cfg, text, direction)

    # 4) 翻译：鉴权回退必须显式开启；成功回退保留固定原因和实际引擎。
    try:
        result = translate_with_cache(
            settings.engine,
            text,
            direction,
            settings.timeout_s,
            cfg,
        )
    except AuthError as exc:
        return write_error(
            output,
            "auth",
            str(exc).strip() or "翻译密钥无效",
            engine_label,
            sanitize_detail(exc, source_text=text, cfg=cfg),
        )
    except ConfigError as exc:
        return write_error(
            output,
            "config",
            str(exc).strip() or "配置无效",
            engine_label,
            sanitize_detail(exc, source_text=text, cfg=cfg),
        )
    except Exception as exc:
        if _is_timeout(exc):
            code, message = "timeout", "翻译超时"
        elif isinstance(exc, FreeEngineLimitError):
            # 云引擎不可用、免费回退引擎又装不下这段文本：真实原因是「太长」，
            # 报 network 会让用户一直去查网络。
            code, message = "too_long", str(exc).strip() or "文本过长，免费引擎不支持"
        elif isinstance(exc, FALLBACK_ERRORS):
            code, message = "network", "网络请求失败"
        else:
            code, message = "internal", "翻译失败"
        return write_error(
            output,
            code,
            message,
            engine_label,
            sanitize_detail(exc, source_text=text, cfg=cfg),
        )

    if result.engine != "identity":
        try:
            prune_cache(max_size_mb=settings.max_size_mb, max_files=settings.max_files)
        except Exception:
            # 清缓存失败不该让已经成功的翻译失败。
            pass
    try:
        fields = {"direction": direction, "engine": result.engine, "cached": "1" if result.cached else "0"}
        if result.fallback_reason:
            fields.update(preferred_engine=result.preferred_engine, fallback_reason=result.fallback_reason)
        fields["text"] = result.text
        write_output(output, "ok", **fields)
    except OSError:
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Lat3ncy 划词翻译")
    parser.add_argument("--text", default="", help="要翻译的文本")
    parser.add_argument("--input-file", default="", help="包含待译文本的 UTF-8 文件")
    parser.add_argument("--output-file", default="", help="结果文件路径")
    parser.add_argument("--config", default=None, help="config.toml 路径")
    parser.add_argument("--source-language", default=None, help="覆盖本次源语言：auto / zh / en")
    parser.add_argument("--target-language", default=None, help="覆盖本次目标语言：auto / zh / en")
    parser.add_argument("--long-text", action=argparse.BooleanOptionalAction, default=None, help="分段翻译，最大 20000 字符、120 秒")
    parser.add_argument("--request-id", default="", help="长文进度归属，不包含文本")
    parser.add_argument("--resume-file", default="", help="仅此面板拥有的临时重试文件")
    parser.add_argument("--trace-file", default="", help="本次请求的脱敏引擎摘要；需同时提供 --request-id")
    parser.add_argument("--self-test", action="store_true", help="只跑判定/配置/缓存单测，不联网")
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_test()

    output = args.output_file.strip()
    if not output:
        print("missing --output-file", file=sys.stderr)
        return 1

    # 1) 配置：TOML 语法、非法数值都归 config，不能混进 network。
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        return write_error(
            output,
            "config",
            str(exc).strip() or "配置无效",
            DEFAULT_ENGINE,
            sanitize_detail(exc),
        )
    except Exception as exc:
        return write_error(
            output,
            "internal",
            "翻译失败",
            DEFAULT_ENGINE,
            sanitize_detail(exc),
        )
    if args.source_language is not None:
        cfg["source_language"] = args.source_language
    if args.target_language is not None:
        cfg["target_language"] = args.target_language
    if args.long_text is not None:
        cfg["long_text_enabled"] = args.long_text
    engine_label = _engine_label(cfg)
    try:
        settings = load_settings(cfg)
    except ConfigError as exc:
        return write_error(
            output,
            "config",
            str(exc).strip() or "配置无效",
            engine_label,
            sanitize_detail(exc, cfg=cfg),
        )
    except Exception as exc:
        return write_error(
            output,
            "internal",
            "翻译失败",
            engine_label,
            sanitize_detail(exc, cfg=cfg),
        )
    engine_label = settings.engine
    if args.trace_file:
        try:
            reserved = [output, args.input_file, args.resume_file, args.config or str(Path(__file__).with_name('config.toml'))]
            if Path(args.trace_file).resolve() in {Path(path).resolve() for path in reserved if path}:
                return write_error(output, 'config', '诊断文件不能与任务文件或配置重合', engine_label)
            cfg['_engine_trace'] = engine_trace.EngineTrace(args.trace_file, args.request_id)
        except (ValueError, OSError):
            return write_error(output, 'config', '诊断请求编号或路径无效', engine_label)

    # 兜底：正常路径都在 _run_translation 内分类；这里只接住真正未预期的异常。
    state: dict[str, object] = {"text": ""}
    try:
        return _run_translation(args, output, settings, cfg, engine_label, state)
    except AuthError as exc:
        return write_error(
            output,
            "auth",
            str(exc).strip() or "翻译密钥无效",
            engine_label,
            sanitize_detail(exc, source_text=_state_source_text(state), cfg=cfg),
        )
    except ConfigError as exc:
        return write_error(
            output,
            "config",
            str(exc).strip() or "配置无效",
            engine_label,
            sanitize_detail(exc, source_text=_state_source_text(state), cfg=cfg),
        )
    except Exception as exc:
        return write_error(
            output,
            "internal",
            "翻译失败",
            engine_label,
            sanitize_detail(exc, source_text=_state_source_text(state), cfg=cfg),
        )


if __name__ == "__main__":
    raise SystemExit(main())
