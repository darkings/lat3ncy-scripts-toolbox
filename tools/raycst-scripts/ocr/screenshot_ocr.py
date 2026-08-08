"""剪贴板图片 OCR：配合系统截图工具（Win+Shift+S）使用。

轮询系统剪贴板中的图片（由截图工具写入），用 RapidOCR 识别中英文，
把识别文本写回剪贴板并通过 Windows 通知显示摘要。超时 45 秒。
"""

import os
import sys
import time
import tkinter as tk
from typing import Any

from PIL import Image, ImageGrab

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(SCRIPT_DIR, "last_ocr.log")
LAST_CAPTURE_PATH = os.path.join(SCRIPT_DIR, "last_capture.png")
LAST_PROCESSED_PATH = os.path.join(SCRIPT_DIR, "last_processed.png")

CLIPBOARD_TIMEOUT_SECONDS = 45


def log(message: str) -> None:
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_PATH, "a", encoding="utf-8", errors="ignore") as log_file:
        log_file.write(f"[{timestamp}] {message}\n")


def safe_log(message: str) -> None:
    try:
        log(message)
    except OSError:
        return


def copy_to_clipboard(text: str) -> None:
    root = tk.Tk()
    root.withdraw()
    root.clipboard_clear()
    root.clipboard_append(text)
    root.update()
    root.destroy()


def notify(title: str, message: str) -> None:
    try:
        root = tk.Tk()
        root.overrideredirect(True)
        root.attributes("-topmost", True)
        root.configure(bg="#202124")

        width = 420
        height = 112
        x = root.winfo_screenwidth() - width - 32
        y = root.winfo_screenheight() - height - 72
        root.geometry(f"{width}x{height}+{x}+{y}")

        title_label = tk.Label(
            root,
            text=title,
            fg="#ffffff",
            bg="#202124",
            font=("Microsoft YaHei UI", 12, "bold"),
            anchor="w",
        )
        title_label.pack(fill="x", padx=16, pady=(14, 4))

        message_label = tk.Label(
            root,
            text=message,
            fg="#dfe1e5",
            bg="#202124",
            font=("Microsoft YaHei UI", 10),
            anchor="w",
            justify="left",
            wraplength=388,
        )
        message_label.pack(fill="x", padx=16)

        root.after(2600, root.destroy)
        root.mainloop()
    except tk.TclError:
        return


def load_engine() -> Any | None:
    try:
        from rapidocr_onnxruntime import RapidOCR
    except (ImportError, OSError) as error:
        safe_log(f"rapidocr_import_error={error}")
        notify("OCR 未配置", "RapidOCR 不可用，请先运行 install-deps.py 安装依赖")
        return None

    try:
        return RapidOCR()
    except (OSError, RuntimeError) as error:
        safe_log(f"rapidocr_init_error={error}")
        notify("OCR 未配置", f"RapidOCR 初始化失败：{str(error)[:120]}")
        return None


def clear_log() -> None:
    try:
        if os.path.exists(LOG_PATH):
            os.remove(LOG_PATH)
    except OSError as error:
        safe_log(f"cleanup_error={error}")


def recognize(engine: Any, image: Image.Image) -> int:
    image.save(LAST_CAPTURE_PATH)
    image.save(LAST_PROCESSED_PATH)

    import numpy as np

    try:
        result, elapse = engine(np.array(image))
    except (RuntimeError, OSError) as error:
        safe_log(f"ocr_error={error}")
        notify("OCR 失败", str(error)[:120])
        return 1
    log(f"elapse={elapse}")

    text = ""
    if result:
        text = "\n".join(line[1] for line in result).strip()
    log(f"text_len={len(text)} text={text[:120]}")

    if text:
        copy_to_clipboard(text)
        preview = text.replace("\r", " ").replace("\n", " ")
        if len(preview) > 60:
            preview = preview[:60] + "..."
        notify("OCR 已复制", f"{len(text)} 个字符：{preview}")
    else:
        notify("OCR 未识别到文字", "请重新框选更清晰的区域")

    return 0


def run_ocr_from_clipboard(timeout_seconds: int = CLIPBOARD_TIMEOUT_SECONDS) -> int:
    clear_log()

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

    return recognize(engine, image)


def main() -> int:
    try:
        return run_ocr_from_clipboard()
    except (OSError, RuntimeError, ValueError, ImportError, tk.TclError) as error:
        error_message = str(error).strip() or error.__class__.__name__
        safe_log(f"fatal_error={error.__class__.__name__}: {error_message}")
        if len(error_message) > 120:
            error_message = error_message[:120] + "..."
        notify("OCR 失败", error_message)
        return 1


if __name__ == "__main__":
    sys.exit(main())
