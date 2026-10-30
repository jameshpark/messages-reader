"""Unix-socket service answering a fixed set of read-only requests.

Protocol: the client sends one JSON object on one line,
``{"op": "<name>", "args": {...}}``, and gets one JSON line back,
``{"ok": true, "result": {...}}`` or ``{"ok": false, "error": "..."}``.
Only the ops in ``OPS`` exist; there is no way to send, write or delete.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import socket
import socketserver
import stat
import struct
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from . import paths
from .store import RequestError, Store

MAX_REQUEST_BYTES = 4096
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_CONCURRENT_REQUESTS = 4
CONNECTION_TIMEOUT_SECONDS = 30

# <sys/un.h>: getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED) fills a struct xucred,
# which starts with u_int cr_version, uid_t cr_uid.
_SOL_LOCAL = 0
_LOCAL_PEERCRED = 0x001
_XUCRED_SIZE = 76

log = logging.getLogger("messages-reader")


@dataclass(frozen=True)
class Int:
    default: int
    lo: int
    hi: int


@dataclass(frozen=True)
class Str:
    max_len: int
    required: bool = True


OPS: dict[str, dict[str, Int | Str]] = {
    "check": {},
    "recent": {"hours": Int(24, 1, 24 * 365), "limit": Int(50, 1, 500)},
    "search": {"query": Str(200), "days": Int(365, 1, 3650), "limit": Int(50, 1, 200)},
    "thread": {"target": Str(320), "limit": Int(50, 1, 500)},
    "contact": {"query": Str(200), "limit": Int(10, 1, 50)},
    "chats": {"limit": Int(30, 1, 200)},
    "attachments": {
        "target": Str(320, required=False),
        "days": Int(30, 1, 3650),
        "limit": Int(50, 1, 200),
    },
}

# thread rows are oldest-first; everything else is newest-first.
_OLDEST_FIRST = {"thread"}


def validate(request: object) -> tuple[str, dict]:
    if not isinstance(request, dict):
        raise RequestError("request must be a JSON object")
    extra = set(request) - {"op", "args"}
    if extra:
        raise RequestError(f"unknown request fields: {sorted(extra)}")
    op = request.get("op")
    if not isinstance(op, str) or op not in OPS:
        raise RequestError(f"unknown op; allowed: {sorted(OPS)}")
    args = request.get("args", {})
    if not isinstance(args, dict):
        raise RequestError("args must be a JSON object")
    spec = OPS[op]
    unknown = set(args) - set(spec)
    if unknown:
        raise RequestError(f"unknown args for {op}: {sorted(unknown)}")
    clean: dict = {}
    for name, rule in spec.items():
        value = args.get(name)
        if isinstance(rule, Int):
            if value is None:
                value = rule.default
            if isinstance(value, bool) or not isinstance(value, int):
                raise RequestError(f"{name} must be an integer")
            if not rule.lo <= value <= rule.hi:
                raise RequestError(f"{name} must be between {rule.lo} and {rule.hi}")
        else:
            if value is None:
                if rule.required:
                    raise RequestError(f"{name} is required")
            elif not isinstance(value, str):
                raise RequestError(f"{name} must be a string")
            else:
                value = value.strip()
                if not value or len(value) > rule.max_len:
                    raise RequestError(f"{name} must be 1-{rule.max_len} characters")
                if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
                    raise RequestError(f"{name} must not contain control characters")
        clean[name] = value
    return op, clean


def handle_request(store: Store, raw: bytes) -> tuple[str | None, dict]:
    op = None
    try:
        try:
            request = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise RequestError("request must be one line of JSON") from None
        op, args = validate(request)
        return op, {"ok": True, "result": getattr(store, op)(**args)}
    except RequestError as e:
        return op, {"ok": False, "error": str(e)}


def encode_response(op: str | None, response: dict) -> bytes:
    """Serialize, dropping the oldest rows until the response fits the size cap."""
    rows = response.get("result", {}).get("rows")
    while True:
        data = json.dumps(response, ensure_ascii=False).encode() + b"\n"
        if len(data) <= MAX_RESPONSE_BYTES:
            return data
        if not rows:
            return json.dumps({"ok": False, "error": "response too large"}).encode() + b"\n"
        drop = max(1, len(rows) // 4)
        if op in _OLDEST_FIRST:
            del rows[:drop]
        else:
            del rows[-drop:]
        response["result"]["truncated"] = True


def peer_uid(sock: socket.socket) -> int | None:
    try:
        raw = sock.getsockopt(_SOL_LOCAL, _LOCAL_PEERCRED, _XUCRED_SIZE)
        _version, uid = struct.unpack_from("=II", raw)
        return uid
    except (OSError, struct.error):
        return None


def _read_line(sock: socket.socket) -> bytes:
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(MAX_REQUEST_BYTES + 1 - len(buf))
        if not chunk:
            break
        buf += chunk
        if len(buf) > MAX_REQUEST_BYTES:
            raise RequestError(f"request larger than {MAX_REQUEST_BYTES} bytes")
    line, _, _ = buf.partition(b"\n")
    return line


class _Handler(socketserver.BaseRequestHandler):
    server: _Server

    def handle(self) -> None:
        sock: socket.socket = self.request
        sock.settimeout(CONNECTION_TIMEOUT_SECONDS)
        started = time.monotonic()
        op = None
        if peer_uid(sock) != os.getuid():
            response = {"ok": False, "error": "permission denied"}
        elif not self.server.slots.acquire(blocking=False):
            response = {"ok": False, "error": "busy, retry shortly"}
        else:
            try:
                op, response = handle_request(self.server.store, _read_line(sock))
            except RequestError as e:
                response = {"ok": False, "error": str(e)}
            except OSError:
                log.info("op=%s status=io-error", op)
                return
            except Exception:
                log.exception("op=%s status=internal-error", op)
                response = {"ok": False, "error": "internal error"}
            finally:
                self.server.slots.release()
        # Log only the op and outcome: never request args or message contents.
        log.info(
            "op=%s ok=%s ms=%d", op, response["ok"], (time.monotonic() - started) * 1000
        )
        try:
            sock.sendall(encode_response(op, response))
        except OSError:
            pass


class _Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, path: Path, store: Store) -> None:
        self.store = store
        self.slots = threading.BoundedSemaphore(MAX_CONCURRENT_REQUESTS)
        super().__init__(str(path), _Handler)


def _prepare_socket_dir(directory: Path) -> None:
    directory.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    st = os.lstat(directory)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise SystemExit(f"{directory} must be a directory owned by uid {os.getuid()}")
    os.chmod(directory, 0o700)


def bind(store: Store, path: Path) -> _Server:
    _prepare_socket_dir(path.parent)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISSOCK(st.st_mode):
            raise SystemExit(f"{path} exists and is not a socket")
        path.unlink()
    old_umask = os.umask(0o177)
    try:
        server = _Server(path, store)
    finally:
        os.umask(old_umask)
    os.chmod(path, 0o600)
    return server


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv:
        print("messages-reader-service takes no arguments", file=sys.stderr)
        return 2
    logging.basicConfig(
        stream=sys.stderr, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    path = paths.socket_path()
    server = bind(Store(), path)
    inode = os.lstat(path).st_ino
    # launchd stops the job with SIGTERM; exit through serve_forever's finally.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log.info("listening on %s", path)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            if os.lstat(path).st_ino == inode:
                path.unlink()
        except FileNotFoundError:
            pass
    return 0
