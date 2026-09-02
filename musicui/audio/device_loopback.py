from __future__ import annotations

import threading

from musicui import config

try:
    import numpy as np
    import soundcard as sc
    AVAILABLE = True
    IMPORT_ERROR = None
except Exception as exc:                                # pragma: no cover
    AVAILABLE = False
    IMPORT_ERROR = f"{type(exc).__name__}: {exc}"
    np = None
    sc = None


class DeviceLoopback(threading.Thread):
    def __init__(self, on_frames, samplerate: int = config.SAMPLE_RATE, blocksize: int = 1024):
        super().__init__(name="di-device-loopback", daemon=True)
        self.on_frames = on_frames
        self.samplerate = samplerate
        self.blocksize = blocksize
        self.ok = False
        self.error = None if AVAILABLE else IMPORT_ERROR
        self.device_name = None
        self._stop = threading.Event()

    def stop(self):
        self._stop.set()

    def run(self):
        if not AVAILABLE:
            return

        try:
            speaker = sc.default_speaker()
            self.device_name = str(speaker.name)
            mic = sc.get_microphone(self.device_name, include_loopback=True)
        except Exception as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            return

        try:
            with mic.recorder(samplerate=self.samplerate, channels=1,
                              blocksize=self.blocksize) as recorder:
                self.ok = True
                while not self._stop.is_set():
                    data = recorder.record(numframes=self.blocksize)
                    if data is not None and len(data):
                        self.on_frames(np.asarray(data, dtype=np.float32).ravel())
        except Exception as exc:
            self.error = f"{type(exc).__name__}: {exc}"
        finally:
            self.ok = False
