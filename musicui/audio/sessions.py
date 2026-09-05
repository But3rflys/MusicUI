from __future__ import annotations

import threading
import time
from ctypes import POINTER, c_float, c_uint32, c_ulong

from musicui import config, logbook

BROWSERS = frozenset({
    "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "browser.exe"
})

MUSIC, IGNORE, UNKNOWN = "music", "ignore", "unknown"

_journal = logbook.get("sessions")

try:
    import comtypes
    from comtypes import COMMETHOD, GUID, IUnknown
    from ctypes import HRESULT

    try:
        from pycaw.pycaw import AudioUtilities
    except ImportError:
        from pycaw.utils import AudioUtilities

    class IAudioMeterInformation(IUnknown):
        _iid_ = GUID("{C02216F6-8C67-4B5B-9D00-D008E73E0064}")
        _methods_ = (
            COMMETHOD([], HRESULT, "GetPeakValue",
                      (["out"], POINTER(c_float), "pfPeak")),
            COMMETHOD([], HRESULT, "GetMeteringChannelCount",
                      (["out"], POINTER(c_uint32), "pnChannelCount")),
            COMMETHOD([], HRESULT, "GetChannelsPeakValues",
                      (["in"], c_uint32, "u32ChannelCount"),
                      (["out"], POINTER(c_float), "afPeakValues")),
            COMMETHOD([], HRESULT, "QueryHardwareSupport",
                      (["out"], POINTER(c_ulong), "pdwHardwareSupportMask")),
        )

    AVAILABLE = True
    IMPORT_ERROR = None
except Exception as exc:
    AVAILABLE = False
    IMPORT_ERROR = f"{type(exc).__name__}: {exc}"
    AudioUtilities = None
    comtypes = None


def classify(process_name: str | None) -> str:
    if not process_name:
        return UNKNOWN
    name = process_name.lower()
    if name in config.IGNORE_APPS:
        return IGNORE
    if name in config.MUSIC_APPS:
        return MUSIC
    return UNKNOWN


def _priority(name: str) -> int:
    if name == "spotify.exe":
        return 3
    if name in BROWSERS:
        return 1
    return 2


def _volume_app(tracked, playing_name):
    if playing_name:
        return playing_name

    best = None
    for item in tracked:
        if item.volume is None or item.kind != MUSIC:
            continue
        key = (_priority(item.name), item.peak)
        if best is None or key > best[0]:
            best = (key, item)
    return best[1].name if best else None


class _Tracked:
    __slots__ = ("pid", "name", "kind", "meter", "volume", "peak", "dead")

    def __init__(self, pid, name, kind, meter, volume):
        self.pid = pid
        self.name = name
        self.kind = kind
        self.meter = meter
        self.volume = volume
        self.peak = 0.0
        self.dead = False


