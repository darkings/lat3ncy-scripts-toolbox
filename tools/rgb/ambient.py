#!/usr/bin/env python3
"""
Ambient：桌面取色 -> 技嘉风扇(OpenRGB SDK) + Hi75(HID Col06)。

OpenRGB 只复用已常驻的 127.0.0.1:6742，本进程不启动、不重启 OpenRGB。
Hi75 走 hidapi Feature Report，不经过 OpenRGB。
"""
from __future__ import annotations

import argparse
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
LIB = ROOT / "lib"
LIB_HID = ROOT / "lib_hid"
# insert(0) 后最靠前的是最后插入的：lib_hid/hid.pyd 必须压过 lib/hid
for p in (ROOT, LIB, LIB_HID):
    text = str(p)
    if text in sys.path:
        sys.path.remove(text)
    sys.path.insert(0, text)

import numpy as np

try:
    import tomllib
except ImportError:  # Python < 3.11
    import tomli as tomllib  # type: ignore[no-redef]

from hi75 import (  # noqa: E402
    build_direct_report,
    enumerate_hi75,
    open_hi75,
    send_feature_reports,
)

CONFIG_PATH = ROOT / "config.toml"
LOG_DIR = ROOT / "logs"
# OpenRGB 设备名子串；B550M DS3H 不含 "gigabyte"，必须单独匹配
DEFAULT_OPENRGB_MATCH = ("gigabyte", "b550", "ds3h")


def _attach_file_logs() -> None:
    """pythonw 没有 stdout。把 print 接到 logs/，避免 Start-Process 重定向再弹出终端。"""
    if sys.stdout is not None:
        return
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    # 每次启动覆盖，日志只反映这一次进程。
    sys.stdout = open(LOG_DIR / "ambient.out.log", "w", encoding="utf-8", buffering=1)
    if sys.stderr is None:
        sys.stderr = open(LOG_DIR / "ambient.err.log", "w", encoding="utf-8", buffering=1)


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    if not path.is_file():
        return {}
    with path.open("rb") as f:
        data = tomllib.load(f)
    return data if isinstance(data, dict) else {}


def _section(cfg: dict[str, Any], name: str) -> dict[str, Any]:
    value = cfg.get(name, {})
    return value if isinstance(value, dict) else {}


