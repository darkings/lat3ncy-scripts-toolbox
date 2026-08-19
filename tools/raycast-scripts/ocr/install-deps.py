#!/usr/bin/env python3
# @raycast.schemaVersion 1
# @raycast.title Install OCR Dependencies
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Install OCR dependencies (Pillow + RapidOCR), skip if already installed
# @raycast.icon 📦

"""Screenshot OCR 依赖安装脚本（跨平台）。

按当前操作系统选择可用的 Python 解释器，通过 pip 安装 OCR 所需的
Python 依赖（Pillow + RapidOCR）。依赖已存在时自动跳过。

用法：
    python install-deps.py            # 检测并安装缺失依赖，交互式选择是否下载移动端模型
    python install-deps.py --check    # 只检测，不安装

RapidOCR 为纯 pip 分发，无需系统包管理器；各平台差异主要体现在
Python 解释器的查找方式上。移动端模型从 ModelScope 官方仓库下载。
"""

import hashlib
import importlib.util
import os
import platform
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

PIP_PACKAGES: list[str] = [
    "pillow",
    "rapidocr-onnxruntime",
    "pyperclip",
]

# pip 包名 -> 模块导入名
IMPORT_NAMES: dict[str, str] = {
    "pillow": "PIL",
    "rapidocr-onnxruntime": "rapidocr_onnxruntime",
}

# 移动端模型：文件名 -> (ModelScope 仓库内路径, sha256)
MOBILE_MODELS: dict[str, tuple[str, str]] = {
    "ch_PP-OCRv4_det_mobile.onnx": (
        "onnx/PP-OCRv4/det/ch_PP-OCRv4_det_mobile.onnx",
        "d2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9",
    ),
    "ch_ppocr_mobile_v2.0_cls_mobile.onnx": (
        "onnx/PP-OCRv4/cls/ch_ppocr_mobile_v2.0_cls_mobile.onnx",
        "e47acedf663230f8863ff1ab0e64dd2d82b838fceb5957146dab185a89d6215c",
    ),
    "ch_PP-OCRv4_rec_mobile.onnx": (
        "onnx/PP-OCRv4/rec/ch_PP-OCRv4_rec_mobile.onnx",
        "48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b",
    ),
}

MODELS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
MODELSCOPE_BASE = "https://modelscope.cn/models/RapidAI/RapidOCR/resolve/master"


def detect_platform() -> str:
    system = platform.system()
    release = platform.release()
    detail = system
    if system == "Linux" and sys.platform.startswith("linux"):
        detail = f"{system} ({linux_distro_id()})"
    return f"{detail} {release}"


def linux_distro_id() -> str:
    try:
        with open("/etc/os-release", encoding="utf-8") as os_release:
            for line in os_release:
                if line.startswith("ID="):
                    return line.strip()[3:].strip('"')
    except OSError:
        return "unknown"
    return "unknown"


def find_python() -> list[str] | None:
    """返回安装依赖用的 Python 命令前缀。

    Windows 上优先 `python`（与 Raycast OCR 脚本使用的 pythonw.exe 同一环境），
    macOS/Linux 上优先 `python3`。
    """
    if sys.platform == "win32":
        candidates = ["python", "py -3"]
    else:
        candidates = ["python3", "python"]
    for candidate in candidates:
        executable = candidate.split()[0]
        if shutil.which(executable):
            return candidate.split()
    return None


def module_installed(package: str) -> bool:
    import_name = IMPORT_NAMES.get(package, package)
    return import_name is not None and importlib.util.find_spec(import_name) is not None


