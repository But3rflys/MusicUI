from __future__ import annotations

import ctypes
import threading

VK_MEDIA_NEXT_TRACK = 0xB0
VK_MEDIA_PREV_TRACK = 0xB1
VK_MEDIA_PLAY_PAUSE = 0xB3
KEYEVENTF_KEYUP = 0x0002

ACTIONS = ("play_pause", "play", "pause", "next", "prev", "seek")


def _tap(vk: int) -> bool:
    try:
        user32 = ctypes.windll.user32
        user32.keybd_event(vk, 0, 0, 0)
        user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)
        return True
    except Exception:
        return False


class Controls:
    def __init__(self, player, store, wake_poller=None):
        self.player = player
        self.store = store
        self.wake_poller = wake_poller
        self._lock = threading.Lock()

    def dispatch(self, action: str, value=None) -> dict:
        if action not in ACTIONS:
            return {"ok": False, "error": f"unknown action: {action}"}

        with self._lock:
            if action in ("play_pause", "play", "pause"):
                result = self._toggle(action)
            elif action == "next":
                result = self._skip(forward=True)
            elif action == "prev":
                result = self._skip(forward=False)
            else:
                result = self._seek(value)

        if result.get("ok") and self.wake_poller:
            self.wake_poller()
        return result

    def _toggle(self, action: str) -> dict:
        if action == "play_pause":
            target_playing = not self.store.is_playing()
        else:
            target_playing = action == "play"

        ok, backend = False, "mediakeys"
        if self.player is not None:
            call = self.player.play if target_playing else self.player.pause
            ok, backend = call()

        if not ok:
            reason = backend
            ok = _tap(VK_MEDIA_PLAY_PAUSE)
            backend = "mediakeys" if ok else f"failed ({reason})"

        if ok:
            self.store.nudge_playing(target_playing)
            self.store.set_player_backend(backend)
        return {"ok": ok, "backend": backend, "playing": target_playing}

    def _skip(self, forward: bool) -> dict:
        ok, backend = False, "mediakeys"
        if self.player is not None:
            call = self.player.next_track if forward else self.player.previous_track
            ok, backend = call()

        if not ok:
            reason = backend
            ok = _tap(VK_MEDIA_NEXT_TRACK if forward else VK_MEDIA_PREV_TRACK)
            backend = "mediakeys" if ok else f"failed ({reason})"

        if ok:
            self.store.set_player_backend(backend)
        return {"ok": ok, "backend": backend}

    def _seek(self, value) -> dict:
        try:
            position = float(value)
        except (TypeError, ValueError):
            return {"ok": False, "error": "seek требует value в секундах"}

        if self.player is None:
            return {"ok": False, "error": "перемотка недоступна: нет источника трека"}

        ok, backend = self.player.seek(position)
        if ok:
            self.store.nudge_position(position)
            self.store.set_player_backend(backend)
        else:
            backend = f"failed ({backend})"
        return {"ok": ok, "backend": backend}
