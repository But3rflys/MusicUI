from __future__ import annotations

import threading
import time

from musicui import config
from musicui.core.lyrics_book import LyricsBook


class StateStore:
    _MAX_ZERO_GLITCHES = 8

    def __init__(self):
        self._lock = threading.RLock()
        self._v = 1

        self._track = None
        self._playing = False
        self._pos = 0.0
        self._pos_ts = time.monotonic()
        self._zero_glitches = 0
        self._cover = None
        self._book = LyricsBook()
        self._lyrics_state = "idle"

        self._bands = [0.0] * config.DEFAULT_BANDS
        self._band_source = "off"
        self._source_app = None
        self._audio_note = None

        self._mode = config.MODE_SPOTIFY
        self._player_backend = "?"
        self._player_error = None

    def _bump(self):
        self._v += 1

    def set_playback(self, playback: dict | None):
        with self._lock:
            if playback is None:
                if self._track is not None:
                    self._track = None
                    self._cover = None
                    self._book = LyricsBook()
                    self._lyrics_state = "idle"
                    self._bump()
                self._playing = False
                return None

            track_id = playback.get("track_id")
            changed = self._track is None or self._track.get("track_id") != track_id
            was_at = 0.0 if changed else self.position_now_locked()

            self._track = {
                "track_id": track_id,
                "title": playback.get("track_name") or "",
                "artist": playback.get("artist_name") or "",
                "album": playback.get("album_name") or "",
                "duration": float(playback.get("duration_sec") or 0.0),
                "cover_url": playback.get("cover_url"),
            }
            self._playing = bool(playback.get("is_playing"))

            pos = float(playback.get("progress_sec") or 0.0)
            if (not changed and self._playing
                    and pos < 1.0 and was_at > 5.0
                    and self._zero_glitches < self._MAX_ZERO_GLITCHES):
                self._zero_glitches += 1
                pos = was_at
            else:
                self._zero_glitches = 0

            self._pos = pos
            self._pos_ts = time.monotonic()

            if changed:
                self._cover = None
                self._book = LyricsBook()
                self._lyrics_state = "searching"
                self._bump()

            return track_id if changed else None

    def set_cover(self, track_id: str, cover: dict | None):
        with self._lock:
            if not self._track or self._track.get("track_id") != track_id:
                return
            self._cover = cover
            self._bump()

    def set_lyrics(self, track_id: str, mode, entries):
        with self._lock:
            if not self._track or self._track.get("track_id") != track_id:
                return
            self._book = LyricsBook(mode, entries)
            self._lyrics_state = "found" if self._book else "missing"
            self._bump()

    def set_player_backend(self, backend: str, error: str | None = None):
        with self._lock:
            self._player_backend = backend
            self._player_error = error

    def set_mode(self, mode: str):
        with self._lock:
            self._mode = mode

    def player_backend(self) -> str:
        with self._lock:
            return self._player_backend

    def nudge_playing(self, playing: bool):
        with self._lock:
            self._pos = self.position_now_locked()
            self._pos_ts = time.monotonic()
            self._playing = playing

    def nudge_position(self, position: float):
        with self._lock:
            self._pos = max(0.0, position)
            self._pos_ts = time.monotonic()

    def set_bands(self, bands, source: str, app: str | None, note: str | None = None):
        with self._lock:
            self._bands = [round(float(b), 3) for b in bands]
            self._band_source = source
            self._source_app = app
            self._audio_note = note

    def position_now_locked(self) -> float:
        if not self._track:
            return 0.0
        pos = self._pos
        if self._playing:
            pos += time.monotonic() - self._pos_ts
        return max(0.0, min(pos, self._track["duration"] or pos))

    def position_now(self) -> float:
        with self._lock:
            return self.position_now_locked()

    def is_playing(self) -> bool:
        with self._lock:
            return self._playing and self._track is not None

    def current_track_id(self):
        with self._lock:
            return self._track.get("track_id") if self._track else None

    def cover_b64(self):
        with self._lock:
            return self._cover.get("b64") if self._cover else None

    def snapshot_tick(self) -> dict:
        with self._lock:
            pos = self.position_now_locked()
            return {
                "v": self._v,
                "ok": self._track is not None,
                "playing": self._playing,
                "pos": round(pos, 3),
                "bands": self._bands,
                "band_source": self._band_source,
                "line": self._book.index_at(pos) if self._book else -1,
            }

    def snapshot_state(self) -> dict:
        with self._lock:
            pos = self.position_now_locked()
            track = dict(self._track) if self._track else None
            if track:
                track.pop("cover_url", None)

            line_index = self._book.index_at(pos) if self._book else -1
            window = self._book.window(line_index, config.LYRICS_WINDOW) if self._book else []

            cover = None
            if self._cover:
                cover = {"url": self._cover.get("url"), "colors": self._cover.get("colors")}

            return {
                "v": self._v,
                "ok": track is not None,
                "playing": self._playing,
                "pos": round(pos, 3),
                "track": track,
                "cover": cover,
                "bands": self._bands,
                "band_source": self._band_source,
                "source_app": self._source_app,
                "audio_note": self._audio_note,
                "mode": self._mode,
                "player_backend": self._player_backend,
                "player_error": self._player_error,
                "lyrics": {
                    "mode": self._book.mode,
                    "state": self._lyrics_state,
                    "line": line_index,
                    "count": len(self._book.lines),
                    "window": window,
                },
            }