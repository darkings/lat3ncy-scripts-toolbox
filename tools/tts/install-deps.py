#!/usr/bin/env python3
# @raycast.schemaVersion 1
# @raycast.title Install TTS Dependencies
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Install TTS dependencies (edge-tts), skip if already installed
# @raycast.icon 🔊

"""TTS 依赖安装与环境检测脚本。

通过 pip 安装 TTS 所需的 Python 依赖 (edge-tts)。依赖已存在时自动跳过。

用法：
    python install-deps.py          # 检测并安装缺失依赖
    python install-deps.py --check  # 只检测，不安装
"""

import importlib.util
import os
import shutil
import subprocess
import sys

PIP_PACKAGES: list[str] = [
    "edge-tts",
]

IMPORT_NAMES: dict[str, str] = {
    "edge-tts": "edge_tts",
}


def find_python() -> list[str] | None:
    if sys.platform == "win32":
        candidates = ["python", "py -3"]
    else:
        candidates = ["python3", "python"]
    for candidate in candidates:
        executable = candidate.split()[0]
        if shutil.which(executable):
            return candidate.split()
    return None


def is_installed(package: str) -> bool:
    module_name = IMPORT_NAMES.get(package, package)
    return importlib.util.find_spec(module_name) is not None


def check_dependencies() -> tuple[list[str], list[str]]:
    installed = []
    missing = []
    for pkg in PIP_PACKAGES:
        if is_installed(pkg):
            installed.append(pkg)
        else:
            missing.append(pkg)
    return installed, missing


def install_packages(python_cmd: list[str], packages: list[str]) -> bool:
    if not packages:
        return True
    print(f"正在安装: {', '.join(packages)} ...")
    cmd = python_cmd + ["-m", "pip", "install"] + packages
    try:
        subprocess.check_call(cmd)
        return True
    except subprocess.CalledProcessError as e:
        print(f"安装失败 (exit code {e.returncode})", file=sys.stderr)
        return False


def main() -> int:
    check_only = "--check" in sys.argv

    python_cmd = find_python()
    if not python_cmd:
        print("未找到可用的 Python 解释器。", file=sys.stderr)
        return 1

    installed, missing = check_dependencies()

    if check_only:
        print(f"已安装: {', '.join(installed) or '无'}")
        print(f"缺失: {', '.join(missing) or '无'}")
        return 1 if missing else 0

    if not missing:
        print("所有 TTS 依赖已就绪 (edge-tts)。")
        return 0

    success = install_packages(python_cmd, missing)
    if not success:
        return 1

    # 验证
    _, still_missing = check_dependencies()
    if still_missing:
        print(f"以下依赖仍未正确安装: {', '.join(still_missing)}", file=sys.stderr)
        return 1

    print("TTS 依赖安装完成！")
    return 0


if __name__ == "__main__":
    sys.exit(main())
