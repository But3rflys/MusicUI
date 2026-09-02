from __future__ import annotations

import math
import threading
import time

from musicui import config
from musicui.audio import device_loopback, process_loopback, sessions
from musicui.audio.analyzer import EnvelopeBands, SpectrumAnalyzer, SyntheticBands

PEAK_GAIN = 3.2


class Equalizer(threading.Thread):
    def __init__(self, store, verbose: bool = False):
        super().__init__(name="di-equalizer", daemon=True)
        self.store = store
        self.verbose = verbose

        self.watcher = sessions.SessionWatcher()
        self.envelope = EnvelopeBands(config.DEFAULT_BANDS)
        self.synth = SyntheticBands(config.DEFAULT_BANDS)
        self.analyzer = None
        if SpectrumAnalyzer.AVAILABLE:
            self.analyzer = SpectrumAnalyzer(config.DEFAULT_BANDS)

        self.enabled = True
        self.bands_count = config.DEFAULT_BANDS

        self._stop = threading.Event()
        self._frames_lock = threading.Lock()
        self._frames: list = []

        self._capture = None
        self._capture_pid = None
        self._proc_fails = 0
        self._proc_disabled = not process_loopback.AVAILABLE
        self._device = None
        self._gate = 0.0
        self._note = None

    def configure(self, bands=None, music_only=None, allow_unknown=None):
        if bands is not None:
            self.bands_count = max(1, min(int(bands), config.MAX_BANDS))
            self.envelope.set_bands(self.bands_count)
            self.synth.set_bands(self.bands_count)
            if self.analyzer:
                self.analyzer.set_bands(self.bands_count)
        if music_only is not None:
            self.watcher.music_only = bool(music_only)
        if allow_unknown is not None:
            self.watcher.allow_unknown = bool(allow_unknown)

    def stop(self):
        self._stop.set()
        self.watcher.stop()
        self._release_capture()
        if self._device:
            self._device.stop()

    def diagnostics(self) -> dict:
        snap = self.watcher.snapshot()
        return {
            "sessions_available": self.watcher.available,
            "sessions_error": self.watcher.error,
            "process_loopback": not self._proc_disabled,
            "process_error": process_loopback.IMPORT_ERROR,
            "device_loopback": device_loopback.AVAILABLE,
            "device_error": device_loopback.IMPORT_ERROR,
            "fft": SpectrumAnalyzer.AVAILABLE,
            "note": self._note,
            "snapshot": snap,
        }

    def _on_frames(self, mono):
        with self._frames_lock:
            self._frames.append(mono)
            if len(self._frames) > 32:
                del self._frames[:-8]

    def _take_frames(self):
        with self._frames_lock:
            if not self._frames:
                return None
            chunk, self._frames = self._frames, []
        if len(chunk) == 1:
            return chunk[0]
        try:
            import numpy as np
            return np.concatenate(chunk)
        except Exception:
            return chunk[-1]

    def _release_capture(self):
        if self._capture:
            self._capture.stop()
            self._capture = None
            self._capture_pid = None

    def _ensure_process_capture(self, pid):
        if self._proc_disabled or self.analyzer is None:
            return False

        if self._capture and self._capture_pid == pid:
            if self._capture.ok:
                return True
            if self._capture.started_event.is_set():
                error = self._capture.error
                self._release_capture()
                self._proc_fails += 1
                if self._proc_fails >= 2:
                    self._proc_disabled = True
                    self._note = f"process loopback недоступен -> микс ({error})"
                    if self.verbose:
                        print(f"[audio] {self._note}")
                return False
            return False

        self._release_capture()
        if pid is None:
            return False

        self._capture = process_loopback.ProcessLoopbackCapture(pid, self._on_frames)
        self._capture_pid = pid
        self._capture.start()
        return False

    def _ensure_device_capture(self):
        if self.analyzer is None or not device_loopback.AVAILABLE:
            return False
        if self._device is None or not self._device.is_alive():
            self._device = device_loopback.DeviceLoopback(self._on_frames)
            self._device.start()
            return False
        return self._device.ok

    def run(self):
        self.watcher.start()
        period = 1.0 / max(1, config.AUDIO_FPS)
        last = time.monotonic()

        while not self._stop.is_set():
            now = time.monotonic()
            dt = min(max(now - last, 1e-4), 0.25)
            last = now

            try:
                self._tick(dt)
            except Exception as exc:
                if self.verbose:
                    print(f"[audio] {type(exc).__name__}: {exc}")

            self._stop.wait(period)

    def _tick(self, dt: float):
        if not self.enabled:
            self.store.set_bands([0.0] * self.bands_count, "off", None, self._note)
            return

        snap = self.watcher.snapshot()
        music_pid = snap["music_pid"]
        music_name = snap["music_name"]
        music_peak = snap["music_peak"]
        amp = min(1.0, music_peak * PEAK_GAIN)

        has_track = self.store.current_track_id() is not None
        playing = self.store.is_playing() if has_track else True
        wants_sound = playing and (snap["music_active"] or not self.watcher.available)
        target_gate = 1.0 if wants_sound else 0.0
        k = 1.0 - math.exp(-dt / (0.05 if target_gate > self._gate else config.GATE_RELEASE_SEC))
        self._gate += (target_gate - self._gate) * k

        source = "off"
        levels = None

        if self._ensure_process_capture(music_pid):
            frames = self._take_frames()
            if frames is not None:
                self.analyzer.feed(frames)
            levels = self.analyzer.compute(dt)
            source = "process"
            self._note = f"process loopback: {music_name} (pid {music_pid})"

        elif self._ensure_device_capture():
            polluted = snap["other_peak"] > max(music_peak, config.SILENCE_PEAK) * 1.2
            if polluted:
                levels = self.envelope.update(amp, dt)
                source = "envelope"
                self._note = f"микс занят {snap['other_name']} -> огибающая {music_name}"
            else:
                frames = self._take_frames()
                if frames is not None:
                    self.analyzer.feed(frames)
                levels = self.analyzer.compute(dt)
                source = "device"
                self._note = f"микс устройства, уровень от {music_name}"

        elif self.watcher.available and music_pid is not None:
            levels = self.envelope.update(amp, dt)
            source = "envelope"
            self._note = f"огибающая {music_name}"

        else:
            levels = self.synth.update(playing, dt)
            source = "synth"

        if len(levels) != self.bands_count:
            levels = (levels + [0.0] * self.bands_count)[:self.bands_count]

        gated = [level * self._gate for level in levels]
        if self._gate < 0.02:
            source = "idle" if source != "off" else source

        self.store.set_bands(gated, source, music_name, self._note)
