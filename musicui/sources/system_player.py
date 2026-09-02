from __future__ import annotations

import asyncio
import hashlib
import threading
import time
from datetime import datetime, timezone

from musicui import config

try:
    from winrt.windows.media.control import (
        GlobalSystemMediaTransportControlsSessionManager as _Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as _Status,
    )
    from winrt.windows.storage.streams import DataReader as _DataReader
except ImportError:                                     # pragma: no cover
    _Manager = None

_DRIFT_SLACK = 5.0
_MAX_DRIFT = 30.0

def _app_key(session) -> str:
    raw = (session.source_app_user_model_id or "").lower()
    return raw.rsplit("\\", 1)[-1].rsplit("!", 1)[-1]


def _seconds(delta) -> float:
    return delta.total_seconds() if delta is not None else 0.0


def _track_id(title: str, artist: str, album: str) -> str:
    key = "\x1f".join((artist, title, album))
    return "sys:" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]


class _Loop:
    def __init__(self):
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._spin, name="di-winrt", daemon=True)
        self._thread.start()

    def _spin(self):
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def call(self, coro, timeout: float = 4.0):
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        try:
            return future.result(timeout)
        except TimeoutError:
            future.cancel()
            raise

    def stop(self):
        self._loop.call_soon_threadsafe(self._loop.stop)


class SystemPlayer:
    poll = config.SYSTEM_POLL
    poll_idle = config.SYSTEM_POLL_IDLE

    def __init__(self):
        if _Manager is None:
            raise RuntimeError(
                "Нет доступа к системной медиасессии: pip install -r requirements.txt"
            )
        self._loop = _Loop()
        self._manager = self._loop.call(self._open())
        self.last_error = None
        self.source_app = None

        self._art_lock = threading.Lock()
        self._art_id = None
        self._art_props = None

        self._clock_key = None
        self._clock_pos = 0.0
        self._clock_at = 0.0
        self._clock_playing = False
        self._clock_raw = 0.0

    async def _open(self):
        return await _Manager.request_async()

    def stop(self):
        self._loop.stop()

    def _session(self):
        current = self._manager.get_current_session()
        if current is not None and _app_key(current) not in config.IGNORE_APPS:
            return current

        fallback = None
        for session in self._manager.get_sessions() or ():
            if _app_key(session) in config.IGNORE_APPS:
                continue
            if session.get_playback_info().playback_status == _Status.PLAYING:
                return session
            fallback = fallback or session
        return fallback

    async def _read(self):
        session = self._session()
        if session is None:
            return None

        info = session.get_playback_info()
        status = info.playback_status
        if status in (_Status.CLOSED, _Status.STOPPED):
            return None

        props = await session.try_get_media_properties_async()
        title = (props.title or "").strip()
        if not title:
            return None

        artist = (props.artist or props.album_artist or "").strip()
        album = (props.album_title or "").strip()

        timeline = session.get_timeline_properties()
        start = _seconds(timeline.start_time)
        duration = max(0.0, _seconds(timeline.end_time) - start)
        raw = max(0.0, _seconds(timeline.position) - start)
        playing = status == _Status.PLAYING

        track_id = _track_id(title, artist, album)
        position = self._advance(track_id, timeline.last_updated_time,
                                 raw, duration, playing)
        if duration:
            position = min(position, duration)

        with self._art_lock:
            self._art_id, self._art_props = track_id, props
        self.source_app = _app_key(session)

        return {
            "track_id": track_id,
            "track_name": title,
            "artist_name": artist,
            "album_name": album,
            "duration_sec": duration,
            "progress_sec": position,
            "is_playing": playing,
            "cover_url": None,
        }

    def _advance(self, track_id, stamp, raw: float, duration: float,
                 playing: bool) -> float:
        
        now = time.monotonic()
        key = (track_id, stamp)

        if key != self._clock_key:
            position = raw
            if playing and stamp is not None:
                drift = (datetime.now(timezone.utc) - stamp).total_seconds()
                limit = duration + _DRIFT_SLACK if duration else _MAX_DRIFT
                if 0.0 < drift < limit:
                    position += drift
        else:
            position = self._clock_pos
            if self._clock_playing:
                position += now - self._clock_at
            if abs(raw - self._clock_raw) > 0.35 and abs(raw - position) > 3.0:
                position = raw

        self._clock_key = key
        self._clock_pos = max(0.0, position)
        self._clock_at = now
        self._clock_playing = playing
        self._clock_raw = raw
        return self._clock_pos

    def get_playback(self):
        try:
            playback = self._loop.call(self._read())
            self.last_error = None
            return playback
        except Exception as exc:
            self.last_error = type(exc).__name__
            return None

    async def _artwork(self, props):
        reference = props.thumbnail
        if reference is None:
            return None

        stream = await reference.open_read_async()
        size = stream.size
        if not size:
            return None

        reader = _DataReader(stream)
        try:
            await reader.load_async(size)
            buffer = bytearray(size)
            reader.read_bytes(buffer)
        finally:
            reader.close()
        return bytes(buffer)

    def artwork(self, track_id: str) -> bytes | None:
        with self._art_lock:
            if track_id != self._art_id or self._art_props is None:
                return None
            props = self._art_props

        try:
            return self._loop.call(self._artwork(props), timeout=6.0)
        except Exception:
            return None

    async def _command(self, name: str, *args) -> tuple[bool, str]:
        session = self._session()
        if session is None:
            return False, "no-session"
        return bool(await getattr(session, name)(*args)), "system"

    def _run(self, name: str, *args) -> tuple[bool, str]:
        try:
            ok, reason = self._loop.call(self._command(name, *args))
        except Exception as exc:
            return False, type(exc).__name__
        return (True, reason) if ok else (False, "refused")

    def play(self):
        return self._run("try_play_async")

    def pause(self):
        return self._run("try_pause_async")

    def next_track(self):
        return self._run("try_skip_next_async")

    def previous_track(self):
        return self._run("try_skip_previous_async")

    def seek(self, position_sec: float):
        ticks = int(max(0.0, position_sec) * 10_000_000)
        return self._run("try_change_playback_position_async", ticks)
