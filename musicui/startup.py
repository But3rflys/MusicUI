from __future__ import annotations

import sys

from musicui import config, logbook
from musicui import spotify_setup

_SETUP_KEYS = frozenset({"k", "к"})

_journal = logbook.get("start")


def _match(raw: str) -> str | None:
    if not raw:
        return None

    if raw.isdigit():
        index = int(raw) - 1
        if 0 <= index < len(config.MODES):
            return config.MODES[index][0]
        return None

    for name, title, _hint in config.MODES:
        if name.startswith(raw) or title.lower().startswith(raw):
            return name
    return None


def parse_mode(raw: str) -> str:
    mode = _match(raw.strip().lower())
    if mode is None:
        names = ", ".join(name for name, _, _ in config.MODES)
        _journal.error(f"unknown mode {raw!r}, available: {names}")
        print(f"Неизвестный режим {raw!r}. Доступны: {names}")
        sys.exit(2)
    return mode


def _menu(numbers: dict[str, int]) -> None:
    width = max(len(title) for _, title, _ in config.MODES)
    status = config.credentials_status()
    verb = "настроить" if status == "не настроены" else "заменить"

    print("\nMusicUI // музыкальный оверлей\n")
    for name, title, hint in config.MODES:
        print(f"  {numbers[name]}  {title.ljust(width)}   {hint}")
    print(f"\n  k  ключи Spotify: {status} — {verb}\n")


def choose_mode() -> str:
    default = config.read_last_mode() or config.MODES[0][0]

    if not sys.stdin or not sys.stdin.isatty():
        _journal.debug(f"no console, using the last mode: {default}")
        print(f"режим: {config.mode_title(default)} (как в прошлый раз)")
        return default

    numbers = {name: i for i, (name, _, _) in enumerate(config.MODES, 1)}
    prompt = f"режим [{numbers[default]}]: "
    _menu(numbers)

    while True:
        try:
            raw = input(prompt).strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return default

        if not raw:
            return default
        if raw in _SETUP_KEYS:
            spotify_setup.wizard()
            _menu(numbers)
            continue
        mode = _match(raw)
        if mode is not None:
            return mode
        print("нужен номер режима или k - ключи Spotify")


def build_player(mode: str):
    if mode == config.MODE_SPOTIFY:
        try:
            spotify_setup.ensure()
            client_id, client_secret = config.load_credentials()
            from musicui.sources.spotify_player import SpotifyPlayer

            return SpotifyPlayer(client_id, client_secret), mode, "spotify", None
        except Exception as exc:
            _journal.warning(f"Spotify unavailable: {exc}", exc_info=True)
            print(f"Spotify недоступен: {exc}")
            print(f"переключаюсь на «{config.mode_title(config.FALLBACK_MODE)}»\n")
            mode = config.FALLBACK_MODE

    try:
        from musicui.sources.system_player import SystemPlayer

        return SystemPlayer(), mode, "system", None
    except Exception as exc:
        _journal.error(f"system media session unavailable: {exc}", exc_info=True)
        print(f"Системная медиасессия недоступна: {exc}")
        print("останутся только эквалайзер и медиаклавиши - без названия трека")
        return None, mode, "mediakeys", str(exc)
