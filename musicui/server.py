from __future__ import annotations

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from musicui import config
from musicui import startup
from musicui.audio.equalizer import Equalizer
from musicui.core.controls import Controls
from musicui.core.poller import Poller
from musicui.core.state import StateStore

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def _truthy(value: str | None) -> bool | None:
    if value is None:
        return None
    return value.lower() in ("1", "true", "yes", "on")


class Island:
    def __init__(self, mode: str, verbose: bool = False):
        self.store = StateStore()
        self.verbose = verbose

        player, self.mode, backend, self.player_error = startup.build_player(mode)
        self.player = player
        self.store.set_mode(self.mode)
        self.store.set_player_backend(backend, self.player_error)

        self.poller = Poller(self.player, self.store, verbose)
        self.controls = Controls(self.player, self.store, wake_poller=self.poller.wake)
        self.equalizer = Equalizer(self.store, verbose)

    def start(self):
        self.poller.start()
        self.equalizer.start()

    def stop(self):
        self.poller.stop()
        self.equalizer.stop()
        stop = getattr(self.player, "stop", None)
        if stop:
            stop()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    island: Island = None
    server_version = "MusicUI/1.0"

    def log_message(self, *_args):
        pass

    def _send(self, payload: dict, status: int = 200):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_text(self, text: str, status: int = 200):
        body = text.encode("ascii", errors="ignore")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=ascii")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        parsed = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        self._route(parsed.path, query)

    def do_POST(self):
        parsed = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length > 0:
                raw = self.rfile.read(length).decode("utf-8", "replace")
                body = json.loads(raw)
                if isinstance(body, dict):
                    query.update({k: v for k, v in body.items()})
        except (ValueError, OSError):
            pass
        self._route(parsed.path, query)

    def _route(self, path: str, query: dict):
        island = Handler.island

        if path in ("/tick", "/t"):
            self._send(island.store.snapshot_tick())

        elif path in ("/state", "/", "/s"):
            self._send(island.store.snapshot_state())

        elif path == "/control":
            action = str(query.get("action") or "")
            self._send(island.controls.dispatch(action, query.get("value")))

        elif path == "/config":
            bands = query.get("bands")
            island.equalizer.configure(
                bands=int(bands) if bands not in (None, "") else None,
                music_only=_truthy(query.get("music_only")),
                allow_unknown=_truthy(query.get("allow_unknown")),
            )
            enabled = _truthy(query.get("equalizer"))
            if enabled is not None:
                island.equalizer.enabled = enabled
            self._send({"ok": True})

        elif path == "/art":
            art = island.store.cover_b64()
            self._send_text(art or "", status=200 if art else 404)

        elif path == "/health":
            self._send({
                "ok": True,
                "mode": island.mode,
                "player": island.store.player_backend(),
                "player_app": getattr(island.player, "source_app", None),
                "player_error": island.player_error,
                "audio": island.equalizer.diagnostics(),
            })

        else:
            self._send({"ok": False, "error": "not found"}, status=404)


_BLOCKS = " ▁▂▃▄▅▆▇█"

def _bar(value: float) -> str:
    index = int(min(1.0, max(0.0, value)) * (len(_BLOCKS) - 1))
    return _BLOCKS[index]


def selftest(island: Island, seconds: float = 20.0):
    print("MusicUI // самопроверка")
    print(f"режим        : {config.mode_title(island.mode)}")
    print(f"источник     : {'ok' if island.player else island.player_error}")

    island.start()
    time.sleep(2.0)

    diag = island.equalizer.diagnostics()
    print(f"аудиосессии  : {'ok' if diag['sessions_available'] else diag['sessions_error']}")
    print(f"per-process  : {'да' if diag['process_loopback'] else 'нет'}"
          f"{'' if diag['process_loopback'] else ' — ' + str(diag['process_error'])}")
    print(f"микс (фолбэк): {'да' if diag['device_loopback'] else 'нет — ' + str(diag['device_error'])}")
    print(f"numpy/FFT    : {'да' if diag['fft'] else 'нет'}")

    print("\nаудиосессии сейчас:")
    for session in sorted(diag["snapshot"]["sessions"], key=lambda s: -s["peak"]):
        print(f"  {session['kind']:8} {session['name']:24} pid {session['pid']:<7} пик {session['peak']:.4f}")

    print("\nполосы (Ctrl+C для выхода). Проверь: музыка двигает, разговор - нет.\n")
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        tick = island.store.snapshot_tick()
        state = island.store.snapshot_state()
        bars = "".join(_bar(b) for b in tick["bands"])
        track = state["track"]
        title = f"{track['artist']} — {track['title']}" if track else "нет трека"
        note = state.get("audio_note") or ""
        print(f"\r[{bars}] {tick['band_source']:8} {'play' if tick['playing'] else 'stop'} "
              f"{tick['pos']:6.1f}s  {title[:38]:38} {note[:44]:44}", end="", flush=True)
        time.sleep(1 / 15)
    print()


def main():
    args = sys.argv[1:]
    verbose = "--verbose" in args or "-v" in args
    port = config.PORT
    if "--port" in args:
        port = int(args[args.index("--port") + 1])

    if "--mode" in args:
        mode = startup.parse_mode(args[args.index("--mode") + 1])
    else:
        mode = startup.choose_mode()

    island = Island(mode, verbose=verbose)
    config.write_last_mode(island.mode)
    Handler.island = island

    if "--selftest" in args:
        try:
            selftest(island)
        except KeyboardInterrupt:
            print()
        finally:
            island.stop()
        return

    island.start()
    httpd = ThreadingHTTPServer((config.HOST, port), Handler)
    httpd.daemon_threads = True

    print(f"\nрежим: {config.mode_title(island.mode)}")
    print(f"MusicUI: http://{config.HOST}:{port}")
    print("Ctrl+C для выхода.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nостановка...")
    finally:
        httpd.shutdown()
        island.stop()
