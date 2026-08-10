#!/usr/bin/env python3
# @raycast.schemaVersion 1
# @raycast.title Install OCR Dependencies
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description 安装 OCR 依赖（Pillow + RapidOCR），已装则跳过
# @raycast.icon 📦

"""Screenshot OCR 依赖安装脚本（跨平台）。

按当前操作系统选择可用的 Python 解释器，通过 pip 安装 OCR 所需的
Python 依赖（Pillow + RapidOCR）。依赖已存在时自动跳过。

用法：
    python install-deps.py            # 检测并安装缺失依赖
    python install-deps.py --check    # 只检测，不安装

RapidOCR 为纯 pip 分发，无需系统包管理器；各平台差异主要体现在
Python 解释器的查找方式上。
"""

import importlib.util
import platform
import shutil
import subprocess
import sys

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
        if "--check" not in sys.argv:
            verify_engine(python)
        return 0

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
    print("\n依赖安装完成，可以运行 Screenshot OCR 了。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
