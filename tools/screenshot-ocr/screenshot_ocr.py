import os
import shutil
import subprocess
import sys
import tempfile
import time
import tkinter as tk

from PIL import ImageEnhance, ImageFilter, ImageGrab, ImageOps


COMMON_TESSERACT_PATHS = [
    r"C:\Program Files\Tesseract-OCR\tesseract.exe",
    r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe",
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_TESSDATA_DIR = os.path.join(SCRIPT_DIR, "tessdata")
LOG_PATH = os.path.join(SCRIPT_DIR, "last_ocr.log")
LAST_CAPTURE_PATH = os.path.join(SCRIPT_DIR, "last_capture.png")
LAST_PROCESSED_PATH = os.path.join(SCRIPT_DIR, "last_processed.png")
NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def log(message):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_PATH, "a", encoding="utf-8", errors="ignore") as log_file:
        log_file.write(f"[{timestamp}] {message}\n")


def find_tesseract():
    configured = os.environ.get("TESSERACT_CMD")
    if configured and os.path.exists(configured):
        return configured

    for path in COMMON_TESSERACT_PATHS:
        if os.path.exists(path):
            return path

    return shutil.which("tesseract")


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
    except Exception:
        pass


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

    def on_drag(self, event):
        if not self.rect_id:
            return
        self.canvas.coords(
            self.rect_id,
            self.start_x,
            self.start_y,
            self.root.winfo_pointerx(),
            self.root.winfo_pointery(),
        )

    def on_release(self, _event):
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


def preprocess(image):
    image = ImageOps.grayscale(image)
    image = ImageOps.autocontrast(image)
    image = image.resize((image.width * 2, image.height * 2))
    image = ImageEnhance.Contrast(image).enhance(1.5)
    return image.filter(ImageFilter.SHARPEN)


def run_tesseract(tesseract_cmd, image_path, output_base, lang, psm):
    cmd = [
        tesseract_cmd,
        image_path,
        output_base,
        "-l",
        lang,
        "--psm",
        str(psm),
    ]
    if os.path.isdir(LOCAL_TESSDATA_DIR):
        cmd.extend(["--tessdata-dir", LOCAL_TESSDATA_DIR])

    env = os.environ.copy()
    if os.path.isdir(LOCAL_TESSDATA_DIR):
        env["TESSDATA_PREFIX"] = LOCAL_TESSDATA_DIR

    log("Running: " + " ".join(f'"{part}"' if " " in part else part for part in cmd))
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=env,
        creationflags=NO_WINDOW,
    )


def main():
    try:
        if os.path.exists(LOG_PATH):
            os.remove(LOG_PATH)
    except Exception:
        pass

    tesseract_cmd = find_tesseract()
    log(f"tesseract={tesseract_cmd}")
    log(f"local_tessdata={LOCAL_TESSDATA_DIR} exists={os.path.isdir(LOCAL_TESSDATA_DIR)}")

    if not tesseract_cmd:
        notify("OCR 未配置", "没有找到 tesseract.exe")
        return 1

    selector = RegionSelector()
    bbox = selector.select()
    log(f"bbox={bbox}")
    if not bbox:
        return 0

    time.sleep(0.35)
    image = ImageGrab.grab(bbox=bbox)
    image.save(LAST_CAPTURE_PATH)
    image = preprocess(image)
    image.save(LAST_PROCESSED_PATH)

    lang = os.environ.get("OCR_LANG", "chi_sim+eng")
    psm_values = [
        os.environ.get("OCR_PSM", "6"),
        "7",
        "11",
        "3",
    ]

    with tempfile.TemporaryDirectory() as tmp:
        image_path = os.path.join(tmp, "ocr.png")
        image.save(image_path)

        text = ""
        last_error = ""
        for psm in psm_values:
            output_base = os.path.join(tmp, f"ocr_{psm}")
            proc = run_tesseract(tesseract_cmd, image_path, output_base, lang, psm)
            log(f"psm={psm} returncode={proc.returncode}")
            if proc.stdout:
                log(f"stdout={proc.stdout.strip()}")
            if proc.stderr:
                log(f"stderr={proc.stderr.strip()}")
            if proc.returncode != 0:
                last_error = proc.stderr.strip() or "Tesseract 执行失败"
                continue

            text_path = output_base + ".txt"
            with open(text_path, "r", encoding="utf-8", errors="ignore") as text_file:
                candidate = text_file.read().strip()
            log(f"psm={psm} text_len={len(candidate)} text={candidate[:120]}")
            if candidate:
                text = candidate
                break

        if not text and last_error:
            error_preview = last_error
            if len(error_preview) > 120:
                error_preview = error_preview[:120] + "..."
            notify("OCR 失败", error_preview)
            return 1

    if text:
        copy_to_clipboard(text)
        preview = text.replace("\r", " ").replace("\n", " ")
        if len(preview) > 60:
            preview = preview[:60] + "..."
        notify("OCR 已复制", f"{len(text)} 个字符：{preview}")
    else:
        notify("OCR 未识别到文字", "请重新框选更清晰的区域")

    return 0


if __name__ == "__main__":
    sys.exit(main())
