from __future__ import annotations

import sys

from musicui import config

_KEY_LEN = 32
_HEX = set("0123456789abcdef")

GUIDE = f"""
Ключи Spotify - делается один раз, минут пять

Нужен аккаунт с Premium: без него Web API не отдаёт позицию трека, и режим
«Spotify» ничем не будет лучше системного.

1. developer.spotify.com/dashboard - войди своим аккаунтом Spotify
   и нажми Create app.

2. Заполни форму:

     App name          любое, например Dynamic Island
     App description   любое, например оверлей с лирикой
     Website           можно не заполнять
     Redirect URI      {config.REDIRECT_URI}
                       вставь и нажми Add рядом с полем - если строки
                       нет в списке, вход потом не сработает

   Именно 127.0.0.1, а не localhost: localhost спотик не принимает.

   Which API/SDKs are you planning to use - галочка Web API, остальное
   не нужно. Ниже согласись с Developer Terms of Service и жми Save.

3. На странице приложения открой Settings. Сверху Client ID - копируй.
   Под ним ссылка View client secret - открой и копируй secret.

4. Вставь оба значения здесь. Пустая строка - отмена.

Ключи лягут в {config.SECRETS_FILE.name} рядом с сервером. Это доступ к твоему
аккаунту: файл не выкладывай и никому не показывай.
"""


def _clean(raw: str) -> str:
    return raw.strip().strip("\"'")


def _looks_like_key(value: str) -> bool:
    return len(value) == _KEY_LEN and set(value.lower()) <= _HEX


def _ask(label: str) -> str | None:
    """Значение ключа или None, если юзер передумал."""
    while True:
        try:
            value = _clean(input(f"  {label}: "))
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        if not value:
            return None
        if _looks_like_key(value):
            return value
        print(f"  не похоже на {label}: ждём 32 символа 0-9 и a-f")


def wizard() -> bool:
    if not sys.stdin or not sys.stdin.isatty():
        return False

    print(GUIDE)

    client_id = _ask("Client ID")
    if client_id is None:
        print("  отменено\n")
        return False

    client_secret = _ask("Client secret")
    if client_secret is None:
        print("  отменено\n")
        return False

    try:
        config.save_credentials(client_id, client_secret)
    except OSError as exc:
        print(f"\n  не смог записать {config.SECRETS_FILE.name}: {exc}\n")
        return False

    print(f"\n  готово, ключи в {config.SECRETS_FILE.name}")
    print("  при первом запуске режима «Spotify» откроется браузер —")
    print("  там нужно один раз разрешить доступ.\n")
    return True


def ensure() -> bool:
    try:
        config.load_credentials()
        return True
    except RuntimeError:
        pass

    print("\nРежиму «Spotify» нужны ключи приложения, а их ещё нет.")
    return wizard()
