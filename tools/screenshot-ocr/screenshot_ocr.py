import os
import sys
import time
import tkinter as tk

from PIL import ImageGrab

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(SCRIPT_DIR, "last_ocr.log")
LAST_CAPTURE_PATH = os.path.join(SCRIPT_DIR, "last_capture.png")
LAST_PROCESSED_PATH = os.path.join(SCRIPT_DIR, "last_processed.png")


def log(message):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_PATH, "a", encoding="utf-8", errors="ignore") as log_file:
        log_file.write(f"[{timestamp}] {message}\n")


def safe_log(message: str) -> None:
    try:
        log(message)
    except OSError:
        return


def copy_to_clipboard(text):
    root = tk.Tk()
    root.withdraw()
    root.clipboard_clear()
    root.clipboard_append(text)
    root.update()
    root.destroy()


def notify(title, message):
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


class RegionSelector:
    def __init__(self):
        self.root = tk.Tk()
        self.root.attributes("-fullscreen", True)
        self.root.attributes("-topmost", True)
        self.root.attributes("-alpha", 0.28)
        self.root.configure(cursor="crosshair", bg="black")

        self.canvas = tk.Canvas(self.root, bg="black", highlightthickness=0)
        self.canvas.pack(fill=tk.BOTH, expand=True)

        self.start_x = None
        self.start_y = None
        self.rect_id = None
        self.bbox = None

        self.canvas.create_text(
            self.root.winfo_screenwidth() // 2,
            60,
            text="拖拽选择 OCR 区域，按 Esc 取消",
            fill="white",
            font=("Microsoft YaHei UI", 18),
        )

        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        self.root.bind("<Escape>", self.cancel)

    def on_press(self, event):
        self.start_x = self.root.winfo_pointerx()
        self.start_y = self.root.winfo_pointery()
        if self.rect_id:
            self.canvas.delete(self.rect_id)
        self.rect_id = self.canvas.create_rectangle(
            event.x,
            event.y,
            event.x,
            event.y,
            outline="white",
            width=3,
        )

    def on_drag(self, event: tk.Event) -> None:
        if not self.rect_id or self.start_x is None or self.start_y is None:
            return
        self.canvas.coords(
            self.rect_id,
            self.start_x,
            self.start_y,
            self.root.winfo_pointerx(),
            self.root.winfo_pointery(),
        )

    def on_release(self, _event: tk.Event) -> None:
        if self.start_x is None or self.start_y is None:
            self.bbox = None
            self.root.quit()
            return
        end_x = self.root.winfo_pointerx()
        end_y = self.root.winfo_pointery()
        left, right = sorted([self.start_x, end_x])
        top, bottom = sorted([self.start_y, end_y])

        if right - left < 8 or bottom - top < 8:
            self.bbox = None
        else:
            self.bbox = (left, top, right, bottom)

        self.root.quit()

    def cancel(self, _event=None):
        self.bbox = None
        self.root.quit()

    def select(self):
        self.root.mainloop()
        self.root.update_idletasks()
        self.root.destroy()
        return self.bbox


def load_engine():
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


def run_ocr() -> int:
    try:
        if os.path.exists(LOG_PATH):
            os.remove(LOG_PATH)
    except OSError as error:
        safe_log(f"cleanup_error={error}")

    engine = load_engine()
    if not engine:
        return 1

    selector = RegionSelector()
    bbox = selector.select()
    log(f"bbox={bbox}")
    if not bbox:
        return 0

    time.sleep(0.35)
    image = ImageGrab.grab(bbox=bbox)
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


def main() -> int:
    try:
        return run_ocr()
    except (OSError, RuntimeError, ValueError, ImportError, tk.TclError) as error:
        # 顶层兜底：文件、运行时、图像与 tkinter 的预期异常都要通知用户而不是静默退出
        error_message = str(error).strip() or error.__class__.__name__
        safe_log(f"fatal_error={error.__class__.__name__}: {error_message}")
        if len(error_message) > 120:
            error_message = error_message[:120] + "..."
        notify("OCR 失败", error_message)
        return 1


if __name__ == "__main__":
    sys.exit(main())