def _as_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_float(value: Any, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _as_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off"}:
            return False
    if isinstance(value, (int, float)):
        return bool(value)
    return default


class CaptureBase:
    def grab(self) -> np.ndarray | None:
        raise NotImplementedError

    def stop(self) -> None:
        return None


class MssCapture(CaptureBase):
    """中心/指定区域抓屏，稀疏采样后返回 HxWx3 RGB，供饱和度选点。"""

    def __init__(self, monitor: int = 1, sample_step: int = 8, region: str | None = None) -> None:
        import mss

        self._monitor_index = monitor
        self._region = region
        self.sample_step = max(1, sample_step)
        self.use_full = False
        self._next_reopen_t = 0.0
        self._grab_fail_logged = False
        self.mss = mss.MSS()
        self._apply_monitor()

    def _apply_monitor(self) -> None:
        """按当前 MSS 句柄重算抓屏区域。解锁后 DC 失效时会整份重建。"""
        monitors = self.mss.monitors
        if self._monitor_index < 0 or self._monitor_index >= len(monitors):
            raise RuntimeError(
                f"mss monitor {self._monitor_index} out of range 0..{len(monitors) - 1}"
            )
        self.monitor = monitors[self._monitor_index]
        region = self._region
        self.use_full = False
        if region and region.strip().lower() == "full":
            self.mon = self.monitor
            self.use_full = True
        elif region and region.strip():
            x, y, rw, rh = (int(part) for part in region.split(","))
            if rw <= 0 or rh <= 0:
                raise ValueError(f"invalid region size: {region}")
            self.mon = {"left": x, "top": y, "width": rw, "height": rh}
        else:
            mon_w = int(self.monitor["width"])
            mon_h = int(self.monitor["height"])
            sw = min(320, max(16, mon_w // 4))
            sh = min(180, max(16, mon_h // 4))
            cx = int(self.monitor["left"]) + (mon_w - sw) // 2
            cy = int(self.monitor["top"]) + (mon_h - sh) // 2
            self.mon = {"left": cx, "top": cy, "width": sw, "height": sh}

    def _reopen(self) -> None:
        """锁屏会让 GetWindowDC(0) 失效；解锁后必须 new MSS()，旧句柄 BitBlt 会一直失败。"""
        import mss

        try:
            self.mss.close()
        except Exception:
            pass
        self.mss = mss.MSS()
        self._apply_monitor()

    def grab(self) -> np.ndarray | None:
        try:
            raw = self.mss.grab(self.mon)
        except Exception as exc:
            # mss.ScreenShotError 继承 Exception 不是 OSError；锁屏 BitBlt 必须吞掉。
            if not self._grab_fail_logged:
                print(f"[capture] mss grab failed: {_capture_error_hint(exc)}")
                self._grab_fail_logged = True
            now = time.monotonic()
            if now >= self._next_reopen_t:
                self._next_reopen_t = now + 5.0
                try:
                    self._reopen()
                    print("[capture] mss reopened after grab fail")
                except Exception as reopen_exc:
                    print(f"[capture] mss reopen failed: {reopen_exc}")
            return None
        self._grab_fail_logged = False
        arr = np.frombuffer(raw.bgra, dtype=np.uint8).reshape(raw.height, raw.width, 4)
        step = self.sample_step
        if self.use_full:
            step = max(step, 8)
        sampled = arr[::step, ::step, :]
        # BGRA -> RGB
        return np.ascontiguousarray(sampled[:, :, 2::-1])

    def stop(self) -> None:
        try:
            self.mss.close()
        except OSError:
            pass


class PilCapture(CaptureBase):
    def __init__(self, w: int = 32, h: int = 32, region: str | None = None) -> None:
        from PIL import ImageGrab

        self.ImageGrab = ImageGrab
        self.w = max(1, w)
        self.h = max(1, h)
        self.bbox: tuple[int, int, int, int] | None = None
        if region and region.strip().lower() == "full":
            self.bbox = None
        elif region and region.strip():
            x, y, rw, rh = (int(part) for part in region.split(","))
            if rw <= 0 or rh <= 0:
                raise ValueError(f"invalid region size: {region}")
            self.bbox = (x, y, x + rw, y + rh)

    def grab(self) -> np.ndarray | None:
        from PIL import Image

        try:
            img = self.ImageGrab.grab(bbox=self.bbox, all_screens=False)
        except Exception as exc:
            # 锁屏 / 无交互桌面时 ImageGrab 同样会失败，返回 None 让主循环保活。
            print(f"[capture] pil grab failed: {_capture_error_hint(exc)}")
            return None
        if img.size != (self.w, self.h):
            # Pillow 10+ 类型桩只有 Resampling.BILINEAR；旧版仍用 Image.BILINEAR。
            resample = getattr(getattr(Image, "Resampling", Image), "BILINEAR")
            img = img.resize((self.w, self.h), resample)
        if img.mode != "RGB":
            img = img.convert("RGB")
        return np.asarray(img, dtype=np.uint8)


class DxcamCapture(CaptureBase):
    def __init__(self, w: int = 32, h: int = 32, monitor: int = 0) -> None:
        import dxcam

        try:
            self.cam = dxcam.create(output_idx=monitor, output_color="BGR", max_buffer_len=2)
        except Exception as exc:  # dxcam 在部分机器 create 即 hang/抛错
            raise RuntimeError(f"dxcam create failed: {exc}") from exc
        self.w = max(1, w)
        self.h = max(1, h)
        self.started = False

    def start(self, fps: int = 12) -> None:
        if self.started:
            return
        self.cam.start(target_fps=max(1, fps), video_mode=True)
        self.started = True
        time.sleep(0.2)

    def grab(self) -> np.ndarray | None:
        from PIL import Image

        if not self.started:
            self.start(12)
        frame = self.cam.get_latest_frame()
        if frame is None:
            return None
        rgb = frame[:, :, ::-1]
        h, w, _ = rgb.shape
        if w == self.w and h == self.h:
            return np.ascontiguousarray(rgb)
        img = Image.fromarray(rgb, "RGB")
        resample = getattr(getattr(Image, "Resampling", Image), "BILINEAR")
        img = img.resize((self.w, self.h), resample)
        return np.asarray(img, dtype=np.uint8)

    def stop(self) -> None:
        if not getattr(self, "cam", None):
            return
        try:
            self.cam.stop()
        except OSError:
            pass


def _capture_error_hint(exc: BaseException) -> str:
    text = str(exc)
    lowered = text.lower()
    if "bitblt" in lowered or "screenshoterror" in type(exc).__name__.lower():
        return (
            f"{exc} — 当前没有可用交互桌面会话（Session 0 / 无显示器抓屏会失败）。"
            " 这不是 OpenRGB 服务或 hi75.exe 损坏。"
        )
    return text


def create_capture(cfg: dict[str, Any]) -> tuple[CaptureBase, str]:
    cap_cfg = _section(cfg, "capture")
    backend = str(cap_cfg.get("backend", "mss")).strip().lower() or "mss"
    w = _as_int(cap_cfg.get("output_w", 32), 32)
    h = _as_int(cap_cfg.get("output_h", 32), 32)
    mon = _as_int(cap_cfg.get("monitor", 1), 1)
    sample_step = _as_int(cap_cfg.get("sample_step", 8), 8)
    region_raw = cap_cfg.get("region", "")
    region = str(region_raw).strip() or None
    if backend == "auto":
        order = ["mss", "pil", "dxcam"]
    else:
        order = [backend]
    last_err: BaseException | None = None
    for name in order:
        cap: CaptureBase | None = None
        try:
            if name == "dxcam":
                cap = DxcamCapture(w=w, h=h, monitor=max(0, mon - 1))
                cap.start(fps=_as_int(cap_cfg.get("fps_active", 8), 8))
                frame = cap.grab()
                if frame is None:
                    raise RuntimeError("dxcam get_latest_frame None")
                print(f"[capture] backend=dxcam {frame.shape} ok")
                return cap, "dxcam"
            if name == "mss":
                cap = MssCapture(monitor=mon, sample_step=sample_step, region=region)
                frame = cap.grab()
                if frame is None:
                    raise RuntimeError("mss grab returned None")
                print(f"[capture] backend=mss {frame.shape} step={sample_step} ok")
                return cap, "mss"
            if name == "pil":
                cap = PilCapture(w=w, h=h, region=region)
                frame = cap.grab()
                if frame is None:
                    raise RuntimeError("pil grab returned None")
                print(f"[capture] backend=pil {frame.shape} ok")
                return cap, "pil"
            raise RuntimeError(f"unknown capture backend {name}")
        except Exception as exc:
            # mss.ScreenShotError 继承 Exception 而不是 OSError；BitBlt 失败必须进 fallback。
            last_err = exc
            print(f"[capture] {name} failed: {_capture_error_hint(exc)}")
            if cap is not None:
                try:
                    cap.stop()
                except Exception:
                    pass
    raise RuntimeError(
        "all capture backends failed, last="
        f"{_capture_error_hint(last_err) if last_err else last_err}"
    )


def apply_gamma(rgb: np.ndarray, gamma: float) -> np.ndarray:
    if abs(gamma - 1.0) < 1e-6:
        return rgb
    if gamma <= 0:
        return rgb
    norm = np.clip(rgb / 255.0, 0.0, 1.0)
    return np.clip((norm ** (1.0 / gamma)) * 255.0, 0.0, 255.0)


def process_frame(
    arr: np.ndarray,
    ema: np.ndarray | None,
    alpha: float,
    min_brightness: float,
    saturation_boost: float = 1.6,
    gamma: float = 1.0,
    min_valid_ratio: float = 0.08,
    snap_delta: float = 48.0,
) -> tuple[np.ndarray | None, np.ndarray | None, float]:
    """返回 (ema, rgb_or_None, brightness)。

    切场黑帧 / 亮像素太少时 rgb 为 None，并且不改 EMA。
    只对亮像素取饱和度最高的 30% 做均值，避免黑边把颜色拉灰、拉黑。
    颜色跳变超过 snap_delta 时直接落地，避免黑→白爬过中间灰。
    """
    pixels = arr.reshape(-1, 3).astype(np.float64)
    luma = pixels.mean(axis=1)
    brightness = float(luma.mean())
    # 整帧均值过暗：直接视为切场，连有效像素筛选都不必做
    if brightness < min_brightness:
        return ema, None, brightness

    min_valid = max(8, int(pixels.shape[0] * min_valid_ratio))
    valid = pixels[luma >= min_brightness]
    if valid.shape[0] < min_valid:
        return ema, None, brightness

    if valid.shape[0] > 64:
        mx = valid.max(axis=1)
        mn = valid.min(axis=1)
        sat = (mx - mn) / (mx + 1.0)
        k = max(1, int(valid.shape[0] * 0.3))
        idx = np.argpartition(sat, -k)[-k:]
        mean = valid[idx].mean(axis=0)
    else:
        mean = valid.mean(axis=0)

    mean = apply_gamma(mean, gamma)
    # 有效像素本身仍然很暗：当黑场，避免少量噪点放行
    if float(mean.mean()) < min_brightness:
        return ema, None, brightness

    if abs(saturation_boost - 1.0) > 1e-6:
        gray = float(mean.mean())
        mean = gray + (mean - gray) * saturation_boost
        mean = np.clip(mean, 0.0, 255.0)

    # 第一帧、或切窗口这种大跳变：直接落地，不要从旧色爬到新色
    if ema is None or float(np.linalg.norm(mean - ema)) >= snap_delta:
        ema = mean.copy()
    else:
        ema = ema * (1.0 - alpha) + mean * alpha
    rgb = np.clip(np.rint(ema), 0, 255).astype(np.int32)
    return ema, rgb, brightness


def color_delta(a: np.ndarray | None, b: np.ndarray | None) -> float:
    if a is None or b is None:
        return 999.0
    return float(np.linalg.norm(a.astype(np.float64) - b.astype(np.float64)))


def _openrgb_match_needles(raw: Any) -> tuple[str, ...]:
    """把 config 的 device_match 收成小写子串；空值回落到主板默认。"""
    if isinstance(raw, str):
        parts = [part.strip().lower() for part in raw.split(",") if part.strip()]
        return tuple(parts) if parts else DEFAULT_OPENRGB_MATCH
    if isinstance(raw, (list, tuple)):
        parts = [str(part).strip().lower() for part in raw if str(part).strip()]
        return tuple(parts) if parts else DEFAULT_OPENRGB_MATCH
    return DEFAULT_OPENRGB_MATCH


def _zone_size_map(raw: Any) -> dict[str, int]:
    """把 config 的 zone_sizes 收成 {分区名小写: 灯珠数}。"""
    if not isinstance(raw, dict):
        return {}
    sizes: dict[str, int] = {}
    for name, value in raw.items():
        key = str(name).strip().lower()
        count = _as_int(value, 0)
        if key and count > 0:
            sizes[key] = count
    return sizes


class OpenRGBWrap:
    """只连接已常驻的 SDK，不启动 OpenRGB.exe。握手失败后按退避重连，不永久放弃主板。"""

    def __init__(
        self,
        enabled: bool,
        brightness: int = 80,
        mode: str = "Direct",
        match: Any = None,
        zone_sizes: Any = None,
    ) -> None:
        self.enabled = enabled
        self.brightness = max(0, min(100, brightness))
        self.mode = mode
        self.match = _openrgb_match_needles(match)
        self.zone_sizes = _zone_size_map(zone_sizes)
        self.cli: Any = None
        self.devs: list[Any] = []
        self.last_rgb: np.ndarray | None = None
        self.last_off = False
        self.RGBColor: Any = None
        # 启动瞬间 SDK 可能还在枚举 SMBus，握手超时很常见；之后必须重试。
        # 不在 __init__ 里连：先让 Hi75 亮起来，第一帧 push 再握手主板。
        self._next_connect_t = 0.0
        self._connect_fail_count = 0
        if not enabled:
            print("[openrgb] disabled")
            return
        print("[openrgb] enabled, will connect on first push")

    def _close_cli(self) -> None:
        """丢掉当前 SDK 连接，下次 _try_connect 再握手。"""
        cli = self.cli
        self.cli = None
        self.devs = []
        if cli is None:
            return
        try:
            cli.disconnect()
        except OSError:
            pass

    def _schedule_retry(self) -> None:
        """连接失败后 2/4/8/16/30s 退避，避免每帧都去撞 6742。"""
        self._connect_fail_count += 1
        delay = min(30.0, 2.0 * (2 ** min(self._connect_fail_count - 1, 4)))
        self._next_connect_t = time.monotonic() + delay
        print(f"[openrgb] retry in {delay:.0f}s")

    def _try_connect(self, initial: bool = False) -> bool:
        """连 127.0.0.1:6742，只接管命中 device_match 的主板，绝不 fallback 全部设备。"""
        if not self.enabled:
            return False
        if self.cli is not None:
            return True
        now = time.monotonic()
        if not initial and now < self._next_connect_t:
            return False

        # 只试一次，失败交给退避。不要在启动时连堵好几秒，否则键盘也跟着晚亮。
        _ = initial
        try:
            from openrgb import OpenRGBClient
            from openrgb.utils import RGBColor

            self.RGBColor = RGBColor
            self.cli = OpenRGBClient(
                address="127.0.0.1", port=6742, name="lat3ncy-ambient"
            )
            matched = [
                d
                for d in self.cli.devices
                if any(needle in d.name.lower() for needle in self.match)
            ]
            if not matched:
                names = ", ".join(d.name for d in self.cli.devices) or "(none)"
                print(
                    f"[openrgb] no device matching {self.match}, "
                    f"have: {names}; skip (will not paint all devices)"
                )
                self._close_cli()
                # 设备列表稍后可能补齐，继续退避重试，但不把 enabled 打成 False。
                self._schedule_retry()
                return False
            self.devs = matched
            names = ", ".join(d.name for d in self.devs)
            print(
                f"[openrgb] connected {len(self.cli.devices)} devices, "
                f"using {len(self.devs)}: {names}"
            )
            for dev in self.devs:
                self._prepare_device(dev)
            self._connect_fail_count = 0
            self._next_connect_t = 0.0
            # 重连后强制再推一帧，否则 last_rgb 还在、主板会一直停在旧色。
            self.last_rgb = None
            self.last_off = False
            return True
        except Exception as exc:
            self._close_cli()
            print(
                "[openrgb] connect failed "
                f"(SDK 需已常驻 6742，本进程不会启动 OpenRGB): {exc}"
            )
            self._schedule_retry()
            return False

    def _prepare_device(self, dev: Any) -> None:
        """切 Direct，并把 D_LED 这类可变长分区 resize 到配置的灯珠数。"""
        try:
            mode_names = [m.name for m in dev.modes]
            if self.mode in mode_names:
                dev.set_mode(self.mode)
        except (OSError, ValueError, RuntimeError) as exc:
            print(f"[openrgb] set_mode {dev.name} fail {exc}")
        for zone in getattr(dev, "zones", []):
            want = self.zone_sizes.get(str(zone.name).strip().lower())
            if want is None:
                continue
            current = len(getattr(zone, "leds", []) or [])
            if current == want:
                print(f"[openrgb] zone {zone.name} already {want} leds")
                continue
            try:
                zone.resize(want)
                print(f"[openrgb] resized {zone.name} {current} -> {want}")
            except (OSError, ValueError, RuntimeError) as exc:
                print(f"[openrgb] resize {zone.name} -> {want} fail {exc}")

    def push(self, rgb: np.ndarray) -> bool:
        if not self.enabled:
            return False
        if self.cli is None and not self._try_connect():
            return False
        if (
            not self.last_off
            and self.last_rgb is not None
            and color_delta(rgb, self.last_rgb) < 3
        ):
            return False
        scale = self.brightness / 100.0
        rgb_br = np.clip(np.rint(rgb.astype(np.float64) * scale), 0, 255).astype(int)
        color = self.RGBColor(int(rgb_br[0]), int(rgb_br[1]), int(rgb_br[2]))
        ok = False
        for dev in self.devs:
            try:
                dev.set_color(color, fast=True)
                ok = True
            except (OSError, RuntimeError, ValueError) as exc:
                print(f"[openrgb] set_color {dev.name} fail {exc}")
        if ok:
            self.last_rgb = rgb.copy()
            self.last_off = False
        else:
            # 写灯失败多半是 SDK 断了；丢掉连接，下次 push 再握手。
            self._close_cli()
            self._schedule_retry()
        return ok

    def needs_retry(self, rgb: np.ndarray) -> bool:
        """已启用但上次没推上当前色时，主循环不能因阈值跳过。"""
        if not self.enabled:
            return False
        if self.cli is None:
            # 还在等 SDK：让主循环继续走 push，而不是当「颜色没变」睡过去。
            return True
        if self.last_off or self.last_rgb is None:
            return True
        return color_delta(rgb, self.last_rgb) >= 3

    def off(self) -> bool:
        if not self.enabled:
            return False
        if self.cli is None and not self._try_connect():
            return False
        if self.last_off:
            return False
        color = self.RGBColor(0, 0, 0)
        ok = False
        for dev in self.devs:
            try:
                dev.set_color(color, fast=True)
                ok = True
            except (OSError, RuntimeError, ValueError) as exc:
                print(f"[openrgb] off {dev.name} fail {exc}")
        if ok:
            self.last_off = True
            self.last_rgb = np.array([0, 0, 0], dtype=np.int32)
        return ok

    def close(self) -> None:
        self._close_cli()


def _resolve_hi75_exe(raw: Any) -> Path | None:
    """config.exe 相对 tools/rgb；空字符串表示本进程直接 HID。"""
    text = str(raw or "").strip()
    if not text:
        return None
    path = Path(text)
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


class Hi75Wrap:
    def __init__(
        self,
        enabled: bool,
        brightness: int = 100,
        path: str = "auto",
        min_interval_s: float = 0.12,
        min_delta: float = 18.0,
        settle_s: float = 0.18,
        settle_delta: float = 14.0,
        stable_frames: int = 2,
        keepalive_s: float = 0.70,
        led_count: int = 120,
        exe: Any = "",
    ) -> None:
        self.enabled = enabled
        self.brightness = max(0, min(100, brightness))
        self.path = path
        # Direct 0x08 不闪，可以比静态 0x0a 更勤；风扇走 OpenRGB 仍可更勤
        self.min_interval_s = max(0.0, min_interval_s)
        self.min_delta = max(0.0, min_delta)
        # 切窗口会先冒过渡色；等目标色连续稳定再发，避免先灰后白
        self.settle_s = max(0.0, settle_s)
        self.settle_delta = max(0.0, settle_delta)
        self.stable_needed = max(1, stable_frames)
        # OpenRGB 注释：010C Direct 约 1s 不刷新会掉回板载灯效
        self.keepalive_s = max(0.2, keepalive_s)
        self.led_count = max(1, led_count)
        self.exe_path = _resolve_hi75_exe(exe)
        self.dev: Any = None
        self.proc: subprocess.Popen[str] | None = None
        self.info: dict[str, Any] | None = None
        self.last_rgb: np.ndarray | None = None
        self.last_off = False
        self.last_push_t = 0.0
        self.last_dark_t = 0.0
        self.pending_rgb: np.ndarray | None = None
        self.pending_since = 0.0
        self.pending_frames = 0
        if not enabled:
            print("[hi75] disabled")
            return
        if self.exe_path is not None:
            self._start_exe()
            return
        try:
            self.dev, self.info = open_hi75(self.path)
            path_text = ""
            if self.info is not None:
                raw = self.info.get("path", b"")
                path_text = raw.decode("utf-8", errors="ignore") if isinstance(raw, bytes) else str(raw)
            print(
                f"[hi75] opened {path_text} Col06={'COL06' in path_text.upper()} "
                f"direct=0x08 leds={self.led_count} keepalive={self.keepalive_s:.2f}s "
                f"min_interval={self.min_interval_s:.2f}s min_delta={self.min_delta:.0f} "
                f"settle={self.settle_s:.2f}s/{self.stable_needed}f"
            )
        except (OSError, RuntimeError, ValueError) as exc:
            print(f"[hi75] open failed: {exc}")
            self.enabled = False
            self.dev = None

    def _start_exe(self) -> None:
        exe = self.exe_path
        if exe is None or not exe.is_file():
            print(f"[hi75] exe missing: {exe}")
            self.enabled = False
            return
        cmd = [
            str(exe),
            "--serve",
            "--path",
            self.path,
            "--leds",
            str(self.led_count),
            "--keepalive",
            f"{self.keepalive_s:.2f}",
        ]
        # CREATE_NO_WINDOW 只能藏 CUI 窗口，挡不住 Win11 默认终端接走 conhost。
        # 根治是 hi75.exe 打成 --noconsole（WINDOWS_GUI）；这里再加 SW_HIDE 防旧包。
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        startupinfo = None
        if sys.platform == "win32":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = getattr(subprocess, "SW_HIDE", 0)
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                cwd=str(exe.parent),
                creationflags=flags,
                startupinfo=startupinfo,
            )
        except OSError as exc:
            print(f"[hi75] spawn {exe} failed: {exc}")
            self.enabled = False
            self.proc = None
            return
        err_proc = self.proc

        def _drain_stderr() -> None:
            if err_proc.stderr is None:
                return
            try:
                for line in err_proc.stderr:
                    text = line.rstrip()
                    if text:
                        print(f"[hi75-exe] {text}")
            except OSError:
                pass

        threading.Thread(target=_drain_stderr, name="hi75-exe-err", daemon=True).start()
        ready = self._read_until(prefix="READY", timeout_s=8.0)
        if ready is None or ready.startswith("ERR"):
            code = self.proc.poll()
            print(f"[hi75] exe no READY, exit={code} msg={ready}")
            self._kill_exe()
            self.enabled = False
            return
        print(
            f"[hi75] exe={exe.name} {ready} "
            f"min_interval={self.min_interval_s:.2f}s min_delta={self.min_delta:.0f} "
            f"settle={self.settle_s:.2f}s/{self.stable_needed}f"
        )

    def _kill_exe(self) -> None:
        proc = self.proc
        self.proc = None
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=1.5)
        except (OSError, subprocess.TimeoutExpired):
            try:
                proc.kill()
            except OSError:
                pass

    def _read_until(self, prefix: str, timeout_s: float) -> str | None:
        if self.proc is None or self.proc.stdout is None:
            return None
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                return None
            line = self.proc.stdout.readline()
            if not line:
                return None
            text = line.strip()
            if text.startswith(prefix) or text.startswith("ERR"):
                return text
        return None

    def _rpc(self, command: str) -> str:
        if self.proc is None or self.proc.stdin is None or self.proc.stdout is None:
            raise RuntimeError("hi75 exe not running")
        if self.proc.poll() is not None:
            raise RuntimeError(f"hi75 exe exited {self.proc.returncode}")
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()
        reply = self._read_until(prefix="OK", timeout_s=2.0)
        if reply is None:
            raise TimeoutError(f"rpc timeout: {command}")
        if reply.startswith("ERR"):
            raise RuntimeError(reply[4:].strip() or reply)
        return reply

    def note_dark(self) -> None:
        """切场黑帧：丢掉未发出的过渡色，避免黑→灰→白连发两包。"""
        self.pending_rgb = None
        self.pending_frames = 0
        self.last_dark_t = time.monotonic()

    def _scaled_rgb(self, rgb: np.ndarray) -> tuple[int, int, int]:
        scale = self.brightness / 100.0
        r = int(np.clip(np.rint(float(rgb[0]) * scale), 0, 255))
        g = int(np.clip(np.rint(float(rgb[1]) * scale), 0, 255))
        b = int(np.clip(np.rint(float(rgb[2]) * scale), 0, 255))
        return r, g, b

    def _backend_ready(self) -> bool:
        if self.proc is not None:
            return self.proc.poll() is None
        return self.dev is not None

    def _send(self, rgb: np.ndarray, now: float, *, keepalive: bool = False) -> bool:
        if not self._backend_ready():
            return False
        r, g, b = self._scaled_rgb(rgb)
        try:
            if self.proc is not None:
                self._rpc(f"SET {r:02x}{g:02x}{b:02x}")
            else:
                report = build_direct_report(r, g, b, self.led_count)
                send_feature_reports(self.dev, [report], delay_s=0.0, verbose=False)
            self.last_rgb = rgb.copy()
            self.last_off = False
            self.last_push_t = now
            self.pending_rgb = None
            self.pending_frames = 0
            if not keepalive:
                print(f"[hi75] #{r:02x}{g:02x}{b:02x} direct")
            return True
        except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
            print(f"[hi75] push fail {exc}")
            return False

    def keepalive(self) -> bool:
        """Direct 模式必须定期重发当前色，否则约 1s 掉回板载灯效。"""
        # exe --serve 自己保活，父进程不必重发
        if self.proc is not None:
            return False
        if not self.enabled or self.dev is None or self.last_off:
            return False
        if self.last_rgb is None:
            return False
        now = time.monotonic()
        if (now - self.last_push_t) < self.keepalive_s:
            return False
        return self._send(self.last_rgb, now, keepalive=True)

    def push(self, rgb: np.ndarray) -> bool:
        if not self.enabled or not self._backend_ready():
            return False
        now = time.monotonic()
        # 开灯 / 从 off 恢复：立刻发 Direct
        if self.last_off or self.last_rgb is None:
            return self._send(rgb, now)
        if color_delta(rgb, self.last_rgb) < self.min_delta:
            self.pending_rgb = None
            self.pending_frames = 0
            return False
        # 颜色还在动就重置；切窗口动画结束、连续几帧同色才发包
        if (
            self.pending_rgb is None
            or color_delta(rgb, self.pending_rgb) >= self.settle_delta
        ):
            self.pending_rgb = rgb.copy()
            self.pending_since = now
            self.pending_frames = 1
            return False
        self.pending_frames += 1
        self.pending_rgb = rgb.copy()
        settled = self.pending_frames >= self.stable_needed
        if self.settle_s > 0:
            settled = settled and (now - self.pending_since) >= self.settle_s
        if not settled:
            return False
        # 刚离开黑场时窗口动画还没结束，再等一拍
        if self.settle_s > 0 and (now - self.last_dark_t) < self.settle_s:
            return False
        if self.min_interval_s > 0 and (now - self.last_push_t) < self.min_interval_s:
            return False
        return self._send(rgb, now)

    def needs_retry(self, rgb: np.ndarray) -> bool:
        """颜色已变但还在等 settle / 间隔时，主循环不能睡过去。"""
        if not self.enabled or not self._backend_ready():
            return False
        if self.last_off or self.last_rgb is None:
            return True
        if self.pending_rgb is not None:
            return True
        return color_delta(rgb, self.last_rgb) >= self.min_delta

    def off(self) -> bool:
        # Direct 关灯发全黑 0x08，不要走 complete_off（会退出 Direct）
        if not self.enabled or not self._backend_ready():
            return False
        if self.last_off:
            return False
        if self.proc is not None:
            try:
                self._rpc("OFF")
                self.last_off = True
                self.last_rgb = np.array([0, 0, 0], dtype=np.int32)
                self.last_push_t = time.monotonic()
                return True
            except (OSError, RuntimeError, TimeoutError) as exc:
                print(f"[hi75] off fail {exc}")
                return False
        black = np.array([0, 0, 0], dtype=np.int32)
        ok = self._send(black, time.monotonic())
        if ok:
            self.last_off = True
        return ok

    def close(self) -> None:
        if self.proc is not None:
            try:
                if self.proc.stdin is not None and self.proc.poll() is None:
                    self.proc.stdin.write("QUIT\n")
                    self.proc.stdin.flush()
                    self.proc.wait(timeout=1.5)
            except (OSError, subprocess.TimeoutExpired):
                pass
            self._kill_exe()
        if self.dev is None:
            return
        try:
            self.dev.close()
        except OSError:
            pass
        self.dev = None


def list_devices() -> int:
    try:
        from openrgb import OpenRGBClient

        cli = OpenRGBClient(address="127.0.0.1", port=6742, name="lat3ncy-ambient-list")
        print(f"OpenRGB {len(cli.devices)} devices:")
        for dev in cli.devices:
            print(f"  {dev.name} {dev.type}")
        try:
            cli.disconnect()
        except OSError:
            pass
    except Exception as exc:
        print(f"OpenRGB list fail (SDK 未常驻则属正常): {exc}")
    try:
        devs, ff = enumerate_hi75()
        print(f"Hi75 {len(devs)} HID, FF00 {len(ff)}")
        return 0
    except Exception as exc:
        print(f"Hi75 list fail: {exc}")
        return 1


def _sleep_remaining(t0: float, interval: float) -> None:
    remain = interval - (time.monotonic() - t0)
    if remain > 0:
        time.sleep(remain)


def main() -> int:
    ap = argparse.ArgumentParser(description="Ambient - desktop color -> fans+keyboard")
    ap.add_argument("--config", default=str(CONFIG_PATH))
    ap.add_argument("--dry-run", action="store_true", help="只算色不推灯")
    ap.add_argument("--fps", type=int, help="override fps_active")
    ap.add_argument("--no-openrgb", action="store_true")
    ap.add_argument("--no-hi75", action="store_true")
    ap.add_argument("--list-devices", action="store_true")
    ap.add_argument("--time", type=float, default=0, help="run seconds (0=forever)")
    ap.add_argument(
        "--bench",
        type=int,
        help="默认跑 process_frame 合成帧压测，不抓屏、不连 OpenRGB/HID、不写灯",
    )
    ap.add_argument(
        "--bench-capture",
        action="store_true",
        help="配合 --bench：改测真实抓屏。无交互桌面时 mss BitBlt 会失败",
    )
    args = ap.parse_args()

    cfg_path = Path(args.config)
    cfg = load_config(cfg_path if cfg_path.is_file() else CONFIG_PATH)
    cap_cfg = _section(cfg, "capture")
    proc_cfg = _section(cfg, "process")
    openrgb_cfg = _section(cfg, "openrgb")
    hi75_cfg = _section(cfg, "hi75")
    behavior_cfg = _section(cfg, "behavior")

    if args.fps:
        cap_cfg["fps_active"] = args.fps
    if args.no_openrgb:
        openrgb_cfg["enabled"] = False
    if args.no_hi75:
        hi75_cfg["enabled"] = False
    cfg["capture"] = cap_cfg
    cfg["openrgb"] = openrgb_cfg
    cfg["hi75"] = hi75_cfg

    if args.list_devices:
        return list_devices()

    if args.bench:
        n = max(1, args.bench)
        if args.bench_capture:
            cap, backend = create_capture(cfg)
            t0 = time.perf_counter()
            grabbed = 0
            try:
                for _ in range(n):
                    arr = cap.grab()
                    if arr is None:
                        continue
                    _ = arr.mean(axis=(0, 1))
                    grabbed += 1
            finally:
                cap.stop()
            dt = time.perf_counter() - t0
            if grabbed == 0 or dt <= 0:
                print(f"bench-capture {backend} no frames")
                return 1
            print(
                f"bench-capture {backend} {grabbed} frames in {dt:.3f}s = "
                f"{grabbed / dt:.1f} fps, {dt / grabbed * 1000:.2f} ms/frame"
            )
            return 0

        # 合成帧：只跑均色路径，不抓屏、不连 SDK、不写灯。
        # 变量名避开后面主循环的 ema，避免同一函数里重复声明。
        frame = np.zeros((45, 80, 3), dtype=np.uint8)
        frame[:, :] = (32, 96, 180)
        bench_ema: np.ndarray | None = None
        t0 = time.perf_counter()
        processed = 0
        for i in range(n):
            frame[0, 0] = (i * 7) % 256
            bench_ema, rgb, _bri = process_frame(frame, bench_ema, 0.18, 22.0)
            if rgb is not None:
                processed += 1
        dt = time.perf_counter() - t0
        if dt <= 0:
            print("bench-synthetic no time")
            return 1
        print(
            f"bench-synthetic process_frame {n} frames ({processed} emitted) in {dt:.3f}s = "
            f"{n / dt:.1f} fps, {dt / n * 1000:.2f} ms/frame "
            "(no capture, no OpenRGB, no HID)"
        )
        return 0

    fps_active = max(1, _as_int(cap_cfg.get("fps_active", 8), 8))
    fps_idle = max(1, _as_int(cap_cfg.get("fps_idle", 4), 4))
    threshold = _as_float(cap_cfg.get("threshold", 8), 8.0)
    ema_alpha = _as_float(proc_cfg.get("ema_alpha", 0.35), 0.35)
    min_bri = _as_float(proc_cfg.get("min_brightness", 16), 16.0)
    sat_boost = _as_float(proc_cfg.get("saturation_boost", 1.6), 1.6)
    gamma = _as_float(proc_cfg.get("gamma", 1.0), 1.0)
    # lerp_alpha=1 表示关闭二次插值；<1 才做输出平滑
    lerp_alpha = min(1.0, max(0.05, _as_float(proc_cfg.get("lerp_alpha", 1.0), 1.0)))
    auto_off = _as_bool(proc_cfg.get("auto_off", False), False)
    off_bri = max(0.0, _as_float(proc_cfg.get("off_brightness", 2), 2.0))
    off_hold_s = max(0.0, _as_float(proc_cfg.get("off_hold_s", 8.0), 8.0))
    min_valid_ratio = min(
        1.0, max(0.0, _as_float(proc_cfg.get("min_valid_ratio", 0.08), 0.08))
    )
    snap_delta = max(0.0, _as_float(proc_cfg.get("snap_delta", 40.0), 40.0))
    idle_timeout = _as_float(behavior_cfg.get("idle_timeout", 3.0), 3.0)
    log_interval = _as_float(behavior_cfg.get("log_interval", 5.0), 5.0)
    hi75_min_interval = max(
        0.0, _as_float(hi75_cfg.get("min_interval_s", 0.12), 0.12)
    )
    hi75_min_delta = max(0.0, _as_float(hi75_cfg.get("min_delta", 18.0), 18.0))
    hi75_settle_s = max(0.0, _as_float(hi75_cfg.get("settle_s", 0.18), 0.18))
    hi75_settle_delta = max(
        0.0, _as_float(hi75_cfg.get("settle_delta", 14.0), 14.0)
    )
    hi75_stable_frames = max(1, _as_int(hi75_cfg.get("stable_frames", 2), 2))
    hi75_keepalive_s = max(0.2, _as_float(hi75_cfg.get("keepalive_s", 0.70), 0.70))
    hi75_led_count = max(1, _as_int(hi75_cfg.get("led_count", 120), 120))
    hi75_exe = str(hi75_cfg.get("exe", "") or "")

    cap, backend = create_capture(cfg)
    print(
        f"[ambient] backend={backend} fps_active={fps_active} "
        f"fps_idle={fps_idle} threshold={threshold} "
        f"ema={ema_alpha} lerp={lerp_alpha} min_bri={min_bri}"
    )

    openrgb = OpenRGBWrap(
        enabled=not args.dry_run and _as_bool(openrgb_cfg.get("enabled", True), True),
        brightness=_as_int(openrgb_cfg.get("brightness", 80), 80),
        mode=str(openrgb_cfg.get("mode", "Direct") or "Direct"),
        match=openrgb_cfg.get("device_match", DEFAULT_OPENRGB_MATCH),
        zone_sizes=openrgb_cfg.get("zone_sizes", {}),
    )
    hi75 = Hi75Wrap(
        enabled=not args.dry_run and _as_bool(hi75_cfg.get("enabled", True), True),
        brightness=_as_int(hi75_cfg.get("brightness", 100), 100),
        path=str(hi75_cfg.get("path", "auto") or "auto"),
        min_interval_s=hi75_min_interval,
        min_delta=hi75_min_delta,
        settle_s=hi75_settle_s,
        settle_delta=hi75_settle_delta,
        stable_frames=hi75_stable_frames,
        keepalive_s=hi75_keepalive_s,
        led_count=hi75_led_count,
        exe=hi75_exe,
    )

    ema: np.ndarray | None = None
    out_rgb: np.ndarray | None = None
    last_rgb: np.ndarray | None = None
    last_change = time.monotonic()
    last_bright = time.monotonic()
    last_log = 0.0
    fps = fps_active
    interval = 1.0 / fps
    pushes = 0
    frames = 0
    start = time.monotonic()
    should_run = True

    def handle_sig(_sig: int, _frame: Any) -> None:
        nonlocal should_run
        should_run = False

    signal.signal(signal.SIGINT, handle_sig)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, handle_sig)

    try:
        while should_run:
            if args.time and (time.monotonic() - start) > args.time:
                break
            t0 = time.monotonic()
            try:
                arr = cap.grab()
            except Exception as exc:
                # 抓屏异常不能冒泡：锁屏 BitBlt 曾经直接把 pythonw 打死，解锁后灯效不再更新。
                print(f"[capture] grab failed: {_capture_error_hint(exc)}")
                arr = None
            frames += 1
            if arr is None:
                now = time.monotonic()
                # 保持上一色：Direct 约 1s 不刷新会掉回板载灯效。
                if hi75.keepalive():
                    pass
                if now - last_change > idle_timeout and fps != fps_idle:
                    fps = fps_idle
                    interval = 1.0 / fps
                if now - last_log >= log_interval:
                    print(
                        f"[{frames} frames {pushes} pushes] skip-grab "
                        f"fps={fps} backend={backend}"
                    )
                    last_log = now
                _sleep_remaining(t0, interval)
                continue

            ema, rgb, bri = process_frame(
                arr,
                ema,
                ema_alpha,
                min_bri,
                saturation_boost=sat_boost,
                gamma=gamma,
                min_valid_ratio=min_valid_ratio,
                snap_delta=snap_delta,
            )

            now = time.monotonic()
            if rgb is None:
                # 切场黑场：保持上一色，丢掉未发出的过渡色；Direct 仍要 keepalive
                hi75.note_dark()
                if hi75.keepalive():
                    pass
                if now - last_change > idle_timeout and fps != fps_idle:
                    fps = fps_idle
                    interval = 1.0 / fps
                if (
                    auto_off
                    and out_rgb is not None
                    and (now - last_bright) >= off_hold_s
                    and bri < off_bri
                ):
                    if not args.dry_run:
                        if openrgb.off():
                            pushes += 1
                        if hi75.off():
                            pushes += 1
                    elif now - last_log >= log_interval:
                        print(f"dry dark bri={bri:.0f} (lights off)")
                        last_log = now
                    last_rgb = None
                elif now - last_log >= log_interval:
                    print(
                        f"[{frames} frames {pushes} pushes] skip-dark "
                        f"bri={bri:.0f} fps={fps} backend={backend}"
                    )
                    last_log = now
                _sleep_remaining(t0, interval)
                continue

            last_bright = now
            if lerp_alpha >= 0.999:
                # 关闭二次插值：颜色只走 EMA，避免每帧都跨过 threshold
                out_rgb = rgb.astype(np.float64)
            elif out_rgb is None:
                out_rgb = rgb.astype(np.float64)
            else:
                out_rgb = out_rgb * (1.0 - lerp_alpha) + rgb.astype(np.float64) * lerp_alpha
            # 走 ndarray.clip，避开 np.clip 对 NDArray[Any] 只匹配标量重载的桩问题。
            blended = np.asarray(out_rgb, dtype=np.float64)
            rgb = np.rint(blended).clip(0, 255).astype(np.int32)

            color_changed = last_rgb is None or color_delta(rgb, last_rgb) >= threshold
            pending_retry = openrgb.needs_retry(rgb) or hi75.needs_retry(rgb)
            if not color_changed and not pending_retry:
                if hi75.keepalive():
                    pass
                if now - last_change > idle_timeout and fps != fps_idle:
                    fps = fps_idle
                    interval = 1.0 / fps
                _sleep_remaining(t0, interval)
                continue

            if color_changed:
                last_change = now
                if fps != fps_active:
                    fps = fps_active
                    interval = 1.0 / fps
            elif now - last_change > idle_timeout and fps != fps_idle:
                # 仅重试失败设备时降频，避免空转 8Hz
                fps = fps_idle
                interval = 1.0 / fps

            if args.dry_run:
                if now - last_log >= log_interval:
                    print(
                        f"dry rgb=#{int(rgb[0]):02x}{int(rgb[1]):02x}{int(rgb[2]):02x} "
                        f"bri={bri:.0f}"
                    )
                    last_log = now
                last_rgb = rgb
            else:
                pushed = False
                # 键盘先推：OpenRGB 握手最多堵 3s，不能把 Hi75 首帧一起拖死。
                # 两路独立成功状态：一路失败不影响另一路重试。
                if hi75.push(rgb):
                    pushed = True
                else:
                    # settle 等待期间也要刷 Direct，否则约 1s 掉回板载灯效
                    hi75.keepalive()
                if openrgb.push(rgb):
                    pushed = True
                if pushed:
                    pushes += 1
                    last_rgb = rgb
                    if now - last_log >= log_interval:
                        print(
                            f"[{frames} frames {pushes} pushes] "
                            f"rgb=#{int(rgb[0]):02x}{int(rgb[1]):02x}{int(rgb[2]):02x} "
                            f"bri={bri:.0f} fps={fps} backend={backend}"
                        )
                        last_log = now

            _sleep_remaining(t0, interval)
    finally:
        cap.stop()
        openrgb.close()
        hi75.close()
        print(
            f"[ambient] done frames={frames} pushes={pushes} "
            f"time={time.monotonic() - start:.1f}s"
        )
    return 0


if __name__ == "__main__":
    _attach_file_logs()
    raise SystemExit(main())
