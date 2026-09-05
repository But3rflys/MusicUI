from __future__ import annotations

import os
import sys

ATTACH_PARENT = -1


def _kernel32():
    try:
        import ctypes

        return ctypes.WinDLL("kernel32", use_last_error=True)
    except Exception:
        return None


def _devnull(mode: str):
    try:
        return open(os.devnull, mode, encoding="utf-8")
    except OSError:
        return None


def _usable(stream) -> bool:
    if stream is None:
        return False
    try:
        stream.fileno()
    except Exception:
        return False
    return True


def ensure_stdio() -> None:
    if getattr(sys, "stdin", None) is None:
        sys.stdin = _devnull("r")
    for name in ("stdout", "stderr"):
        if getattr(sys, name, None) is None:
            setattr(sys, name, _devnull("w"))


def attach(title: str = "MusicUI") -> bool:
    kernel32 = _kernel32()
    if kernel32 is None or kernel32.GetConsoleWindow():
        return False
    if _usable(sys.stdout) and _usable(sys.stdin):
        return False

    if not kernel32.AttachConsole(ATTACH_PARENT) and not kernel32.AllocConsole():
        return False

    try:
        if not _usable(sys.stdin):
            sys.stdin = open("CONIN$", "r", encoding="utf-8", errors="replace")
        for name in ("stdout", "stderr"):
            if not _usable(getattr(sys, name, None)):
                setattr(sys, name, open("CONOUT$", "w", encoding="utf-8",
                                        errors="replace", buffering=1))
    except OSError:
        ensure_stdio()
        return False

    try:
        kernel32.SetConsoleTitleW(title)
    except Exception:
        pass
    return True


def crash(exc: BaseException) -> None:
    import traceback

    from musicui import logbook

    print("".join(traceback.format_exception(exc)), file=sys.stderr)
    where = logbook.crash(exc)
    if where is not None:
        print(f"всё это лежит в логе: {where}", file=sys.stderr)
