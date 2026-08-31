#!/usr/bin/env python3
"""
Hi75 最小 HID 控制（SinoWealth 258A:010C，Feature Report 520B）。

只走 hidapi Feature Report，不依赖、也不启动 OpenRGB。
报文来自 OpenRGB #4297 USBPcap：0684 / 0604 / 060a 各 520 字节。
"""
from __future__ import annotations

import argparse
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

def _frozen() -> bool:
    """PyInstaller --onedir/--onefile 都会设 sys.frozen，资源在 _MEIPASS。"""
    return bool(getattr(sys, "frozen", False))


def _app_dir() -> Path:
    if _frozen():
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def _bundle_dir() -> Path:
    if _frozen():
        meipass = getattr(sys, "_MEIPASS", None)
        if meipass:
            return Path(str(meipass))
    return _app_dir()


# 源码模式：lib_hid/hid.pyd 必须排在 lib/hid（缺 hidapi.dll 的 ctypes 包）前面
# 冻结后 hid.pyd 已打进包，不要再改 sys.path
if not _frozen():
    _hid_lib = str(_app_dir() / "lib_hid")
    if _hid_lib not in sys.path:
        sys.path.insert(0, _hid_lib)

import hid  # noqa: E402  # cython hidapi：hid.device() / hid.enumerate()

VID = 0x258A
PID = 0x010C
REPORT_LEN = 520
REPORT_ID = 0x06
USAGE_PAGE_RGB = 65280  # 0xFF00
# 静态 0x0a 模板：优先用冻结包内 hi75_data，其次 exe 旁的目录（方便换键盘不重编）
_bundled_data = _bundle_dir() / "hi75_data"
_sidecar_data = _app_dir() / "hi75_data"
DATA_DIR = _sidecar_data if _sidecar_data.is_dir() else _bundled_data

# feat2 里 5 组静态色（pcap 差分），字节序为 R,G,B
COLOR_TRIPLES: tuple[tuple[int, int, int], ...] = (
    (29, 30, 31),
    (93, 94, 95),
    (114, 115, 116),
    (135, 136, 137),
    (156, 157, 158),
)

# OpenRGB SinowealthKeyboard10c Direct：cmd=0x08，从偏移 8 起每灯 3 字节 RGB
# 静态 0x0a 每次 SetFeature 都会重放灯效（肉眼就是闪）；Direct 只刷新帧缓冲
DIRECT_CMD = 0x08
DIRECT_LED_OFFSET = 8
# 75% 稀疏索引大约到 89；多填同色无害，少填会有键不亮
DEFAULT_LED_COUNT = 120


@dataclass(frozen=True, slots=True)
class Hi75Templates:
    """三段 Feature Report 模板。on/off 的 feat0 分开，避免关灯仍带红色 feat2。"""

    feat0_on: bytes
    feat0_off: bytes
    feat1_on: bytes
    feat1_off: bytes
    feat2_red: bytes
    feat2_green: bytes
    feat2_white: bytes
    feat2_off: bytes


_templates: Hi75Templates | None = None


def _path_text(path: bytes | str) -> str:
    if isinstance(path, bytes):
        return path.decode("utf-8", errors="ignore")
    return str(path)


def _path_bytes(path: bytes | str) -> bytes:
    if isinstance(path, bytes):
        return path
    return path.encode("utf-8")


def load_feat(name: str) -> bytes:
    """从 hi75_data 读 520B Feature Report，并校验 Report ID。"""
    path = DATA_DIR / name
    if not path.is_file():
        raise FileNotFoundError(f"missing {path}")
    data = path.read_bytes()
    if len(data) != REPORT_LEN:
        raise ValueError(f"{name} len {len(data)} != {REPORT_LEN}")
    if data[0] != REPORT_ID:
        raise ValueError(f"{name} report id 0x{data[0]:02x} != 0x{REPORT_ID:02x}")
    return data


def get_templates() -> Hi75Templates:
    """懒加载模板；缺文件时抛错，避免模块 import 就打印半初始化状态。"""
    global _templates
    if _templates is None:
        _templates = Hi75Templates(
            feat0_on=load_feat("static_red_feat0.bin"),
            feat0_off=load_feat("complete_off_feat0.bin"),
            feat1_on=load_feat("static_red_feat1.bin"),
            feat1_off=load_feat("complete_off_feat1.bin"),
            feat2_red=load_feat("static_red_feat2.bin"),
            feat2_green=load_feat("static_green_feat2.bin"),
            feat2_white=load_feat("static_white_feat2.bin"),
            feat2_off=load_feat("complete_off_feat2.bin"),
        )
    return _templates


