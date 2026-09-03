from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from musicui import autostart
from musicui import config
from musicui import console
from musicui import procwatch
from musicui import startup
from musicui.audio.equalizer import Equalizer
from musicui.core.controls import Controls
from musicui.core.poller import Poller
from musicui.core.state import StateStore

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def _already_running(port: int) -> bool:
    with socket.socket() as probe:
        probe.settimeout(0.35)
        return probe.connect_ex((config.HOST, port)) == 0


def _log(message: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {message}")


def _spawn(command: list[str]):
    try:
        return subprocess.Popen(command)
    except OSError as exc:
        print(f"не удалось запустить игру: {exc}")
        return None


def _wait_for(process) -> None:
    if process is None:
        return
    try:
        process.wait()
    except KeyboardInterrupt:
        pass


def _wait_game_gone() -> None:
    if not procwatch.available():
        return
    gone_at = None
    while not _quit.is_set():
        if procwatch.running(config.GAME_APPS):
            gone_at = None
        else:
            gone_at = gone_at or time.monotonic()
            if time.monotonic() - gone_at >= config.WATCH_GRACE:
                return
        _quit.wait(config.WATCH_POLL)


def stop_running(port: int) -> None:
    request = urllib.request.Request(f"http://{config.HOST}:{port}/quit", data=b"", method="POST")
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            response.read()
        print("сервер остановлен")
    except OSError:
        print("сервер не отвечает - похоже, он и не запущен")


def _truthy(value: str | None) -> bool | None:
    if value is None:
        return None
    return value.lower() in ("1", "true", "yes", "on")


_quit = threading.Event()


def _force_exit(delay: float = 3.0) -> None:
    def burn():
        time.sleep(delay)
        try:
            sys.stdout.flush()
        except Exception:
            pass
        os._exit(0)

    threading.Thread(target=burn, name="di-exit", daemon=True).start()


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
    idle: StateStore = None
    mode: str = None
    httpd: ThreadingHTTPServer = None
    server_version = "MusicUI/1.0"

    def log_message(self, *_args):
        pass

    def _reply(self, body: bytes, content_type: str, status: int):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send(self, payload: dict, status: int = 200):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._reply(body, "application/json; charset=utf-8", status)

    def _send_text(self, text: str, status: int = 200):
        self._reply(text.encode("ascii", errors="ignore"), "text/plain; charset=ascii", status)

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
                    query.update(body)
        except (ValueError, OSError):
            pass
        self._route(parsed.path, query)

    @classmethod
    def _idle_store(cls) -> StateStore:
        if cls.idle is None:
            store = StateStore()
            store.set_mode(cls.mode or config.MODES[0][0])
            store.set_player_backend("ожидание", None)
            cls.idle = store
        return cls.idle

    def _route(self, path: str, query: dict):
        island = Handler.island
        store = island.store if island is not None else Handler._idle_store()

        if path in ("/tick", "/t"):
            self._send(store.snapshot_tick())

        elif path in ("/state", "/", "/s"):
            self._send(store.snapshot_state())

        elif path == "/control":
            if island is None:
                self._send({"ok": False, "error": "idle"})
                return
            action = str(query.get("action") or "")
            self._send(island.controls.dispatch(action, query.get("value")))

        elif path == "/config":
            if island is None:
                self._send({"ok": False, "error": "idle"})
                return
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
            art = store.cover_b64()
            self._send_text(art or "", status=200 if art else 404)

        elif path == "/quit":
            if self.command != "POST":
                self._send({"ok": False, "error": "post only"}, status=405)
                return
            self._send({"ok": True})
            _quit.set()
            if Handler.httpd is not None:
                threading.Thread(target=Handler.httpd.shutdown, daemon=True).start()

        elif path == "/health":
            if island is None:
                self._send({"ok": True, "idle": True, "mode": Handler.mode})
                return
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


def launch_with_game(port: int, launch: list[str], verbose: bool) -> None:
    _log(f"запуск из Steam: {subprocess.list2cmdline(launch)}")
    game = _spawn(launch)
    if game is None:
        _log("игра не запустилась - проверь строку в параметрах запуска Dota 2")
        return
    _log(f"игра пошла, pid {game.pid}")
    config.write_autostart_choice(autostart.DONE)

    island = None
    httpd = None

    if _already_running(port):
        _log(f"MusicUI уже слушает {port} - просто жду игру")
    else:
        try:
            mode = config.read_last_mode() or config.FALLBACK_MODE
            island = Island(mode, verbose=verbose)
            config.write_last_mode(island.mode)
            Handler.island = island
            Handler.mode = island.mode
            island.start()
            httpd = ThreadingHTTPServer((config.HOST, port), Handler)
            httpd.daemon_threads = True
            Handler.httpd = httpd
            threading.Thread(target=httpd.serve_forever, name="di-http", daemon=True).start()
            _log(f"островок поднят, режим {config.mode_title(island.mode)}, порт {port}")
        except Exception as exc:
            Handler.island = None
            _log(f"островок не поднялся: {exc!r} - игра работает дальше")

    _wait_for(game)
    _log("игра закрылась")
    _wait_game_gone()
    _force_exit()
    Handler.island = None
    if httpd is not None:
        httpd.shutdown()
        try:
            httpd.server_close()
        except OSError:
            pass
    if island is not None:
        island.stop()
    _log("выключился вместе с игрой")


def main():
    args = sys.argv[1:]

    launch: list[str] = []
    if "--launch" in args:
        index = args.index("--launch")
        launch, args = args[index + 1:], args[:index]

    if not launch and "--auto" not in args:
        console.attach()
    console.ensure_stdio()

    verbose = "--verbose" in args or "-v" in args
    port = config.PORT
    if "--port" in args:
        port = int(args[args.index("--port") + 1])

    if "--autostart" in args:
        index = args.index("--autostart") + 1
        autostart.handle(args[index] if index < len(args) else None)
        return

    if "--stop" in args:
        stop_running(port)
        return

    if launch:
        launch_with_game(port, launch, verbose)
        return

    if _already_running(port):
        print(f"MusicUI уже работает на http://{config.HOST}:{port} - второй экземпляр не нужен")
        print(f"остановить его: {autostart.launcher()} --stop")
        return

    if "--mode" in args:
        mode = startup.parse_mode(args[args.index("--mode") + 1])
    elif "--auto" in args:
        mode = config.read_last_mode() or config.MODES[0][0]
        print(f"режим: {config.mode_title(mode)} (как в прошлый раз)")
    else:
        mode = startup.choose_mode()
        autostart.ask()

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
    Handler.httpd = httpd

    print(f"\nрежим: {config.mode_title(island.mode)}")
    print(f"MusicUI: http://{config.HOST}:{port}")

    print(f"выключить из другого окна: {autostart.launcher()} --stop")
    print("Ctrl+C для выхода.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nостановка...")
    finally:
        _force_exit()
        httpd.shutdown()
        try:
            httpd.server_close()
        except OSError:
            pass
        island.stop()
