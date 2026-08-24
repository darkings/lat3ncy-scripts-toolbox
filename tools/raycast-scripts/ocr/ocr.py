"""剪贴板图片 OCR：配合系统截图工具（Win+Shift+S）使用。

轮询系统剪贴板中的图片（由截图工具写入），用 RapidOCR 识别中英文，
把识别文本写回剪贴板并通过统一 HUD（shared/notify）显示摘要。超时 45 秒。
当由 Raycast（--result-file）调用时保持静默，由外层 ps1 统一通知。
"""

import os
import pathlib
import shutil
import subprocess
import sys
import time
import tkinter as tk
from typing import Any

import tomllib
from PIL import Image, ImageGrab

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CLIPBOARD_TIMEOUT_SECONDS = 45

# config.toml 中预设的键名 -> RapidOCR 构造函数参数名
MODEL_PARAM_NAMES = {
    "det": "det_model_path",
    "cls": "cls_model_path",
    "rec": "rec_model_path",
}

# Raycast 托管时由外层 ps1 统一通知，py 侧静默以避免双泡
_SILENT_MODE = False


def copy_to_clipboard(text: str) -> None:
    try:
        import pyperclip

        pyperclip.copy(text)
    except Exception:
        # tkinter 剪贴板在进程退出后可能被清空，仅在 pyperclip 不可用时回退
        copy_to_clipboard_tkinter(text)


def copy_to_clipboard_tkinter(text: str) -> None:
    root = tk.Tk()
    root.withdraw()
    root.clipboard_clear()
    root.clipboard_append(text)
    root.update()
    root.destroy()


def _resolve_notify_dir() -> pathlib.Path | None:
    current = pathlib.Path(SCRIPT_DIR).resolve()
    for _ in range(6):
        candidate = current / "shared" / "notify"
        if (candidate / "notify-cli.ahk").is_file() or (candidate / "notify.exe").is_file():
            return candidate
        if current.parent == current:
            break
        current = current.parent
    return None


def _resolve_autohotkey() -> str | None:
    local_app_data = os.environ.get("LOCALAPPDATA") or os.environ.get("LocalAppData")
    if not local_app_data:
        # Raycast 隔离环境下 env 可能为空，回退到 HOME\AppData\Local
        try:
            local_app_data = str(pathlib.Path.home() / "AppData" / "Local")
        except Exception:
            local_app_data = ""
    if local_app_data:
        for name in ("AutoHotkey64.exe", "AutoHotkey32.exe"):
            candidate = pathlib.Path(local_app_data) / "Programs" / "AutoHotkey" / "v2" / name
            if candidate.is_file():
                return str(candidate)
    found = shutil.which("AutoHotkey.exe")
    if found:
        # 处理 Scoop shim（.shim 文件）
        try:
            shim = pathlib.Path(found).with_suffix(".shim")
            if shim.is_file():
                text = shim.read_text(encoding="utf-8", errors="ignore")
                import re

                m = re.search(r'path\s*=\s*"([^"]+)"', text)
                if m:
                    target = pathlib.Path(m.group(1))
                    if target.name.lower() == "autohotkeyux.exe":
                        install_root = target.parent.parent
                        engine = install_root / "v2" / ("AutoHotkey64.exe" if os.environ.get("PROCESSOR_ARCHITECTURE", "").endswith("64") else "AutoHotkey32.exe")
                        if engine.is_file():
                            return str(engine)
                    if target.is_file():
                        return str(target)
        except Exception:
            pass
        return found
    program_files = os.environ.get("ProgramFiles") or r"C:\Program Files"
    for candidate in (
        pathlib.Path(program_files) / "AutoHotkey" / "v2" / "AutoHotkey64.exe",
        pathlib.Path(program_files) / "AutoHotkey" / "v2" / "AutoHotkey32.exe",
        pathlib.Path(program_files) / "AutoHotkey" / "v2" / "AutoHotkey.exe",
    ):
        if candidate.is_file():
            return str(candidate)
    # Scoop 常见路径兜底
    for root in (os.environ.get("USERPROFILE"), os.environ.get("SCOOP")):
        if not root:
            continue
        for candidate in (
            pathlib.Path(root) / "scoop" / "apps" / "autohotkey" / "current" / "AutoHotkey64.exe",
            pathlib.Path(root) / "scoop" / "apps" / "autohotkey" / "current" / "AutoHotkey32.exe",
        ):
            if candidate.is_file():
                return str(candidate)
    return None


def notify_shared(ntype: str, icon: str, text: str, duration: int = 0) -> None:
    notify_dir = _resolve_notify_dir()
    if notify_dir is None:
        return
    args: list[str] = [ntype, icon, text]
    if duration > 0:
        args.append(str(duration))
    try:
        notify_exe = notify_dir / "notify.exe"
        if notify_exe.is_file():
            subprocess.Popen(
                [str(notify_exe), *args],
                cwd=str(notify_dir),
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
            )
            return
        notify_ahk = notify_dir / "notify-cli.ahk"
        if not notify_ahk.is_file():
            return
        ahk = _resolve_autohotkey()
        if not ahk:
            return
        subprocess.Popen(
            [ahk, str(notify_ahk), *args],
            cwd=str(notify_dir),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
        )
    except Exception:
        return