def enumerate_hi75() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """返回 (全部 HID, FF00 RGB 接口)。"""
    devs = hid.enumerate(VID, PID)
    ff = [d for d in devs if d.get("usage_page") == USAGE_PAGE_RGB]
    return devs, ff


def _col_sort_key(device: dict[str, Any]) -> int:
    """Col06 才能 SetFeature 520B；Col05/03 会返回 -1 / 0x01。"""
    text = _path_text(device.get("path", b"")).upper()
    if "COL06" in text:
        return 0
    if "COL05" in text:
        return 1
    return 2


def _close_quiet(dev: Any) -> None:
    close = getattr(dev, "close", None)
    if close is None:
        return
    try:
        close()
    except OSError:
        pass


def open_hi75(preferred_path: str = "auto") -> tuple[Any, dict[str, Any]]:
    """
    打开 Hi75 的 FF00 接口。
    preferred_path=auto 时按 Col06 > Col05 > 其它；否则打开指定 HID path。
    """
    devs, ff = enumerate_hi75()
    if preferred_path and preferred_path.strip().lower() not in {"", "auto"}:
        want = preferred_path.strip()
        match = next(
            (d for d in devs if _path_text(d.get("path", b"")) == want),
            None,
        )
        if match is None:
            raise RuntimeError(f"未找到指定 HID 路径: {want}")
        candidates = [match]
    else:
        if not ff:
            raise RuntimeError(
                "未找到 Hi75 的 FF00 HID 接口，请确认键盘有线连接且未被 OpenRGB/官方驱动独占"
            )
        candidates = sorted(ff, key=_col_sort_key)

    last_err: BaseException | None = None
    for info in candidates:
        handle = hid.device()
        try:
            handle.open_path(_path_bytes(info["path"]))
            return handle, info
        except (OSError, ValueError, RuntimeError) as exc:
            last_err = exc
            print(
                f"open {_path_text(info.get('path', b''))} failed: {exc}",
                file=sys.stderr,
            )
            _close_quiet(handle)
    raise RuntimeError(f"所有候选接口打开失败: {last_err}")


def send_feature_reports(
    dev: Any,
    reports: list[bytes],
    *,
    delay_s: float = 0.06,
    verbose: bool = True,
) -> None:
    """按顺序发送 520B Feature Report。ret==-1 视为失败。"""
    for i, data in enumerate(reports):
        if len(data) != REPORT_LEN:
            raise ValueError(f"report {i} len {len(data)} != {REPORT_LEN}")
        ret = dev.send_feature_report(data)
        if ret == -1:
            err = ""
            error_fn = getattr(dev, "error", None)
            if callable(error_fn):
                err = str(error_fn())
            raise RuntimeError(f"send_feature_report {i} failed {err}".strip())
        if verbose:
            print(
                f"  -> report {i} sent {ret} bytes "
                f"(id=0x{data[0]:02x} cmd=0x{data[1]:02x})"
            )
        if delay_s > 0:
            time.sleep(delay_s)


def patch_feat2_color(base: bytes, r: int, g: int, b: int) -> bytes:
    """把 feat2 (060a) 的 5 组色点改成指定 RGB。"""
    if not (0 <= r <= 255 and 0 <= g <= 255 and 0 <= b <= 255):
        raise ValueError(f"RGB out of range: {(r, g, b)}")
    ba = bytearray(base)
    for o0, o1, o2 in COLOR_TRIPLES:
        ba[o0] = r
        ba[o1] = g
        ba[o2] = b
    return bytes(ba)


def apply_brightness(feat2: bytes, brightness: int) -> bytes:
    """按 0-100 缩放 feat2 色点，100 为原样。"""
    if brightness >= 100:
        return feat2
    if brightness <= 0:
        return patch_feat2_color(feat2, 0, 0, 0)
    scale = brightness / 100.0
    ba = bytearray(feat2)
    for o0, o1, o2 in COLOR_TRIPLES:
        ba[o0] = int(ba[o0] * scale)
        ba[o1] = int(ba[o1] * scale)
        ba[o2] = int(ba[o2] * scale)
    return bytes(ba)