class SessionWatcher(threading.Thread):
    def __init__(self):
        super().__init__(name="di-sessions", daemon=True)
        self.available = AVAILABLE
        self.error = IMPORT_ERROR

        self._trouble = logbook.Changed("sessions")
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._tracked: list[_Tracked] = []
        self._last_enum = 0.0

        self._music_pid = None
        self._music_name = None
        self._music_peak = 0.0
        self._music_seen = 0.0
        self._other_name = None
        self._other_peak = 0.0

        self._volume_app = None
        self._volume_level = None
        self._volume_mute = False
        self._volume_read = 0.0
        self._want_level = None
        self._want_mute = None

        self.allow_unknown = config.UNKNOWN_COUNTS_AS_MUSIC
        self.music_only = True

    def stop(self):
        self._stop.set()

    def set_volume(self, level: float) -> float:
        level = max(0.0, min(1.0, float(level)))
        with self._lock:
            self._want_level = level
            self._volume_level = level
        return level

    def set_mute(self, state: bool | None) -> bool:
        with self._lock:
            target = (not self._volume_mute) if state is None else bool(state)
            self._want_mute = target
            self._volume_mute = target
        return target

    def volume_snapshot(self) -> dict:
        with self._lock:
            return {
                "app": self._volume_app,
                "level": self._volume_level,
                "mute": self._volume_mute,
            }

    def snapshot(self) -> dict:
        with self._lock:
            active = (
                self._music_pid is not None
                and time.monotonic() - self._music_seen < config.SOURCE_STICKY_SEC
            )
            return {
                "music_pid": self._music_pid,
                "music_name": self._music_name,
                "music_peak": self._music_peak,
                "music_active": active,
                "other_name": self._other_name,
                "other_peak": self._other_peak,
                "sessions": [
                    {"pid": t.pid, "name": t.name, "kind": t.kind, "peak": round(t.peak, 4)}
                    for t in self._tracked
                ],
            }

    def run(self):
        if not self.available:
            _journal.error(f"mixer unavailable: {self.error}")
            return

        comtypes.CoInitialize()
        try:
            period = 1.0 / max(1, config.SESSION_POLL_FPS)
            while not self._stop.is_set():
                now = time.monotonic()
                if now - self._last_enum >= config.SESSION_ENUM_INTERVAL or any(
                    t.dead for t in self._tracked
                ):
                    self._enumerate()
                    self._last_enum = now

                self._poll_peaks()
                self._pick_source()
                self._apply_volume()
                self._read_volume(now)
                self._stop.wait(period)
        finally:
            comtypes.CoUninitialize()

    def _enumerate(self):
        try:
            sessions = AudioUtilities.GetAllSessions()
            self._trouble.clear()
        except Exception as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            self._trouble.say(f"mixer sweep failed: {self.error}")
            return

        tracked: list[_Tracked] = []
        for session in sessions:
            try:
                pid = session.ProcessId
                if not pid:
                    continue
                name = session.Process.name() if session.Process else None
                if not name:
                    continue
                meter = session._ctl.QueryInterface(IAudioMeterInformation)
            except Exception:
                continue
            try:
                volume = session.SimpleAudioVolume
            except Exception:
                volume = None
            tracked.append(_Tracked(pid, name.lower(), classify(name), meter, volume))

        with self._lock:
            before = {(item.pid, item.name) for item in self._tracked}
            self._tracked = tracked

        now = {(item.pid, item.name) for item in tracked}
        kinds = {(item.pid, item.name): item.kind for item in tracked}
        for pid, name in sorted(now - before):
            _journal.debug(f"+ {name} pid {pid} [{kinds[(pid, name)]}]")
        for pid, name in sorted(before - now):
            _journal.debug(f"- {name} pid {pid}")

    def _poll_peaks(self):
        with self._lock:
            tracked = list(self._tracked)

        for item in tracked:
            try:
                item.peak = float(item.meter.GetPeakValue())
            except Exception:
                item.dead = True
                item.peak = 0.0

    def _pick_source(self):
        now = time.monotonic()
        best = None
        loudest_other = None

        with self._lock:
            tracked = list(self._tracked)

        for item in tracked:
            is_music = item.kind == MUSIC or (item.kind == UNKNOWN and self.allow_unknown)
            if not self.music_only:
                is_music = item.kind != IGNORE

            if is_music:
                if item.peak > config.SILENCE_PEAK:
                    key = (_priority(item.name), item.peak)
                    if best is None or key > best[0]:
                        best = (key, item)
            elif item.peak > config.SILENCE_PEAK:
                if loudest_other is None or item.peak > loudest_other.peak:
                    loudest_other = item

        with self._lock:
            was_pid, was_name = self._music_pid, self._music_name
            if best is not None:
                item = best[1]
                self._music_pid = item.pid
                self._music_name = item.name
                self._music_peak = item.peak
                self._music_seen = now
            else:
                if now - self._music_seen >= config.SOURCE_STICKY_SEC:
                    self._music_pid = None
                    self._music_name = None
                self._music_peak = 0.0

            self._other_name = loudest_other.name if loudest_other else None
            self._other_peak = loudest_other.peak if loudest_other else 0.0

            app = _volume_app(tracked, self._music_name)
            switched = app is not None and app != self._volume_app
            if switched:
                self._volume_app = app
                self._volume_level = None
                self._volume_read = 0.0

            source = (self._music_pid, self._music_name)

        if source != (was_pid, was_name):
            pid, name = source
            _journal.info(f"audio source: {name} (pid {pid})" if name
                          else "audio source gone")
        if switched:
            _journal.debug(f"reading volume from {app}")

    def _apply_volume(self):
        with self._lock:
            level, mute = self._want_level, self._want_mute
            self._want_level = self._want_mute = None
            targets = [item for item in self._tracked
                       if item.volume is not None and item.name == self._volume_app]

        if level is None and mute is None:
            return

        _journal.debug(f"mixer: level={level} mute={mute} targets={len(targets)}")
        for item in targets:
            try:
                if level is not None:
                    item.volume.SetMasterVolume(level, None)
                if mute is not None:
                    item.volume.SetMute(mute, None)
            except Exception as exc:
                item.dead = True
                _journal.debug(f"{item.name} rejected volume: {type(exc).__name__}: {exc}")

    def _read_volume(self, now: float):
        if now - self._volume_read < config.VOLUME_READ_INTERVAL:
            return
        self._volume_read = now

        with self._lock:
            target = next((item for item in self._tracked
                           if item.volume is not None and item.name == self._volume_app), None)
        if target is None:
            return

        try:
            level = round(float(target.volume.GetMasterVolume()), 3)
            mute = bool(target.volume.GetMute())
        except Exception as exc:
            target.dead = True
            _journal.debug(f"{target.name} gave no volume: {type(exc).__name__}: {exc}")
            return

        with self._lock:
            if self._want_level is None:
                self._volume_level = level
            if self._want_mute is None:
                self._volume_mute = mute
