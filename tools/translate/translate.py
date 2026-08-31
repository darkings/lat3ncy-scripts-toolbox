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
import os
import re
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn

ZH_CHAR_PATTERN = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff]")
EN_CHAR_PATTERN = re.compile(r"[A-Za-z]")

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
# 阿里云鉴权失败：密钥错/签名错。这类错误不回退，交给 AHK 弹系统 Toast。
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
# 腾讯云 TC3 鉴权失败。同样不回退。
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


class AuthError(ValueError):
    """云厂商密钥或签名无效。不回退 Google/MyMemory。"""


def detect_direction(text: str) -> str | None:
    """汉字数 >= 拉丁字母数 → zh-en，否则 en-zh；两边都是 0 则无法判定。"""
    zh = len(ZH_CHAR_PATTERN.findall(text))
    en = len(EN_CHAR_PATTERN.findall(text))
    if zh == 0 and en == 0:
        return None
    return "zh-en" if zh >= en else "en-zh"


def direction_langs(direction: str) -> tuple[str, str]:
    if direction == "en-zh":
        return "en", "zh-CN"
    return "zh-CN", "en"


def load_config(config_path: str | None) -> dict:
    cfg: dict = {
        "engine": "tencent",
        "timeout_s": 4,
        "max_chars": 2000,
        "cache": {"max_size_mb": 10, "max_files": 500},
        "aliyun": {
            "access_key_id": "",
            "access_key_secret": "",
            "endpoint": "mt.cn-hangzhou.aliyuncs.com",
        },
        "tencent": {
            "secret_id": "",
            "secret_key": "",
            "region": "ap-guangzhou",
            "endpoint": "tmt.tencentcloudapi.com",
            "project_id": 0,
        },
    }
    path = Path(config_path) if config_path else Path(__file__).with_name("config.toml")
    if path.is_file():
        try:
            with path.open("rb") as handle:
                loaded = tomllib.load(handle)
            if isinstance(loaded, dict):
                cache = cfg["cache"]
                aliyun = cfg["aliyun"]
                tencent = cfg["tencent"]
                cfg.update(loaded)
                if isinstance(cfg.get("cache"), dict):
                    merged = dict(cache)
                    merged.update(cfg["cache"])
                    cfg["cache"] = merged
                else:
                    cfg["cache"] = cache
                if isinstance(cfg.get("aliyun"), dict):
                    merged_aliyun = dict(aliyun)
                    merged_aliyun.update(cfg["aliyun"])
                    cfg["aliyun"] = merged_aliyun
                else:
                    cfg["aliyun"] = aliyun
                if isinstance(cfg.get("tencent"), dict):
                    merged_tencent = dict(tencent)
                    merged_tencent.update(cfg["tencent"])
                    cfg["tencent"] = merged_tencent
                else:
                    cfg["tencent"] = tencent
        except OSError:
            pass
    return cfg


def cache_dir() -> Path:
    root = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
    path = Path(root) / "lat3ncy-toolbox" / "translate-cache"
    path.mkdir(parents=True, exist_ok=True)
    return path


def cache_key(direction: str, text: str) -> str:
    payload = f"{direction}\n{text}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def cache_get(direction: str, text: str) -> str | None:
    path = cache_dir() / f"{cache_key(direction, text)}.txt"
    if not path.is_file():
        return None
    try:
        translated = path.read_text(encoding="utf-8")
        if translated.strip():
            try:
                os.utime(path, None)
            except OSError:
                pass
            return translated
    except OSError:
        return None
    return None


def cache_put(direction: str, text: str, translated: str) -> None:
    path = cache_dir() / f"{cache_key(direction, text)}.txt"
    tmp = path.with_suffix(f".tmp.{os.getpid()}")
    try:
        tmp.write_text(translated, encoding="utf-8")
        if path.exists():
            path.unlink()
        tmp.replace(path)
    except OSError:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def prune_cache(max_size_mb: int = 10, max_files: int = 500) -> None:
    folder = cache_dir()
    try:
        entries: list[tuple[float, int, Path]] = []
        total = 0
        for item in folder.iterdir():
            if not item.is_file() or item.suffix != ".txt":
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


def engine_order(preferred: str, cfg: dict) -> list[str]:
    """首选在前，其余只回退免费接口；没 Key 就跳过对应云引擎。"""
    name = normalize_engine(preferred)
    ordered = [name] + [item for item in FALLBACK_ENGINES if item != name]
    if name == "aliyun":
        key_id, key_secret = resolve_aliyun_keys(cfg)
        if not key_id or not key_secret:
            ordered = [item for item in ordered if item != "aliyun"]
    elif name == "tencent":
        secret_id, secret_key = resolve_tencent_keys(cfg)
        if not secret_id or not secret_key:
            ordered = [item for item in ordered if item != "tencent"]
    return ordered or ["google_gtx", "mymemory"]


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
    endpoint = str(section.get("endpoint") or "mt.cn-hangzhou.aliyuncs.com").strip()
    endpoint = endpoint.replace("https://", "").replace("http://", "").strip("/")
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
    host = str(section.get("endpoint") or "tmt.tencentcloudapi.com").strip()
    host = host.replace("https://", "").replace("http://", "").strip("/")
    region = str(section.get("region") or "ap-guangzhou").strip() or "ap-guangzhou"
    try:
        project_id = int(section.get("project_id", 0) or 0)
    except (TypeError, ValueError):
        project_id = 0
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


