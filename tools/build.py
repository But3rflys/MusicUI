from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
ENTRY = Path("musicui") / "__main__.py"
NAME = "MusicUI"
WORK = BASE / "build"

COLLECT = ("winrt", "comtypes", "pycaw", "syncedlyrics")

EXCLUDE = ("tkinter", "test", "unittest", "pydoc_data")


def build() -> int:
    if not (BASE / ENTRY).exists():
        print(f"нет {ENTRY} - проект неполный, качай заново")
        return 1

    if importlib.util.find_spec("PyInstaller") is None:
        print("PyInstaller не установлен:\n  pip install pyinstaller")
        return 1

    WORK.mkdir(exist_ok=True)
    args = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm", "--clean",
        "--onefile",
        "--noconsole",
        "--name", NAME,
        "--paths", str(BASE),
        "--specpath", str(WORK),
    ]
    for module in COLLECT:
        args += ["--collect-all", module]
    for module in EXCLUDE:
        args += ["--exclude-module", module]
    args.append(str(ENTRY))

    print(f"Собираю {NAME}.exe - это небыстро, пара минут.\n")
    result = subprocess.run(args, cwd=BASE)
    if result.returncode != 0:
        print("\nСборка не прошла - причина в логе выше.")
        return result.returncode

    exe = BASE / "dist" / f"{NAME}.exe"
    size = exe.stat().st_size / 1024 / 1024 if exe.exists() else 0
    print(f"\nГотово: {exe}  ({size:.0f} МБ)")
    print("Ключи и выбранный режим .exe пишет рядом с собой, внутрь не зашиты.")

    shutil.rmtree(WORK, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(build())
