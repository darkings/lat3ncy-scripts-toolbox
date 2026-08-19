"""剪贴板图片 OCR：配合系统截图工具（Win+Shift+S）使用。

轮询系统剪贴板中的图片（由截图工具写入），用 RapidOCR 识别中英文，
把识别文本写回剪贴板并通过 Windows 通知显示摘要。超时 45 秒。
"""

import os
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


def notify(title: str, message: str) -> None:
    notify_tkinter(title, message)


def notify_tkinter(title: str, message: str) -> None:
    try:
        root = tk.Tk()
        root.overrideredirect(True)
        root.attributes("-topmost", True)
        # 透明色背景 + Canvas 绘制卡片，实现圆角、图标与动画
        root.attributes("-transparentcolor", "#ff00ff")

        width = 420
        height = 88
        x = root.winfo_screenwidth() - width - 32
        y = 72
        root.geometry(f"{width}x{height}+{x}+{y}")
        root.configure(bg="#ff00ff")

        canvas = tk.Canvas(root, bg="#ff00ff", highlightthickness=0)
        canvas.pack(fill=tk.BOTH, expand=True)
        rounded_rect(
            canvas, 0, 0, width - 1, height - 1, 14, fill="#1f1f23", outline="#3a3a40"
        )
        # 顶部进度条（随剩余时间缩短）
        bar = canvas.create_rectangle(16, 6, width - 16, 10, fill="#3b82f6", outline="")
        # 标题与消息（无图标，左对齐）
        canvas.create_text(
            16,
            20,
            text=title,
            anchor="nw",
            fill="#ffffff",
            font=("Microsoft YaHei UI", 13, "bold"),
        )
        canvas.create_text(
            16,
            48,
            text=message,
            anchor="nw",
            fill="#c9c9cf",
            font=("Microsoft YaHei UI", 10),
            width=width - 32,
        )

        def animate() -> None:
            root.attributes("-alpha", 0.0)
            for step in range(1, 11):
                root.attributes("-alpha", step / 10)
                root.update()
                time.sleep(0.02)
            for step in range(40, 0, -1):
                bar_right = 16 + int((width - 32) * step / 40)
                canvas.coords(bar, 16, 6, bar_right, 10)
                root.update()
                time.sleep(0.05)
            for step in range(10, 0, -1):
                root.attributes("-alpha", step / 10)
                root.update()
                time.sleep(0.025)
            root.destroy()

        root.after(50, animate)
        root.mainloop()
    except tk.TclError:
        return


def rounded_rect(
    canvas: tk.Canvas,
    x1: int,
    y1: int,
    x2: int,
    y2: int,
    radius: int,
    **kwargs: Any,
) -> int:
    points = [
        x1 + radius,
        y1,
        x2 - radius,
        y1,
        x2,
        y1,
        x2,
        y1 + radius,
        x2,
        y2 - radius,
        x2,
        y2,
        x2 - radius,
        y2,
        x1 + radius,
        y2,
        x1,
        y2,
        x1,
        y2 - radius,
        x1,
        y1 + radius,
        x1,
        y1,
    ]
    return canvas.create_polygon(points, smooth=True, **kwargs)


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
        # Raycast 流程：结果交调用方以系统气泡展示，这里只写文件并复制剪贴板
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
    inject_screenshot = "--no-screenshot" not in sys.argv
    result_file = None
    args = sys.argv[1:]
    if "--result-file" in args:
        position = args.index("--result-file")
        if position + 1 < len(args):
            result_file = args[position + 1]

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