def translate_text(
    engine: str,
    text: str,
    direction: str,
    timeout: float,
    cfg: dict | None = None,
) -> str:
    source, target = direction_langs(direction)
    settings = cfg or {}
    engines = engine_order(engine, settings)

    last_error: Exception | None = None
    for name in engines:
        try:
            if name == "tencent":
                return translate_tencent(text, source, target, timeout, settings)
            if name == "aliyun":
                return translate_aliyun(text, source, target, timeout, settings)
            if name == "google_gtx":
                return translate_google_gtx(text, source, target, timeout)
            return translate_mymemory(text, source, target, timeout)
        except AuthError:
            # 密钥错了再回退，会把配置问题藏起来。交给上层弹 Toast。
            raise
        except (
            urllib.error.URLError,
            urllib.error.HTTPError,
            TimeoutError,
            ValueError,
            json.JSONDecodeError,
            OSError,
        ) as exc:
            last_error = exc
            continue
    raise RuntimeError(str(last_error) if last_error else "翻译失败")


def write_output(path: str, status: str, **fields: str) -> None:
    lines = [f"status={status}"]
    for key, value in fields.items():
        if key == "text":
            continue
        cleaned = value.replace("\r", "").replace("\n", " ")
        lines.append(f"{key}={cleaned}")
    if "text" in fields:
        body = fields["text"].replace("\r\n", "\n").replace("\r", "\n")
        lines.append("text=" + body)
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_self_test() -> int:
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
    failed = 0
    for text, expected in cases:
        actual = detect_direction(text)
        if actual != expected:
            print(f"FAIL detect {text!r}: expected {expected!r} got {actual!r}", file=sys.stderr)
            failed += 1
    source, target = direction_langs("zh-en")
    if source != "zh-CN" or target != "en":
        print(f"FAIL langs zh-en: {source} {target}", file=sys.stderr)
        failed += 1
    source, target = direction_langs("en-zh")
    if source != "en" or target != "zh-CN":
        print(f"FAIL langs en-zh: {source} {target}", file=sys.stderr)
        failed += 1
    if aliyun_lang("zh-CN") != "zh" or aliyun_lang("en") != "en":
        print("FAIL aliyun_lang", file=sys.stderr)
        failed += 1
    if tencent_lang("zh-CN") != "zh" or tencent_lang("en") != "en":
        print("FAIL tencent_lang", file=sys.stderr)
        failed += 1
    encoded = aliyun_percent_encode("a b*c~d")
    if encoded != "a%20b%2Ac~d":
        print(f"FAIL aliyun_percent_encode: {encoded}", file=sys.stderr)
        failed += 1
    empty_cfg: dict = {
        "aliyun": {"access_key_id": "", "access_key_secret": ""},
        "tencent": {"secret_id": "", "secret_key": ""},
    }
    # 本机可能已有云厂商环境变量 / 用户环境；自测必须临时摘掉。
    env_backup = {
        name: os.environ.pop(name, None)
        for name in (
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
    }
    original_read_user_env = read_user_env

    def _no_user_env(_name: str) -> str:
        return ""

    globals()["read_user_env"] = _no_user_env
    try:
        order = engine_order("tencent", empty_cfg)
        if "tencent" in order:
            print(f"FAIL skip tencent without keys: {order}", file=sys.stderr)
            failed += 1
        if "aliyun" in order:
            print(f"FAIL default order must not include aliyun: {order}", file=sys.stderr)
            failed += 1
        if order[:2] != ["google_gtx", "mymemory"]:
            print(f"FAIL fallback order: {order}", file=sys.stderr)
            failed += 1
        keyed_tencent = {"tencent": {"secret_id": "id", "secret_key": "secret"}}
        if engine_order("tencent", keyed_tencent)[0] != "tencent":
            print("FAIL tencent preferred with keys", file=sys.stderr)
            failed += 1
        keyed_aliyun = {"aliyun": {"access_key_id": "id", "access_key_secret": "secret"}}
        if engine_order("aliyun", keyed_aliyun)[0] != "aliyun":
            print("FAIL aliyun preferred with keys", file=sys.stderr)
            failed += 1
        if engine_order("google", keyed_tencent)[0] != "google_gtx":
            print("FAIL google alias", file=sys.stderr)
            failed += 1
        if engine_order("tmt", keyed_tencent)[0] != "tencent":
            print("FAIL tmt alias", file=sys.stderr)
            failed += 1
        file_id, file_secret = resolve_tencent_keys(keyed_tencent)
        if file_id != "id" or file_secret != "secret":
            print("FAIL config keys used when env empty", file=sys.stderr)
            failed += 1
        os.environ["TENCENTCLOUD_SECRET_ID"] = "env-id"
        os.environ["TENCENTCLOUD_SECRET_KEY"] = "env-secret"
        env_id, env_secret = resolve_tencent_keys(keyed_tencent)
        if env_id != "env-id" or env_secret != "env-secret":
            print(f"FAIL env keys override config: {env_id!r} {env_secret!r}", file=sys.stderr)
            failed += 1
    finally:
        globals()["read_user_env"] = original_read_user_env
        for name, value in env_backup.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    signed = aliyun_sign("secret", "POST", {"AccessKeyId": "id", "Action": "TranslateGeneral"})
    if not signed:
        print("FAIL aliyun_sign empty", file=sys.stderr)
        failed += 1
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
    if not auth.startswith("TC3-HMAC-SHA256 Credential=AKIDtest/"):
        print(f"FAIL tencent auth prefix: {auth[:80]}", file=sys.stderr)
        failed += 1
    if "Signature=" not in auth or len(auth.rsplit("Signature=", 1)[-1]) != 64:
        print("FAIL tencent signature length", file=sys.stderr)
        failed += 1
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
    if again.get("Authorization") != auth:
        print("FAIL tencent signature not stable", file=sys.stderr)
        failed += 1
    if headers.get("X-TC-Action") != "TextTranslate":
        print("FAIL tencent action header", file=sys.stderr)
        failed += 1
    if not is_aliyun_auth_error("InvalidAccessKeyId.NotFound", ""):
        print("FAIL auth detect InvalidAccessKeyId", file=sys.stderr)
        failed += 1
    if not is_aliyun_auth_error("", "Specified access key is not found."):
        print("FAIL auth detect access key message", file=sys.stderr)
        failed += 1
    if is_aliyun_auth_error("Throttling", "Request was denied due to throttling"):
        print("FAIL throttling is not auth", file=sys.stderr)
        failed += 1
    if not is_tencent_auth_error("AuthFailure.SecretIdNotFound", ""):
        print("FAIL tencent auth detect SecretIdNotFound", file=sys.stderr)
        failed += 1
    if not is_tencent_auth_error("AuthFailure.SignatureFailure", "The provided credentials could not be validated"):
        print("FAIL tencent auth detect SignatureFailure", file=sys.stderr)
        failed += 1
    if is_tencent_auth_error("FailedOperation.NoFreeAmount", "free quota exceeded"):
        print("FAIL tencent quota is not auth", file=sys.stderr)
        failed += 1
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
        if str(exc) != "腾讯云密钥无效":
            print(f"FAIL tencent auth message: {exc}", file=sys.stderr)
            failed += 1
    except Exception as exc:
        print(f"FAIL raise_tencent_error type: {type(exc)}", file=sys.stderr)
        failed += 1
    if failed:
        print(f"self-test failed: {failed}", file=sys.stderr)
        return 1
    print("PASS: translate self-test")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Lat3ncy 划词翻译")
    parser.add_argument("--text", default="", help="要翻译的文本")
    parser.add_argument("--input-file", default="", help="包含待译文本的 UTF-8 文件")
    parser.add_argument("--output-file", default="", help="结果文件路径")
    parser.add_argument("--config", default=None, help="config.toml 路径")
    parser.add_argument("--self-test", action="store_true", help="只跑语言判定单测，不联网")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    output = args.output_file.strip()
    if not output:
        print("missing --output-file", file=sys.stderr)
        return 1

    try:
        text = args.text
        if args.input_file:
            text = Path(args.input_file).read_text(encoding="utf-8")
            try:
                Path(args.input_file).unlink(missing_ok=True)
            except OSError:
                pass
        text = text.lstrip("\ufeff").strip()
        cfg = load_config(args.config)
        max_chars = max(1, int(cfg.get("max_chars", 2000) or 2000))
        timeout_s = max(1.0, float(cfg.get("timeout_s", 4) or 4))
        engine = str(cfg.get("engine", "tencent") or "tencent")
        cache_cfg = cfg.get("cache", {})
        max_size_mb = int(cache_cfg.get("max_size_mb", 10) or 10)
        max_files = int(cache_cfg.get("max_files", 500) or 500)

        if not text:
            write_output(output, "error", code="empty", message="未包含可翻译文字")
            return 0

        if len(text) > max_chars:
            text = text[:max_chars]

        direction = detect_direction(text)
        if direction is None:
            write_output(output, "error", code="detect", message="未包含可翻译文字")
            return 0

        cached = cache_get(direction, text)
        if cached is not None:
            write_output(output, "ok", direction=direction, text=cached)
            return 0

        translated = translate_text(engine, text, direction, timeout_s, cfg)
        cache_put(direction, text, translated)
        prune_cache(max_size_mb=max_size_mb, max_files=max_files)
        write_output(output, "ok", direction=direction, text=translated)
        return 0
    except AuthError as exc:
        try:
            write_output(
                output,
                "error",
                code="auth",
                message=str(exc).strip() or "翻译密钥无效",
            )
        except OSError:
            return 1
        return 0
    except Exception:
        try:
            write_output(output, "error", code="network", message="翻译失败")
        except OSError:
            return 1
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
