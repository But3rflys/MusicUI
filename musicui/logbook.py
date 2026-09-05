from __future__ import annotations

import atexit
import logging
import sys
import threading
import time
import traceback
from pathlib import Path

from musicui import config

TAGS = {
    logging.DEBUG: "DEBUG",
    logging.INFO: "INFO",
    logging.WARNING: "WARN",
    logging.ERROR: "ERROR",
    logging.CRITICAL: "FATAL",
}

NOISY = ("urllib3", "requests", "comtypes", "PIL", "spotipy", "asyncio",
         "charset_normalizer", "winrt", "syncedlyrics", "websocket", "soundcard")

LEVELS = {
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warn": logging.WARNING,
    "warning": logging.WARNING,
    "error": logging.ERROR,
    "fatal": logging.CRITICAL,
}

RULE = "─" * 78
INDENT = " " * 8

logging.lastResort = None
logging.raiseExceptions = False

_started = time.monotonic()
_stream = None
_path: Path | None = None
_ready = False
_said_bye = False


class _Lines(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        stamp = time.strftime("%H:%M:%S", time.localtime(record.created))
        level = TAGS.get(record.levelno, "?").ljust(5)
        source = record.name.rpartition(".")[2][:9].ljust(9)
        body = record.getMessage()
        if record.exc_info:
            body += "\n" + "".join(traceback.format_exception(*record.exc_info)).rstrip()
        return f"{stamp}.{int(record.msecs):03d}  {level}  {source}  " + body.replace("\n", "\n" + INDENT)


class Changed:
    def __init__(self, name: str, level: int = logging.WARNING):
        self._log = get(name)
        self._level = level
        self._last = None

    def say(self, message: str, level: int | None = None) -> None:
        if message == self._last:
            return
        self._last = message
        self._log.log(self._level if level is None else level, message)

    def clear(self) -> None:
        self._last = None


def get(name: str) -> logging.Logger:
    return logging.getLogger(name if name.startswith("musicui") else f"musicui.{name}")


def level(name) -> int:
    return LEVELS.get(str(name or "").strip().lower(), logging.INFO)


def path() -> Path | None:
    return _path


def uptime() -> str:
    seconds = int(max(0.0, time.monotonic() - _started))
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}h {minutes}m {secs}s"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def _wipe() -> list[str]:
    gone = []
    for name in config.LOG_STALE:
        stale = config.BASE_DIR / name
        try:
            if stale.exists():
                stale.unlink()
                gone.append(name)
        except OSError:
            pass
    return gone


def _banner(stream) -> None:
    rows = (
        ("started", time.strftime("%Y-%m-%d %H:%M:%S")),
        ("folder", str(config.BASE_DIR)),
        ("args", " ".join(sys.argv[1:]) or "none"),
    )
    for label, value in rows:
        stream.write(f"{label:<7}  {value}\n")
    stream.write(RULE + "\n")
    stream.flush()


def _hook_main(kind, value, tb) -> None:
    if issubclass(kind, KeyboardInterrupt):
        get("exit").info("Ctrl+C")
        return
    get("crash").critical("unhandled exception", exc_info=(kind, value, tb))
    flush()


def _hook_thread(args) -> None:
    if args.exc_type is SystemExit:
        return
    name = args.thread.name if args.thread else "?"
    get("crash").critical(f"thread {name} crashed",
                          exc_info=(args.exc_type, args.exc_value, args.exc_traceback))
    flush()


def farewell() -> None:
    global _said_bye
    if _said_bye:
        return
    _said_bye = True
    get("exit").info(f"exit, uptime {uptime()}")
    flush()


def flush() -> None:
    if _stream is not None:
        try:
            _stream.flush()
        except (OSError, ValueError):
            pass


def setup(verbose: bool = False) -> Path | None:
    global _stream, _path, _ready
    if _ready:
        return _path
    _ready = True

    dropped = _wipe()

    root = logging.getLogger()
    for handler in list(root.handlers):
        root.removeHandler(handler)

    try:
        _stream = open(config.LOG_FILE, "w", encoding="utf-8", errors="replace", buffering=1)
        _banner(_stream)
        _path = config.LOG_FILE
    except OSError:
        _stream = None

    lines = _Lines()
    if _stream is not None:
        journal = logging.StreamHandler(_stream)
        journal.setFormatter(lines)
        root.addHandler(journal)
    if verbose and sys.stdout is not None:
        echo = logging.StreamHandler(sys.stdout)
        echo.setFormatter(lines)
        root.addHandler(echo)
    if not root.handlers:
        root.addHandler(logging.NullHandler())

    root.setLevel(logging.INFO)
    get("musicui").setLevel(logging.DEBUG)
    for name in NOISY:
        logging.getLogger(name).setLevel(logging.WARNING)
    logging.captureWarnings(True)

    sys.excepthook = _hook_main
    threading.excepthook = _hook_thread
    atexit.register(farewell)

    log = get("logbook")
    if _path is None:
        log.error(f"could not open the log file: {config.LOG_FILE}")
    if dropped:
        log.debug(f"removed stale: {', '.join(dropped)}")
    return _path


def crash(exc: BaseException) -> Path | None:
    if not _ready:
        setup()
    get("crash").critical("crashed", exc_info=(type(exc), exc, exc.__traceback__))
    flush()
    return _path