def run(
    command: list[str], check_message: str | None = None
) -> subprocess.CompletedProcess[bytes]:
    if check_message:
        print(f">> {check_message}")
    print("$", " ".join(command))
    result = subprocess.run(command, check=False)
    if result.returncode != 0:
        raise SystemExit(f"命令失败（exit {result.returncode}）：{' '.join(command)}")
    return result


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_model(filename: str, remote_path: str, expected_sha256: str) -> None:
    """下载单个模型文件，校验 sha256 后落到 ocr/models/。"""
    target = os.path.join(MODELS_DIR, filename)
    if os.path.isfile(target) and sha256_of(target) == expected_sha256:
        print(f"  OK {filename}（已存在）")
        return

    url = f"{MODELSCOPE_BASE}/{remote_path}"
    temporary = target + ".part"
    print(f"  下载 {filename} ...")
    try:
        urllib.request.urlretrieve(url, temporary)
        if sha256_of(temporary) != expected_sha256:
            raise RuntimeError(f"{filename} 下载校验失败（sha256 不匹配）")
        os.replace(temporary, target)
        print(f"  OK {filename}")
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def ensure_mobile_models() -> None:
    """确保 PP-OCRv4 移动端三个模型文件就位，缺失则从 ModelScope 下载。"""
    os.makedirs(MODELS_DIR, exist_ok=True)
    for filename, (remote_path, expected_sha256) in MOBILE_MODELS.items():
        download_model(filename, remote_path, expected_sha256)


def prompt_yes_no(question: str) -> bool:
    """交互式提问，返回是否确认；无输入（管道/非交互）时默认否。"""
    try:
        answer = input(f"{question} [y/N] ").strip().lower()
    except EOFError:
        return False
    return answer in ("y", "yes")


def switch_model_to_mobile() -> None:
    """把 config.toml 顶层 model 字段切换为 mobile。"""
    config_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "config.toml"
    )
    lines = open(config_path, encoding="utf-8").readlines()
    for index, line in enumerate(lines):
        if line.strip().startswith("model ="):
            lines[index] = 'model = "mobile"\n'
            break
    open(config_path, "w", encoding="utf-8").writelines(lines)
    print('已切换：model = "mobile"（修改 ocr/config.toml 可随时切回 default）')


def verify_engine(python: list[str]) -> None:
    print("\n验证 RapidOCR 引擎可加载（首次会加载模型，请稍候）：")
    run(
        python
        + [
            "-c",
            (
                "from rapidocr_onnxruntime import RapidOCR; "
                "engine = RapidOCR(); print('  OK rapidocr engine ready')"
            ),
        ],
        check_message="实例化 RapidOCR",
    )


def main() -> int:
    print(f"检测到操作系统：{detect_platform()}")
    print(f"Python：{sys.version.split()[0]}")

    python = find_python()
    if not python:
        raise SystemExit(
            "未找到 Python 3。请先安装 Python 3 并加入 PATH："
            "https://www.python.org/downloads/"
        )
    print(f"使用解释器：{' '.join(python)}")

    missing = [pkg for pkg in PIP_PACKAGES if not module_installed(pkg)]
    if not missing:
        print("依赖已全部就绪：" + ", ".join(PIP_PACKAGES))
        if "--check" in sys.argv:
            return 0
        verify_engine(python)
    else:
        print("缺少依赖：" + ", ".join(missing))
        if "--check" in sys.argv:
            print("--check 模式：跳过安装。")
            return 1

        run(python + ["-m", "pip", "install"] + missing, check_message="安装缺失依赖")

        print("\n验证安装结果：")
        for package in missing:
            if not module_installed(package):
                raise SystemExit(f"验证失败：{package} 安装后仍无法导入")
            print(f"  OK {package}")

        verify_engine(python)

    if prompt_yes_no("是否下载 PP-OCRv4 移动端模型（识别更快、精度略降）？"):
        print("\n下载 PP-OCRv4 移动端模型（mobile）：")
        try:
            ensure_mobile_models()
        except (OSError, urllib.error.URLError) as error:
            raise SystemExit(f"移动端模型下载失败：{error}")
        if prompt_yes_no("是否将 config.toml 的模型切换为 mobile？"):
            switch_model_to_mobile()

    print("\n依赖安装完成，可以运行 Screenshot OCR 了。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
