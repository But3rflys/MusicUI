from __future__ import annotations

from musicui import config

try:
    import spotipy
    from spotipy.oauth2 import SpotifyOAuth
    from spotipy.exceptions import SpotifyException
except ImportError:
    spotipy = None
    SpotifyOAuth = None

    class SpotifyException(Exception):
        http_status = 0


class SpotifyPlayer:
    poll = config.SPOTIFY_POLL
    poll_idle = config.SPOTIFY_POLL_IDLE

    def __init__(self, client_id, client_secret, redirect_uri=config.REDIRECT_URI):
        if spotipy is None:
            raise RuntimeError("Не установлен spotipy: pip install -r requirements.txt")

        self.sp = spotipy.Spotify(
            requests_timeout=6,
            retries=2,
            auth_manager=SpotifyOAuth(
                client_id=client_id,
                client_secret=client_secret,
                redirect_uri=redirect_uri,
                scope=config.SCOPE,
                cache_path=str(config.SPOTIPY_CACHE),
                open_browser=True,
            ),
        )

    def get_playback(self):
        try:
            playback = self.sp.current_playback()
        except Exception:
            return None

        if not playback or not playback.get("item"):
            return None

        item = playback["item"]
        album = item.get("album") or {}
        images = album.get("images") or []
        artists = item.get("artists") or []

        return {
            "track_id": item.get("id") or item.get("uri") or item.get("name"),
            "track_name": item.get("name") or "",
            "artist_name": ", ".join(a["name"] for a in artists if a.get("name")),
            "album_name": album.get("name") or "",
            "duration_sec": (item.get("duration_ms") or 0) / 1000,
            "progress_sec": (playback.get("progress_ms") or 0) / 1000,
            "is_playing": bool(playback.get("is_playing")),
            "cover_url": images[0]["url"] if images else None,
        }

    def _call(self, fn, *args, **kwargs) -> tuple[bool, str]:
        try:
            fn(*args, **kwargs)
            return True, "spotify"
        except SpotifyException as exc:
            status = getattr(exc, "http_status", 0)
            if status == 403:
                return False, "no-premium"
            if status == 404:
                return False, "no-device"
            return False, f"http-{status}"
        except Exception as exc:
            return False, type(exc).__name__

    def play(self):
        return self._call(self.sp.start_playback)

    def pause(self):
        return self._call(self.sp.pause_playback)

    def next_track(self):
        return self._call(self.sp.next_track)

    def previous_track(self):
        return self._call(self.sp.previous_track)

    def seek(self, position_sec: float):
        return self._call(self.sp.seek_track, int(max(0.0, position_sec) * 1000))
