"""Minimal OpenRGB plugin stubs.

The original openrgb.plugins package was trimmed. Ambient only uses
OpenRGBClient for device/color control, but orgb.py imports this module
at top level, so we keep a no-op implementation.
"""
from __future__ import annotations

from typing import Any


class ORGBPlugin:
    """No-op SDK plugin wrapper. Ambient never talks to OpenRGB plugins."""

    def __init__(self, plugin: Any, comms: Any) -> None:
        self.name = getattr(plugin, "name", "")
        self.description = getattr(plugin, "description", "")
        self.version = getattr(plugin, "version", "")
        self.id = getattr(plugin, "id", 0)
        self.sdk_version = getattr(plugin, "sdk_version", 0)
        self.comms = comms

    def update(self) -> None:
        return None

    def _recv(self, data: Any) -> None:
        return None


def create_plugin(plugin: Any, comms: Any) -> ORGBPlugin:
    return ORGBPlugin(plugin, comms)
