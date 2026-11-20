"""剪贴板图片 OCR：配合系统截图工具（Win+Shift+S / ms-screenclip:）使用。

轮询系统剪贴板中的图片（由截图工具写入），用 RapidOCR 识别中英文，
把识别文本写回剪贴板。手动运行与 Raycast 路径都走系统 Toast：
Raycast 由 screenshot-ocr.ps1 以 detached 方式启动本脚本并传
--no-screenshot --result-file --notify-on-done；完成后由本脚本直接弹
Toast（Raycast host 的 30s IPC 超时等不了引擎冷启动，ps1 侧不等待）。
失败协议：--result-file 模式下识别失败时把错误写成首行 "ERROR: <原因>" 并 exit 1。
"""

import base64
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import tkinter as tk
from typing import Any

import tomllib
from PIL import Image, ImageGrab

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CLIPBOARD_TIMEOUT_SECONDS = 45
DEBUG_LOG = os.path.join(SCRIPT_DIR, ".debug.log")


def _debug(message: str) -> None:
    """现场日志：写在仓库内（MSIX 不虚拟化 Projects 目录），排障用。"""
    try:
        with open(DEBUG_LOG, "a", encoding="utf-8") as log_file:
            log_file.write(f"{time.strftime('%H:%M:%S')} py {message}\n")
    except OSError:
        pass


def _session_id() -> int:
    """当前进程所在 Windows 会话；不是 1 就说明拿不到用户桌面/剪贴板。"""
    try:
        import ctypes

        session = ctypes.c_ulong()
        if ctypes.windll.kernel32.ProcessIdToSessionId(os.getpid(), ctypes.byref(session)):
            return int(session.value)
    except Exception:
        pass
    return -1

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


def notify(title: str, message: str, wait: bool = True) -> None:
    if _SILENT_MODE:
        return
    toast = _resolve_toast_script()
    if toast is None:
        _debug("notify skipped: toast.ps1 not found")
        return
    runner_path: str | None = None
    try:
        # 命令行参数经 powershell.exe 5.1 会按 ANSI(GBK) 解码，中文必乱码
        # （仓库 _lib/notify.ps1 同因改用 UTF-8 runner）。这里把 UTF-8 文本
        # base64 后写进纯 ASCII runner：不依赖 BOM、不受引号/here-string 影响。
        title_b64 = base64.b64encode(title.encode("utf-8")).decode("ascii")
        message_b64 = base64.b64encode(message.encode("utf-8")).decode("ascii")
        runner = (
            "param([string]$ToastScript)\n"
            "$utf8 = [Text.Encoding]::UTF8\n"
            f"$title = $utf8.GetString([Convert]::FromBase64String('{title_b64}'))\n"
            f"$message = $utf8.GetString([Convert]::FromBase64String('{message_b64}'))\n"
            "try { & $ToastScript -Title $title -Message $message } finally {\n"
            # fire-and-forget 时父进程不能删这个文件（子进程还没读完），交给它自己收尾。
            "Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue\n"
            "}\n"
        )
        # 候选目录：脚本目录优先。不要用 tempfile.gettempdir()——它在
        # TEMP 不可用时抛 FileNotFoundError("No usable temporary directory found")，
        # 直接把 Toast 打断（2026-11-06 实测）。
        token = f"{os.getpid()}-{os.urandom(8).hex()}"
        candidates = [os.path.join(SCRIPT_DIR, f".toast-{token}.ps1")]
        temp_dir = os.environ.get("TEMP") or os.environ.get("TMP")
        if temp_dir:
            candidates.append(os.path.join(temp_dir, f"lat3ncy-ocr-toast-{token}.ps1"))
        for candidate in candidates:
            try:
                with open(candidate, "w", encoding="ascii", newline="\n") as runner_file:
                    runner_file.write(runner)
                runner_path = candidate
                break
            except OSError:
                continue
        if runner_path is None:
            _debug("notify failed: no writable runner path")
            return
        # wait=False 时绝不能建 PIPE：没人读的管道写满缓冲后会把子进程永久阻塞。
        sink = subprocess.PIPE if wait else subprocess.DEVNULL
        process = subprocess.Popen(
            [
                "powershell.exe",
                "-ExecutionPolicy",
                "Bypass",
                "-NoProfile",
                "-File",
                runner_path,
                "-ToastScript",
                str(toast),
            ],
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
            stdout=sink,
            stderr=sink,
        )
        if not wait:
            # 即时反馈用：不等待。runner 由子进程自己删（见上面的 Remove-Item）。
            _debug(f"notify fired pid={process.pid} (no wait)")
            runner_path = None  # ownership transferred after successful Popen
            return
        try:
            out, err = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            _debug(f"notify timeout pid={process.pid} runner={runner_path}")
            return
        _debug(
            f"notify pid={process.pid} rc={process.returncode} "
            f"stderr={err.decode('utf-8', 'replace').strip()[:150]!r}"
        )
    except Exception as error:
        _debug(f"notify threw: {error!r}")
        return
    finally:
        if runner_path:
            try:
                os.remove(runner_path)
            except OSError:
                pass


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


