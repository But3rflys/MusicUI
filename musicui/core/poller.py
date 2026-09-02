from __future__ import annotations

import threading
import time
from concurrent.futures import ThreadPoolExecutor

from musicui.core import cover
from musicui.sources.lyrics_source import fetch_lyrics

COVER_RETRIES = (0.0, 0.6, 1.5, 3.0, 5.0)

class Poller(threading.Thread):
    IDLE_GRACE = 2.0

    def __init__(self, player, store, verbose: bool = False):
        super().__init__(name="di-poller", daemon=True)
        self.player = player
        self.store = store
        self.verbose = verbose
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._fetchers = ThreadPoolExecutor(max_workers=3, thread_name_prefix="di-fetch")

        self._lyrics_cache: dict[str, tuple] = {}
        self._cover_cache: dict[str, dict] = {}

        if player is None:
            self._poll = self._poll_idle = 2.0
            self._artwork = None
        else:
            self._poll, self._poll_idle = player.poll, player.poll_idle
            self._artwork = getattr(player, "artwork", None)

    def wake(self, delay: float = 0.35):
        threading.Timer(delay, self._wake.set).start()

    def stop(self):
        self._stop.set()
        self._wake.set()

    def run(self):
        blank_since = None

        while not self._stop.is_set():
            playback = None
            try:
                if self.player is not None:
                    playback = self.player.get_playback()
            except Exception as exc:
                if self.verbose:
                    print(f"[poller] {type(exc).__name__}: {exc}")

            if playback is None and self.player is not None:
                blank_since = blank_since or time.monotonic()
                if time.monotonic() - blank_since < self.IDLE_GRACE:
                    self._sleep(self._poll)
                    continue
            else:
                blank_since = None

            changed_track = self.store.set_playback(playback)
            if changed_track and playback:
                self._on_new_track(changed_track, playback)

            self._sleep(self._poll if playback else self._poll_idle)

    def _sleep(self, seconds: float):
        self._wake.wait(seconds)
        self._wake.clear()

    def _on_new_track(self, track_id: str, playback: dict):
        if self.verbose:
            print(f"\n[track] {playback['artist_name']} — {playback['track_name']}")

        art = self._cover_cache.get(track_id)
        if art:
            self.store.set_cover(track_id, art)
        else:
            self._fetchers.submit(self._fetch_cover, track_id, playback.get("cover_url"))

        cached = self._lyrics_cache.get(track_id)
        if cached is not None:
            self.store.set_lyrics(track_id, *cached)
        else:
            self._fetchers.submit(
                self._fetch_lyrics, track_id,
                playback["track_name"], playback["artist_name"],
            )

    def _remember(self, store: dict, key: str, value):
        if len(store) > 48:
            store.clear()
        store[key] = value

    def _fetch_cover(self, track_id: str, url):
        for attempt, delay in enumerate(COVER_RETRIES):
            if delay:
                if self._stop.wait(delay):
                    return
            if self.store.current_track_id() != track_id:
                return

            art = None
            try:
                data = self._artwork(track_id) if self._artwork else None
                art = cover.build(data) if data else cover.fetch(url)
            except Exception as exc:
                if self.verbose:
                    print(f"[cover] {type(exc).__name__}: {exc}")

            if art:
                self._remember(self._cover_cache, track_id, art)
                self.store.set_cover(track_id, art)
                if self.verbose and attempt:
                    print(f"[cover] получена с {attempt + 1}-й попытки")
                return

        if self.verbose:
            print("[cover] не отдалась, оставляем плитку с акцентом")

    def _fetch_lyrics(self, track_id: str, title: str, artist: str):
        started = time.monotonic()
        try:
            mode, entries = fetch_lyrics(title, artist)
        except Exception as exc:
            mode, entries = None, []
            if self.verbose:
                print(f"[lyrics] {type(exc).__name__}: {exc}")

        self._remember(self._lyrics_cache, track_id, (mode, entries))
        self.store.set_lyrics(track_id, mode, entries)
        if self.verbose:
            took = time.monotonic() - started
            found = f"{mode}-level, {len(entries)} записей" if entries else "не найдена"
            print(f"[lyrics] {found} ({took:.1f}с)")
