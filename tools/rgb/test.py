#!/usr/bin/env python3
"""最小验证：连接已常驻的 OpenRGB SDK 并列出设备。不启动 OpenRGB。"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from openrgb import OpenRGBClient


def main() -> int:
    try:
        cli = OpenRGBClient(address="127.0.0.1", port=6742, name="lat3ncy-rgb-test")
    except Exception as exc:
        print(f"[FAIL] 无法连接 SDK（需系统服务 OpenRGB 常驻，不要每次启动）: {exc}")
        print("  一次性管理员: powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/install.ps1")
        print("  或: powershell -NoProfile -ExecutionPolicy Bypass -File tools/rgb/Start-OpenRGB.ps1")
        print("  检查: Get-Service OpenRGB")
        return 1
    version = getattr(cli, "protocol_version", "?")
    print(f"[OK] 已连接 OpenRGB SDK v{version}")
    print(f"   发现 {len(cli.devices)} 个设备：")
    for i, dev in enumerate(cli.devices):
        led_n = len(dev.leds) if hasattr(dev, "leds") else "?"
        print(f"  [{i}] {dev.name} | type={dev.type} | modes={len(dev.modes)} | leds={led_n}")
        for mode in dev.modes[:5]:
            print(f"      - mode: {mode.name} ({mode.value})")
    try:
        cli.disconnect()
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