def load_engine() -> Any:
    # 失败时抛 RuntimeError 而不是 notify+None：Raycast 静默模式下 notify 会被吞掉，
    # 错误交给 main() 写进 result 文件，由外层 ps1 透传到 Toast。
    # 限制 ONNX 线程数：默认会用满全部核心，和前台程序抢 CPU，
    # 整机高负载时反而把自己饿到 20s+（2026-11-06 实测：load=91% 时引擎加载 20s，
    # 空闲时只 2.3s）。4 线程足够，且不干扰用户。
    thread_cap = "4"
    for env_name in ("OMP_NUM_THREADS", "ORT_NUM_THREADS"):
        if not os.environ.get(env_name):
            os.environ[env_name] = thread_cap

    try:
        from rapidocr_onnxruntime import RapidOCR
    except (ImportError, OSError) as error:
        raise RuntimeError(
            f"RapidOCR 不可用（{error.__class__.__name__}），请先运行 install-deps.py；"
            "若 pip 报 onnxruntime 无匹配版本，说明当前 Python 版本还没有对应 wheel"
        ) from error

    try:
        return RapidOCR(**load_model_paths())
    except (OSError, RuntimeError) as error:
        raise RuntimeError(f"RapidOCR 初始化失败：{str(error)[:120]}") from error


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


def recognize(
    engine: Any,
    image: Image.Image,
    result_file: str | None = None,
    notify_on_done: bool = False,
) -> int:
    import numpy as np

    # 大图先降采样：RapidOCR 的耗时随像素数近似线性增长。
    # 2026-11-06 实测 1877x737 要 21s（用户体感就是「框选完没反应」），
    # 而 PP-OCRv4 检测器本身会把长边缩到 960 左右，超过这个尺寸再算就是白烧时间。
    original_size = image.size
    max_side = 1600
    longest = max(original_size)
    if longest > max_side:
        scale = max_side / longest
        image = image.resize(
            (max(1, int(image.width * scale)), max(1, int(image.height * scale))),
            Image.LANCZOS,
        )
        _debug(f"downscale {original_size} -> {image.size}")
    else:
        _debug(f"no downscale, size={original_size}")

    try:
        result, _ = engine(np.array(image))
    except (RuntimeError, OSError) as error:
        raise RuntimeError(f"识别失败：{str(error)[:120]}") from error

    text = ""
    if result:
        text = "\n".join(line[1] for line in result).strip()

    if result_file is not None:
        # Raycast detached 流程：先交付用户可见的结果（剪贴板 + Toast），
        # result 文件只是诊断副产物，写不进去绝不能再吞掉交付动作。
        # 2026-11-06 事故：WMI 创建的进程写 %TEMP% 抛 PermissionError，
        # 因为 write_result 排在复制/通知之前，识别成功却「长时间没反应」。
        if notify_on_done:
            preview = text.replace("\r", " ").replace("\n", " ")
            if len(preview) > 90:
                preview = preview[:90] + "..."
            if preview:
                notify("✓ OCR 文本已复制", preview)
            else:
                notify("! 未识别到文字", "所选区域内未检测到有效字符")
        if text:
            copy_to_clipboard(text)
        try:
            write_result(result_file, text)
        except OSError as error:
            _debug(f"write_result failed (ignored): {error}")
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


