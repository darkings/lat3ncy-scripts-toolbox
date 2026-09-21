"""剪贴板图片 OCR：配合系统截图工具（Win+Shift+S / ms-screenclip:）使用。

轮询系统剪贴板中的图片（由截图工具写入），用 RapidOCR 识别中英文，
把识别文本写回剪贴板。手动运行与 Raycast 路径都走系统 Toast：
Raycast 由 screenshot-ocr.ps1 统一弹泡，本脚本保持静默；
手动运行时由本脚本直接调用 shared/notify/toast.ps1。超时 45 秒。
手动运行时先注入截图框再加载模型，避免 ONNX 冷启动挡住框选。
Raycast 路径由 screenshot-ocr.ps1 先打开截图框，再带 --no-screenshot --result-file
调用本脚本；此时保持静默，由外层 ps1 统一通知。
"""

import os
import pathlib
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


def _resolve_toast_script() -> pathlib.Path | None:
    """从脚本目录向上找仓库根，定位系统 Toast 脚本。"""
    current = pathlib.Path(SCRIPT_DIR).resolve()
    for _ in range(6):
        candidate = current / "shared" / "notify" / "toast.ps1"
        if candidate.is_file():
            return candidate
        if current.parent == current:
            break
        current = current.parent
    return None


def notify(title: str, message: str) -> None:
    if _SILENT_MODE:
        return
    toast = _resolve_toast_script()
    if toast is None:
        return
    try:
        # CREATE_NO_WINDOW：避免弹黑窗口；失败静默，不影响 OCR 主流程。
        subprocess.Popen(
            [
                "powershell.exe",
                "-ExecutionPolicy",
                "Bypass",
                "-NoProfile",
                "-File",
                str(toast),
                title,
                message,
            ],
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
        )
    except Exception:
        return


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
        # Raycast 流程：结果交调用方以系统 Toast 展示，这里只写文件并复制剪贴板
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
    # 先出截图框，再加载 RapidOCR。模型冷启动通常 1～5 秒，不能挡在框选前面。
    if inject_screenshot:
        send_win_shift_s()

    engine = load_engine()
    if not engine:
        return 1

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

    # Raycast 托管时静默，统一由 screenshot-ocr.ps1 的 Show-SystemToast 负责
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
