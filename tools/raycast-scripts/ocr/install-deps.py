#!/usr/bin/env python3
# @raycast.schemaVersion 1
# @raycast.title Install OCR Dependencies
# @raycast.mode compact
# @raycast.platform windows
# @raycast.packageName Lat3ncy Toolbox
# @raycast.description Install OCR dependencies (Pillow + RapidOCR), skip if already installed
# @raycast.icon 📦

"""Install/check the Windows Python 3.14 OCR lock; optional model download is explicit."""

import hashlib
import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from ocr_runtime import base_python, check_environment

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


def main() -> int:
    parser = argparse.ArgumentParser(description='Install/check the locked module Python 3.14 OCR environment')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--mobile-models', action='store_true', help='Also download the existing hash-verified optional models; never changes config')
    args = parser.parse_args()
    if sys.platform != 'win32':
        print(json.dumps({'status': 'unsupported', 'reason': 'windows-required'}))
        return 1
    root = Path(__file__).resolve().parent
    try:
        status = check_environment(root)
        if args.check:
            print(json.dumps(status))
            return 0 if status['status'] == 'ready' else 1
        if status['status'] != 'ready':
            uv = shutil.which('uv')
            if not uv:
                raise RuntimeError('uv is required to create/install the locked OCR environment')
            environment = root/'.venv314'
            if not (environment/'pyvenv.cfg').is_file():
                if environment.exists() and any(environment.iterdir()):
                    raise ValueError('Refusing to replace a nonempty unrecognized environment')
                subprocess.run([uv, 'venv', '--python', '3.14', str(environment)], check=True, timeout=180)
            # Validate its declared base before modifying the module environment.
            base_python(root)
            command = [uv, 'pip', 'install', '--python', str(environment/'Scripts/python.exe'),
                       '--require-hashes', '-r', str(root/'requirements.lock')]
            if status['status'] == 'broken':
                command.append('--reinstall')
            subprocess.run(command, check=True, timeout=300)
            status = check_environment(root)
        if args.mobile_models:
            ensure_mobile_models()
        print(json.dumps(status))
        return 0 if status['status'] == 'ready' else 1
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'failed', 'errorType': type(error).__name__}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
