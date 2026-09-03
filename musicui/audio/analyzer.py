from __future__ import annotations

import math
import random

from musicui import config

try:
    import numpy as np
except ImportError:
    np = None


def _smooth(current: float, target: float, dt: float, attack: float, decay: float) -> float:
    tau = attack if target > current else decay
    k = 1.0 - math.exp(-dt / max(tau, 1e-4))
    return current + (target - current) * k


class SpectrumAnalyzer:
    AVAILABLE = np is not None

    ATTACK = 0.035
    DECAY = 0.20
    DYN_RANGE_DB = 42.0
    REF_DECAY_DB = 7.0

    def __init__(self, bands: int = config.DEFAULT_BANDS,
                 samplerate: int = config.SAMPLE_RATE,
                 fft_size: int = config.FFT_SIZE):
        if np is None:
            raise RuntimeError("Нужен numpy: pip install -r requirements.txt")

        self.samplerate = samplerate
        self.fft_size = fft_size
        self._window = np.hanning(fft_size).astype(np.float32)
        self._buf = np.zeros(fft_size, dtype=np.float32)
        self._ref_db = -60.0
        self._levels: list[float] = []
        self._edges: list[tuple[int, int]] = []
        self._tilt: list[float] = []
        self.set_bands(bands)

    def set_bands(self, bands: int):
        bands = max(1, min(int(bands), config.MAX_BANDS))
        if len(self._levels) == bands and self._edges:
            return

        lo_hz, hi_hz = config.BAND_MIN_HZ, min(config.BAND_MAX_HZ, self.samplerate / 2 - 1)
        ratio = (hi_hz / lo_hz) ** (1.0 / bands)
        hz_per_bin = self.samplerate / self.fft_size

        edges, tilt = [], []
        for i in range(bands):
            f_lo = lo_hz * (ratio ** i)
            f_hi = lo_hz * (ratio ** (i + 1))
            b_lo = max(1, int(f_lo / hz_per_bin))
            b_hi = max(b_lo + 1, int(f_hi / hz_per_bin))
            edges.append((b_lo, min(b_hi, self.fft_size // 2)))
            tilt.append((f_lo / lo_hz) ** 0.30)

        self._edges = edges
        self._tilt = tilt
        self._levels = [0.0] * bands

    def feed(self, samples):
        if samples is None or len(samples) == 0:
            return
        chunk = np.asarray(samples, dtype=np.float32).ravel()
        if len(chunk) >= self.fft_size:
            self._buf = chunk[-self.fft_size:].copy()
        else:
            self._buf = np.concatenate((self._buf[len(chunk):], chunk))

    def compute(self, dt: float) -> list[float]:
        spectrum = np.abs(np.fft.rfft(self._buf * self._window))
        raw_db = []

        for (b_lo, b_hi), tilt in zip(self._edges, self._tilt):
            slice_ = spectrum[b_lo:b_hi]
            energy = float(np.sqrt(np.mean(slice_ * slice_))) if slice_.size else 0.0
            raw_db.append(20.0 * math.log10(energy * tilt + 1e-9))

        peak_db = max(raw_db)
        self._ref_db = max(peak_db, self._ref_db - self.REF_DECAY_DB * dt)
        floor_db = max(self._ref_db, -34.0) - self.DYN_RANGE_DB

        for i, db in enumerate(raw_db):
            target = (db - floor_db) / self.DYN_RANGE_DB
            target = min(1.0, max(0.0, target))
            self._levels[i] = _smooth(self._levels[i], target, dt, self.ATTACK, self.DECAY)

        return list(self._levels)


class EnvelopeBands:
    def __init__(self, bands: int = config.DEFAULT_BANDS):
        self._levels: list[float] = []
        self._slow = 0.0
        self._fast = 0.0
        self._phase = 0.0
        self.set_bands(bands)

    def set_bands(self, bands: int):
        bands = max(1, min(int(bands), config.MAX_BANDS))
        if len(self._levels) != bands:
            self._levels = [0.0] * bands

    def update(self, amplitude: float, dt: float) -> list[float]:
        amp = min(1.0, max(0.0, amplitude))
        self._slow = _smooth(self._slow, amp, dt, 0.09, 0.30)
        self._fast = _smooth(self._fast, amp, dt, 0.012, 0.09)
        transient = max(0.0, self._fast - self._slow) * 2.4
        self._phase += dt

        n = len(self._levels)
        for i in range(n):
            pos = i / max(1, n - 1)
            body = self._slow * (1.0 - 0.35 * pos) + transient * (0.25 + 0.75 * pos)
            wobble = 0.10 * math.sin(self._phase * (2.1 + 1.7 * i) + i * 1.9)
            target = min(1.0, max(0.0, body + wobble * self._slow))
            self._levels[i] = _smooth(self._levels[i], target, dt, 0.03, 0.18)

        return list(self._levels)


class SyntheticBands:
    def __init__(self, bands: int = config.DEFAULT_BANDS):
        self._levels: list[float] = []
        self._phase = random.random() * 10.0
        self.set_bands(bands)

    def set_bands(self, bands: int):
        bands = max(1, min(int(bands), config.MAX_BANDS))
        if len(self._levels) != bands:
            self._levels = [0.0] * bands

    def update(self, playing: bool, dt: float) -> list[float]:
        self._phase += dt
        n = len(self._levels)
        for i in range(n):
            if not playing:
                target = 0.0
            else:
                a = math.sin(self._phase * (1.7 + 0.53 * i) + i)
                b = math.sin(self._phase * (0.61 + 0.29 * i) + i * 2.3)
                target = 0.42 + 0.28 * a + 0.16 * b
                target = min(1.0, max(0.06, target))
            self._levels[i] = _smooth(self._levels[i], target, dt, 0.08, 0.22)
        return list(self._levels)
