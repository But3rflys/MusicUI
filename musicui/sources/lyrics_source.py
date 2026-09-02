import logging

import syncedlyrics

from musicui.sources.lyrics_parser import parse_lyrics

_lib_log = logging.getLogger("syncedlyrics")
_lib_log.setLevel(logging.CRITICAL)
_lib_log.addHandler(logging.NullHandler())
_lib_log.propagate = False

_KNOWN_PROVIDERS = frozenset({
    "Musixmatch", "NetEase", "Lrclib", "Megalobiz", "Deezer", "Genius",
    "Lyricsify", "Spotify",
})


def _silence_provider_logs() -> None:
    names = set(_KNOWN_PROVIDERS)

    try:
        from syncedlyrics.providers.base import LRCProvider

        stack = [LRCProvider]
        while stack:
            for sub in stack.pop().__subclasses__():
                if sub.__name__ not in names:
                    stack.append(sub)
                names.add(sub.__name__)
    except Exception:
        pass

    for name in names:
        log = logging.getLogger(name)
        log.setLevel(logging.CRITICAL)
        log.propagate = False


_silence_provider_logs()


def fetch_lyrics(track_name, artist_name):
    query = f"{track_name} {artist_name}"
    lrc_text = syncedlyrics.search(query, enhanced=True)

    if not lrc_text:
        return None, []

    return parse_lyrics(lrc_text)