def notify(title: str, message: str) -> None:
    if _SILENT_MODE:
        return
    # 映射到统一 HUD 的 4 种语义类型
    if title == "OCR 已复制":
        notify_shared("success", "✓", message, 900)
    elif title == "OCR 未识别到文字":
        notify_shared("error", "!", "未识别到文字", 1400)
    elif title == "OCR 已取消":
        notify_shared("info", "−", "OCR 已取消", 750)
    elif title == "OCR 未配置":
        text = message if message else title
        notify_shared("error", "×", text[:120], 1400)
    elif title == "OCR 失败":
        text = message if message else title
        notify_shared("error", "×", text[:120] if text != title else "OCR 失败", 1400)
    else:
        text = f"{title} {message}".strip()[:120] if message else title
        notify_shared("error", "×", text, 1400)


def load_model_paths() -> dict[str, str]:
    """从 config.toml 读取模型配置，返回 RapidOCR 可用的模型路径参数。"""
    config_path = os.path.join(SCRIPT_DIR, "config.toml")
    try:
        with open(config_path, "rb") as config_file:
            config = tomllib.load(config_file)
        preset = config.get("models", {}).get(config.get("model", "default"), {})
    except (OSError, ValueError):
        return {}

    paths: dict[str, str] = {}
    for key, param_name in MODEL_PARAM_NAMES.items():
        value = preset.get(key)
        if not isinstance(value, str) or not value:
            continue
        candidate = os.path.join(SCRIPT_DIR, value)
        if os.path.isfile(candidate):
            paths[param_name] = candidate
    return paths


def load_engine() -> Any | None:
    try:
        from rapidocr_onnxruntime import RapidOCR
    except (ImportError, OSError):
        notify("OCR 未配置", "RapidOCR 不可用，请先运行 install-deps.py 安装依赖")
        return None

    try:
        return RapidOCR(**load_model_paths())
    except (OSError, RuntimeError) as error:
        notify("OCR 未配置", f"RapidOCR 初始化失败：{str(error)[:120]}")
        return None


def send_win_shift_s() -> None:
    """通过 ctypes 注入 Win+Shift+S 打开系统截图框选。"""
    import ctypes

    user32 = ctypes.windll.user32
    vk_lwin = 0x5B
    vk_shift = 0x10
    vk_s = 0x53
    keyeventf_keyup = 0x0002
    user32.keybd_event(vk_lwin, 0, 0, 0)
    user32.keybd_event(vk_shift, 0, 0, 0)
    user32.keybd_event(vk_s, 0, 0, 0)
    time.sleep(0.06)
    user32.keybd_event(vk_s, 0, keyeventf_keyup, 0)
    user32.keybd_event(vk_shift, 0, keyeventf_keyup, 0)
    user32.keybd_event(vk_lwin, 0, keyeventf_keyup, 0)


def write_result(result_file: str, text: str) -> None:
    with open(result_file, "w", encoding="utf-8") as result:
        result.write(text)


def recognize(engine: Any, image: Image.Image, result_file: str | None = None) -> int:
    import numpy as np

    try:
        result, _ = engine(np.array(image))
    except (RuntimeError, OSError) as error:
        notify("OCR 失败", str(error)[:120])
        return 1

    text = ""
    if result:
        text = "\n".join(line[1] for line in result).strip()

    if result_file is not None:
        # Raycast 流程：结果交调用方以统一 HUD 展示，这里只写文件并复制剪贴板
        write_result(result_file, text)
        if text:
            copy_to_clipboard(text)
        return 0

    if text:
        copy_to_clipboard(text)
        preview = text.replace("\r", " ").replace("\n", " ")
        if len(preview) > 60:
            preview = preview[:60] + "..."
        notify("OCR 已复制", f"{len(text)} 个字符：{preview}")
    else:
        notify("OCR 未识别到文字", "请重新框选更清晰的区域")

    return 0


def run_ocr_from_clipboard(
    timeout_seconds: int = CLIPBOARD_TIMEOUT_SECONDS,
    inject_screenshot: bool = True,
    result_file: str | None = None,
) -> int:
    engine = load_engine()
    if not engine:
        return 1

    if inject_screenshot:
        send_win_shift_s()

    deadline = time.monotonic() + timeout_seconds
    image: Image.Image | None = None
    while time.monotonic() < deadline:
        clipboard = ImageGrab.grabclipboard()
        if isinstance(clipboard, Image.Image):
            image = clipboard
            break
        time.sleep(0.3)

    if image is None:
        notify("OCR 已取消", "未检测到截图，请在截屏工具中框选区域后重试")
        return 0

    return recognize(engine, image, result_file)


def main() -> int:
    global _SILENT_MODE
    inject_screenshot = "--no-screenshot" not in sys.argv
    result_file = None
    args = sys.argv[1:]
    if "--result-file" in args:
        position = args.index("--result-file")
        if position + 1 < len(args):
            result_file = args[position + 1]

    # Raycast 托管时静默，统一由 screenshot-ocr.ps1 的 Show-ToolboxNotify 负责
    _SILENT_MODE = result_file is not None

    try:
        return run_ocr_from_clipboard(
            inject_screenshot=inject_screenshot,
            result_file=result_file,
        )
    except (OSError, RuntimeError, ValueError, ImportError, tk.TclError) as error:
        error_message = str(error).strip() or error.__class__.__name__
        if len(error_message) > 120:
            error_message = error_message[:120] + "..."
        notify("OCR 失败", error_message)
        return 1


if __name__ == "__main__":
    sys.exit(main())