def _clipboard_sequence() -> int:
    """Windows 剪贴板序列号：内容变化时递增；取不到返回 0（退回旧行为）。"""
    try:
        import ctypes

        return int(ctypes.windll.user32.GetClipboardSequenceNumber())
    except Exception:
        return 0


def run_ocr_from_clipboard(
    timeout_seconds: int = CLIPBOARD_TIMEOUT_SECONDS,
    inject_screenshot: bool = True,
    result_file: str | None = None,
    notify_on_done: bool = False,
) -> int:
    _debug(f"start session={_session_id()} inject={inject_screenshot} notify={notify_on_done} result={result_file}")

    # 必须在出框/加载引擎之前读基线：剪贴板里可能还留着上一张截图，
    # 不比较序列号会立刻把旧图当成刚框选的内容识别（错误但看起来像成功）。
    baseline_sequence = _clipboard_sequence()
    _debug(f"baseline_seq={baseline_sequence}")

    # 先出截图框，再加载 RapidOCR。模型冷启动通常 1～5 秒，不能挡在框选前面。
    if inject_screenshot:
        send_win_shift_s()

    engine = load_engine()
    _debug("engine ready")
    deadline = time.monotonic() + timeout_seconds
    image: Image.Image | None = None
    while time.monotonic() < deadline:
        clipboard = ImageGrab.grabclipboard()
        if isinstance(clipboard, Image.Image):
            current_sequence = _clipboard_sequence()
            # 基线可用时必须等剪贴板确实更新过（用户完成框选），否则视为旧图
            if baseline_sequence == 0 or current_sequence != baseline_sequence:
                image = clipboard
                _debug(f"clipboard image {image.size} seq={baseline_sequence}->{current_sequence}")
                break
        time.sleep(0.3)

    if image is None:
        _debug("clipboard timeout")
        if notify_on_done:
            # 用户取消/未截图：detached 模式没人替我们说话，安静退出但留痕
            notify("OCR 已取消", "未检测到截图，请在截屏工具中框选区域后重试")
        return 0

    # 立即反馈：识别要 4-13 秒（冷启动更久），不提示的话用户以为没反应。
    # 用非阻塞方式弹（不 wait），避免拖慢识别。
    if notify_on_done:
        notify("OCR 识别中…", f"{image.width}×{image.height}，请稍候", wait=False)

    return recognize(engine, image, result_file, notify_on_done=notify_on_done)


def main() -> int:
    global _SILENT_MODE
    inject_screenshot = "--no-screenshot" not in sys.argv
    result_file = None
    notify_on_done = "--notify-on-done" in sys.argv
    args = sys.argv[1:]
    if "--result-file" in args:
        position = args.index("--result-file")
        if position + 1 < len(args):
            result_file = args[position + 1]

    # Raycast detached 流程：通知由本脚本的 --notify-on-done 负责，
    # 其余 stderr/stdout 保持静默（Raycast 会把任何 stdout 当 HUD 弹出）。
    _SILENT_MODE = result_file is not None and not notify_on_done

    try:
        exit_code = run_ocr_from_clipboard(
            inject_screenshot=inject_screenshot,
            result_file=result_file,
            notify_on_done=notify_on_done,
        )
        _debug(f"done exit={exit_code}")
        return exit_code
    except (OSError, RuntimeError, ValueError, ImportError, tk.TclError) as error:
        error_message = str(error).strip() or error.__class__.__name__
        # 压成单行：result 文件与 Toast 都是单行协议
        error_message = " ".join(error_message.split())
        if len(error_message) > 200:
            error_message = error_message[:200] + "..."
        _debug(f"error exit=1 {error_message}")
        if result_file is not None:
            try:
                write_result(result_file, f"ERROR: {error_message}")
            except OSError as write_error:
                _debug(f"error result write failed (ignored): {write_error}")
        if notify_on_done:
            notify("× OCR 失败", error_message[:160])
        elif result_file is None:
            notify("OCR 失败", error_message)
        return 1


if __name__ == "__main__":
    sys.exit(main())