def build_direct_report(r: int, g: int, b: int, led_count: int = DEFAULT_LED_COUNT) -> bytes:
    """构造 OpenRGB Direct 报文：06 08 .... 从偏移 8 起填 RGB。

    官方静态 0x0a 会重放灯效，换色必闪。Direct 0x08 只刷帧缓冲，可无缝换色。
    固件约 1 秒不刷新会掉回板载灯效，调用方需要 keepalive。
    """
    r = _clamp_channel("R", r)
    g = _clamp_channel("G", g)
    b = _clamp_channel("B", b)
    count = max(1, min(led_count, (REPORT_LEN - DIRECT_LED_OFFSET) // 3))
    buf = bytearray(REPORT_LEN)
    buf[0] = REPORT_ID
    buf[1] = DIRECT_CMD
    buf[4] = 0x01
    buf[6] = 0x7A
    buf[7] = 0x01
    for i in range(count):
        off = DIRECT_LED_OFFSET + i * 3
        buf[off] = r
        buf[off + 1] = g
        buf[off + 2] = b
    return bytes(buf)


def parse_hex_color(text: str) -> tuple[int, int, int]:
    raw = text.strip().removeprefix("#")
    if len(raw) != 6:
        raise ValueError(f"颜色必须是 6 位 hex，收到 {text!r}")
    try:
        return int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16)
    except ValueError as exc:
        raise ValueError(f"无效 hex 颜色: {text!r}") from exc


def _clamp_channel(name: str, value: int) -> int:
    if not 0 <= value <= 255:
        raise ValueError(f"{name} 必须是 0-255，收到 {value}")
    return value


def set_direct_color(
    r: int,
    g: int,
    b: int,
    preferred_path: str = "auto",
    hold_s: float = 0.0,
    led_count: int = DEFAULT_LED_COUNT,
) -> None:
    """发 Direct 0x08。hold_s>0 时按 0.7s 保活，方便肉眼确认是否还闪。"""
    r = _clamp_channel("R", r)
    g = _clamp_channel("G", g)
    b = _clamp_channel("B", b)
    print(f"Setting Hi75 Direct #{r:02x}{g:02x}{b:02x} leds={led_count}")
    dev, info = open_hi75(preferred_path)
    print(
        f"Opened {_path_text(info.get('path', b''))} "
        f"up={info.get('usage_page')} if={info.get('interface_number')}"
    )
    report = build_direct_report(r, g, b, led_count)
    try:
        send_feature_reports(dev, [report], delay_s=0.0)
        if hold_s <= 0:
            print("Direct sent. 固件约 1s 无刷新会掉回板载灯效")
            return
        deadline = time.monotonic() + hold_s
        while time.monotonic() < deadline:
            time.sleep(0.7)
            send_feature_reports(dev, [report], delay_s=0.0, verbose=False)
        print(f"Direct held {hold_s:.1f}s")
    finally:
        _close_quiet(dev)


def set_static_color(r: int, g: int, b: int, preferred_path: str = "auto") -> None:
    r = _clamp_channel("R", r)
    g = _clamp_channel("G", g)
    b = _clamp_channel("B", b)
    print(f"Setting Hi75 static color #{r:02x}{g:02x}{b:02x}")
    templates = get_templates()
    dev, info = open_hi75(preferred_path)
    print(
        f"Opened {_path_text(info.get('path', b''))} "
        f"up={info.get('usage_page')} if={info.get('interface_number')}"
    )
    try:
        feat2 = patch_feat2_color(templates.feat2_red, r, g, b)
        print(
            f"  patched feat2[29:32]={feat2[29]:02x}{feat2[30]:02x}{feat2[31]:02x} "
            f"(expected {r:02x}{g:02x}{b:02x})"
        )
        print(f"  feat2[93:96]={feat2[93]:02x}{feat2[94]:02x}{feat2[95]:02x}")
        send_feature_reports(dev, [templates.feat0_on, templates.feat1_on, feat2])
        print("Done. 若键盘未变色：1) 确认有线连接 2) 关闭 OpenRGB/官方驱动 3) 拔插后重跑")
    finally:
        _close_quiet(dev)


def set_off(preferred_path: str = "auto") -> None:
    """关灯必须用 complete_off 的三段，不能复用红色 feat2。"""
    print("Turning Hi75 off")
    templates = get_templates()
    dev, info = open_hi75(preferred_path)
    print(f"Opened {_path_text(info.get('path', b''))}")
    try:
        send_feature_reports(
            dev,
            [templates.feat0_off, templates.feat1_off, templates.feat2_off],
        )
        print("Off sent")
    finally:
        _close_quiet(dev)


def set_preset(name: str, preferred_path: str = "auto") -> None:
    templates = get_templates()
    mapping: dict[str, tuple[bytes, bytes, bytes]] = {
        "red": (templates.feat0_on, templates.feat1_on, templates.feat2_red),
        "green": (templates.feat0_on, templates.feat1_on, templates.feat2_green),
        "white": (templates.feat0_on, templates.feat1_on, templates.feat2_white),
        "off": (templates.feat0_off, templates.feat1_off, templates.feat2_off),
    }
    if name == "blue":
        set_static_color(0, 0, 255, preferred_path)
        return
    if name not in mapping:
        raise ValueError(f"unknown preset {name}")
    if name == "off":
        set_off(preferred_path)
        return
    dev, info = open_hi75(preferred_path)
    print(f"Opened {_path_text(info.get('path', b''))} preset {name}")
    try:
        send_feature_reports(dev, list(mapping[name]))
        print(f"Preset {name} done")
    finally:
        _close_quiet(dev)


def test_enumerate() -> None:
    devs, ff = enumerate_hi75()
    print(f"Found {len(devs)} HID devices for {VID:04x}:{PID:04x}, FF00={len(ff)}")
    for d in devs:
        up = d.get("usage_page")
        mark = " <-- RGB" if up == USAGE_PAGE_RGB else ""
        print(
            f"  path={_path_text(d.get('path', b''))} up={up} "
            f"us={d.get('usage')} if={d.get('interface_number')} "
            f"prod={d.get('product_string')}{mark}"
        )
    if not ff:
        print("未找到 FF00 接口，检查是否被占用或未用有线")


def _stdout(line: str) -> None:
    """serve 协议必须逐行 flush，否则父进程 readline 会卡住。"""
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def serve(
    preferred_path: str = "auto",
    led_count: int = DEFAULT_LED_COUNT,
    keepalive_s: float = 0.70,
) -> int:
    """stdin 行协议，给 ambient / 其它宿主当独立键盘进程用。

    命令：
      SET rrggbb   Direct 上色（内部按 keepalive_s 重发，父进程不用保活）
      OFF          Direct 全黑
      LIST         列出 HID
      PING         PONG
      QUIT         退出
    换键盘：换一份编好的 hi75.exe，或把另一套 hi75_data 放在 exe 旁边。
    """
    keepalive_s = max(0.2, float(keepalive_s))
    led_count = max(1, int(led_count))
    try:
        sys.stdout.reconfigure(line_buffering=True)  # type: ignore[attr-defined]
        sys.stdin.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except (AttributeError, OSError):
        pass

    try:
        dev, info = open_hi75(preferred_path)
    except (OSError, RuntimeError, ValueError) as exc:
        _stdout(f"ERR {exc}")
        return 1

    path_text = _path_text(info.get("path", b""))
    _stdout(
        f"READY path={path_text} leds={led_count} keepalive={keepalive_s:.2f} "
        f"direct=0x08 frozen={int(_frozen())}"
    )

    pending: list[str] = []
    lock = threading.Lock()
    stop = threading.Event()

    def _reader() -> None:
        try:
            for raw in sys.stdin:
                line = raw.strip()
                if not line:
                    continue
                with lock:
                    pending.append(line)
                if line.split(None, 1)[0].upper() in {"QUIT", "EXIT"}:
                    break
        except OSError:
            pass
        finally:
            stop.set()

    reader = threading.Thread(target=_reader, name="hi75-stdin", daemon=True)
    reader.start()

    last_rgb: tuple[int, int, int] | None = None
    last_off = False
    last_push = 0.0
    last_report: bytes | None = None

    def _send_rgb(r: int, g: int, b: int, *, as_off: bool = False) -> None:
        nonlocal last_rgb, last_off, last_push, last_report
        report = build_direct_report(r, g, b, led_count)
        send_feature_reports(dev, [report], delay_s=0.0, verbose=False)
        last_report = report
        last_rgb = (r, g, b)
        last_off = as_off
        last_push = time.monotonic()

    try:
        while not stop.is_set() or pending:
            cmd = ""
            with lock:
                if pending:
                    cmd = pending.pop(0)
            if cmd:
                parts = cmd.split()
                op = parts[0].upper()
                try:
                    if op in {"QUIT", "EXIT"}:
                        _stdout("BYE")
                        break
                    if op == "PING":
                        _stdout("PONG")
                    elif op == "LIST":
                        test_enumerate()
                        _stdout("OK LIST")
                    elif op == "OFF":
                        _send_rgb(0, 0, 0, as_off=True)
                        _stdout("OK #000000")
                    elif op == "SET":
                        if len(parts) < 2:
                            raise ValueError("SET 需要 rrggbb")
                        r, g, b = parse_hex_color(parts[1])
                        _send_rgb(r, g, b)
                        _stdout(f"OK #{r:02x}{g:02x}{b:02x}")
                    else:
                        _stdout(f"ERR unknown {op}")
                except (OSError, RuntimeError, ValueError) as exc:
                    _stdout(f"ERR {exc}")
                continue

            now = time.monotonic()
            if (
                last_report is not None
                and not last_off
                and (now - last_push) >= keepalive_s
            ):
                try:
                    send_feature_reports(dev, [last_report], delay_s=0.0, verbose=False)
                    last_push = now
                except (OSError, RuntimeError, ValueError) as exc:
                    _stdout(f"ERR keepalive {exc}")
                    break
            stop.wait(0.05)
    finally:
        _close_quiet(dev)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Hi75 minimal HID control")
    ap.add_argument("--list", action="store_true", help="列出 HID 设备")
    ap.add_argument("--off", action="store_true", help="熄灯")
    ap.add_argument(
        "--preset",
        type=str,
        choices=["red", "green", "white", "blue", "off"],
        help="预设颜色",
    )
    ap.add_argument("--color", type=str, help="静态颜色 hex, 如 ff0000")
    ap.add_argument(
        "--direct",
        type=str,
        help="Direct 模式 hex, 如 ff0000（不闪，需保活）",
    )
    ap.add_argument(
        "--hold",
        type=float,
        default=0.0,
        help="配合 --direct，保活秒数",
    )
    ap.add_argument(
        "--serve",
        action="store_true",
        help="stdin 行协议常驻（ambient 调 exe 用，内部 keepalive）",
    )
    ap.add_argument("--r", type=int, help="R 0-255")
    ap.add_argument("--g", type=int, help="G 0-255")
    ap.add_argument("--b", type=int, help="B 0-255")
    ap.add_argument(
        "--path",
        type=str,
        default="auto",
        help="HID 路径，默认 auto=优先 Col06",
    )
    ap.add_argument(
        "--leds",
        type=int,
        default=DEFAULT_LED_COUNT,
        help="Direct LED 数量，默认 120",
    )
    ap.add_argument(
        "--keepalive",
        type=float,
        default=0.70,
        help="Direct 保活间隔秒，默认 0.70",
    )
    args = ap.parse_args()
    try:
        if args.list:
            test_enumerate()
            return 0
        if args.serve:
            return serve(args.path, led_count=args.leds, keepalive_s=args.keepalive)
        if args.off:
            set_off(args.path)
            return 0
        if args.direct:
            r, g, b = parse_hex_color(args.direct)
            set_direct_color(
                r, g, b, args.path, hold_s=args.hold, led_count=args.leds
            )
            return 0
        if args.preset:
            set_preset(args.preset, args.path)
            return 0
        if args.color:
            r, g, b = parse_hex_color(args.color)
            set_static_color(r, g, b, args.path)
            return 0
        if args.r is not None:
            set_static_color(args.r, args.g or 0, args.b or 0, args.path)
            return 0
    except (FileNotFoundError, ValueError, RuntimeError, OSError) as exc:
        print(f"[ERROR] {exc}")
        return 1
    prog = Path(sys.executable).name if _frozen() else "python tools/rgb/hi75.py"
    ap.print_help()
    print("\n示例:")
    print(f"  {prog} --list")
    print(f"  {prog} --preset red")
    print(f"  {prog} --color ff0000  # 静态 0x0a，换色会闪")
    print(f"  {prog} --direct ff0000 --hold 5  # Direct 0x08")
    print(f"  {prog} --serve  # 给 ambient 当独立键盘进程")
    print(f"  {prog} --off")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
