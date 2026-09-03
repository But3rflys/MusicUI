from __future__ import annotations

import ctypes
from ctypes import wintypes

TH32CS_SNAPPROCESS = 0x0002
ERROR_BAD_LENGTH = 24
MAX_PATH = 260


class _Entry(ctypes.Structure):
    _fields_ = (
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.c_void_p),
        ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", wintypes.LONG),
        ("dwFlags", wintypes.DWORD),
        ("szExeFile", wintypes.WCHAR * MAX_PATH),
    )


def _kernel32():
    try:
        return ctypes.WinDLL("kernel32", use_last_error=True)
    except (OSError, AttributeError):
        return None


_K32 = _kernel32()
_INVALID = ctypes.c_void_p(-1).value


def available() -> bool:
    return _K32 is not None


def _walk():
    if _K32 is None:
        return

    for _ in range(3):
        snapshot = _K32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if snapshot != _INVALID and snapshot is not None:
            break
        if ctypes.get_last_error() != ERROR_BAD_LENGTH:
            return
    else:
        return

    entry = _Entry()
    entry.dwSize = ctypes.sizeof(_Entry)
    try:
        if not _K32.Process32FirstW(snapshot, ctypes.byref(entry)):
            return
        while True:
            yield entry.szExeFile.lower()
            if not _K32.Process32NextW(snapshot, ctypes.byref(entry)):
                return
    finally:
        _K32.CloseHandle(snapshot)


def running(names) -> bool:
    wanted = {name.lower() for name in names}
    return any(name in wanted for name in _walk())
