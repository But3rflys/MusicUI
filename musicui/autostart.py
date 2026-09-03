from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from musicui import config

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
VALUE_NAME = "MusicUI"

DONE = "steam"
QUIET = "skip"

_OFF = frozenset({"off", "выкл", "0", "no", "нет", "не", "quiet", "хватит"})


def launcher() -> str:
    return "MusicUI.exe" if getattr(sys, "frozen", False) else "python -m musicui"


def steam_line() -> str:
    exe = Path(sys.executable).resolve()
    if getattr(sys, "frozen", False):
        return f'"{exe}" --launch %command%'
    entry = Path(config.BASE_DIR) / "musicui" / "__main__.py"
    return f'"{exe}" "{entry}" --launch %command%'


def to_clipboard(line: str) -> bool:
    try:
        subprocess.run(
            ["clip"],
            input=line.encode("mbcs", "replace"),
            check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return True
    except Exception:
        return False


def _drop_old_run_key() -> None:
    """Тихо убирает автозапуск старых версий: теперь островок поднимает Steam."""
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, VALUE_NAME)
    except (ImportError, OSError):
        pass


def show() -> None:
    line = steam_line()
    _drop_old_run_key()
    copied = to_clipboard(line)

    print("\nчтобы островок сам поднимался с Дотой, нужна одна строка в параметрах запуска.")
    print("вот она" + (" - уже в буфере обмена:" if copied else ":"))
    print(f"\n  {line}\n")
    print("стирать ничего не надо, просто вставить в начало.")
    print("важно: строка идёт первой, перед всеми остальными параметрами запуска.")
    print("можно вставить в Umbrella Loader или напрямую в Steam.")
    print("\nвсё, дальше запускаешь Доту как обычно - MusicUI включится вместе с ней")
    print("и выключится, когда выйдешь из игры. Возвращаться сюда не надо,")
    print("пока папка с MusicUI не переедет в другое место.")
    print(f"\nпоказать строку снова: {launcher()} --autostart")
    if not getattr(sys, "frozen", False):
        print("это строка для запуска через python; собери exe - python tools/build.py - и возьми новую.")


def _quiet() -> None:
    _drop_old_run_key()
    config.write_autostart_choice(QUIET)
    print("\nладно, больше не напомню")
    print(f"строка для Доты, когда понадобится: {launcher()} --autostart")


def ask() -> None:
    if config.read_autostart_choice() in (DONE, QUIET):
        return
    show()


def handle(raw: str | None) -> None:
    if (raw or "").strip().lower() in _OFF:
        _quiet()
        return
    show()
