"""Opt-in synthetic image delivery to the real Windows clipboard."""
import ctypes
from ctypes import wintypes
import io
from pathlib import Path
import time


def sequence() -> int:
    return int(ctypes.windll.user32.GetClipboardSequenceNumber())


def record_sequence(path: Path) -> None:
    temporary = path.with_suffix('.tmp')
    temporary.write_text(str(sequence()), encoding='ascii')
    temporary.replace(path)


def copy_image(image, lease: Path) -> None:
    data = io.BytesIO()
    image.convert('RGB').save(data, format='BMP')
    dib = data.getvalue()[14:]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    user = ctypes.WinDLL('user32', use_last_error=True)
    kernel.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel.GlobalAlloc.restype = wintypes.HGLOBAL
    kernel.GlobalLock.argtypes = [wintypes.HGLOBAL]
    kernel.GlobalLock.restype = ctypes.c_void_p
    kernel.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    kernel.GlobalFree.argtypes = [wintypes.HGLOBAL]
    user.OpenClipboard.argtypes = [wintypes.HWND]
    user.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    user.SetClipboardData.restype = wintypes.HANDLE
    user.CreateWindowExW.argtypes = [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
        ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, ctypes.c_void_p]
    user.CreateWindowExW.restype = wintypes.HWND
    user.DestroyWindow.argtypes = [wintypes.HWND]
    handle = kernel.GlobalAlloc(2, len(dib))  # GMEM_MOVEABLE
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    opened, mutated, owner = False, False, None
    try:
        pointer = kernel.GlobalLock(handle)
        if not pointer:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            ctypes.memmove(pointer, dib, len(dib))
        finally:
            kernel.GlobalUnlock(handle)
        owner = user.CreateWindowExW(0, 'STATIC', 'Toolbox clipboard fixture owner', 0, 0, 0, 0, 0, None, None, None, None)
        if not owner:
            raise ctypes.WinError(ctypes.get_last_error())
        for _ in range(20):
            if user.OpenClipboard(owner):
                opened = True
                break
            time.sleep(.025)
        if not opened or not user.EmptyClipboard():
            raise ctypes.WinError(ctypes.get_last_error())
        mutated = True
        if not user.SetClipboardData(8, handle):  # CF_DIB; ownership transfers
            raise ctypes.WinError(ctypes.get_last_error())
        handle = None
    finally:
        if opened:
            user.CloseClipboard()
        if owner:
            user.DestroyWindow(owner)
        if handle:
            kernel.GlobalFree(handle)
        if mutated:
            record_sequence(lease)
