from __future__ import annotations

import json
import os
import sys
from pathlib import Path

if getattr(sys, "frozen", False):
    BASE_DIR = Path(sys.executable).resolve().parent
else:
    BASE_DIR = Path(__file__).resolve().parents[1]

SECRETS_FILE = BASE_DIR / "secrets.json"
SPOTIPY_CACHE = BASE_DIR / ".cache"
LAUNCH_FILE = BASE_DIR / ".launch"

HOST = "127.0.0.1"
PORT = 8770

SPOTIFY_POLL = 1.5
SPOTIFY_POLL_IDLE = 4.0
SYSTEM_POLL = 0.25
SYSTEM_POLL_IDLE = 1.0
AUDIO_FPS = 60
SESSION_ENUM_INTERVAL = 1.0
SESSION_POLL_FPS = 20

DEFAULT_BANDS = 5
MAX_BANDS = 12
SAMPLE_RATE = 44100
FFT_SIZE = 2048
BAND_MIN_HZ = 45.0
BAND_MAX_HZ = 14000.0

SILENCE_PEAK = 0.0015
SOURCE_STICKY_SEC = 1.6
GATE_RELEASE_SEC = 0.35

MUSIC_APPS = frozenset({
    "spotify.exe",
    "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe",
    "opera_gx.exe", "yandex.exe", "яндекс музыка.exe"
})

IGNORE_APPS = frozenset({
    "discord.exe", "discordptb.exe", "discordcanary.exe",
    "ts3client_win64.exe", "ts3client_win32.exe", "teamspeak.exe",
    "telegram.exe", "dota2.exe", "steam.exe", "steamwebhelper.exe",
    "obs64.exe", "nvcontainer.exe"
})

UNKNOWN_COUNTS_AS_MUSIC = False

COVER_SIZE = 160

REDIRECT_URI = "http://127.0.0.1:8888/callback"
SCOPE = "user-read-playback-state user-modify-playback-state"

MODE_SPOTIFY = "spotify"
MODE_SYSTEM = "system"

MODES = (
    (MODE_SPOTIFY, "Spotify",
     "точная позиция и перемотка / нужен Premium и ключи"),
    (MODE_SYSTEM, "Системный",
     "любой плеер Windows / без ключей и Premium"),
)

FALLBACK_MODE = MODE_SYSTEM


def mode_title(mode: str) -> str:
    for name, title, _ in MODES:
        if name == mode:
            return title
    return mode


def read_last_mode() -> str | None:
    try:
        mode = LAUNCH_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return mode if any(mode == name for name, _, _ in MODES) else None


def write_last_mode(mode: str) -> None:
    try:
        LAUNCH_FILE.write_text(mode, encoding="utf-8")
    except OSError:
        pass

LYRICS_WINDOW = 3

def credentials_status() -> str:
    if os.environ.get("SPOTIFY_CLIENT_ID") and os.environ.get("SPOTIFY_CLIENT_SECRET"):
        return "переменные окружения"
    if SECRETS_FILE.exists():
        return SECRETS_FILE.name
    return "не настроены"


def save_credentials(client_id: str, client_secret: str) -> None:
    SECRETS_FILE.write_text(
        json.dumps({"client_id": client_id, "client_secret": client_secret}, indent=2)
        + "\n",
        encoding="utf-8",
    )
    SPOTIPY_CACHE.unlink(missing_ok=True)


def load_credentials() -> tuple[str, str]:
    cid = os.environ.get("SPOTIFY_CLIENT_ID")
    secret = os.environ.get("SPOTIFY_CLIENT_SECRET")
    if cid and secret:
        return cid, secret

    if SECRETS_FILE.exists():
        try:
            data = json.loads(SECRETS_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise RuntimeError(f"{SECRETS_FILE} повреждён: {exc}") from exc
        cid = data.get("client_id")
        secret = data.get("client_secret")
        if cid and secret:
            return cid, secret

    raise RuntimeError("ключи Spotify не настроены")