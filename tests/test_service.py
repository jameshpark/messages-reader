from __future__ import annotations

import ast
import json
import os
import shutil
import socket
import stat
import tempfile
import threading
from pathlib import Path

import pytest

from messages_reader import client, service
from messages_reader.store import RequestError

SRC = Path(__file__).resolve().parents[1] / "src" / "messages_reader"


@pytest.mark.parametrize(
    "request_obj, message",
    [
        ([], "JSON object"),
        ({"op": "send", "args": {"to": "x", "text": "hi"}}, "unknown op"),
        ({"op": "send_message"}, "unknown op"),
        ({"op": "delete"}, "unknown op"),
        ({"op": "sql", "args": {"query": "DELETE FROM message"}}, "unknown op"),
        ({"op": "__init__"}, "unknown op"),
        ({"op": "_resolve_chats"}, "unknown op"),
        ({"op": "check", "extra": 1}, "unknown request fields"),
        ({"op": "recent", "args": {"hours": 1, "send": True}}, "unknown args"),
        ({"op": "recent", "args": []}, "args must be"),
        ({"op": "recent", "args": {"limit": "5"}}, "integer"),
        ({"op": "recent", "args": {"limit": True}}, "integer"),
        ({"op": "recent", "args": {"limit": 501}}, "between"),
        ({"op": "recent", "args": {"hours": 0}}, "between"),
        ({"op": "search", "args": {}}, "query is required"),
        ({"op": "search", "args": {"query": "   "}}, "1-200"),
        ({"op": "search", "args": {"query": "x" * 201}}, "1-200"),
        ({"op": "search", "args": {"query": "a\x00b"}}, "control characters"),
        ({"op": "thread", "args": {"target": 5}}, "must be a string"),
    ],
)
def test_validate_rejects(request_obj, message):
    with pytest.raises(RequestError, match=message):
        service.validate(request_obj)


def test_validate_applies_defaults_and_strips():
    assert service.validate({"op": "search", "args": {"query": "  hi  "}}) == (
        "search",
        {"query": "hi", "days": 365, "limit": 50},
    )
    assert service.validate({"op": "attachments"}) == (
        "attachments",
        {"target": None, "days": 30, "limit": 50},
    )


def test_every_op_is_a_store_method_with_matching_args(store):
    for op, spec in service.OPS.items():
        method = getattr(store, op)
        assert set(method.__code__.co_varnames[1 : method.__code__.co_argcount]) == set(spec)


def test_encode_response_drops_oldest_rows_to_fit(monkeypatch):
    monkeypatch.setattr(service, "MAX_RESPONSE_BYTES", 2000)
    rows = [{"id": i, "text": "x" * 100} for i in range(50)]
    newest_first = json.loads(service.encode_response("recent", {"ok": True, "result": {"rows": list(rows)}}))
    assert newest_first["result"]["truncated"] and newest_first["result"]["rows"][0]["id"] == 0
    oldest_first = json.loads(service.encode_response("thread", {"ok": True, "result": {"rows": list(rows)}}))
    assert oldest_first["result"]["rows"][-1]["id"] == 49
    for out in (newest_first, oldest_first):
        assert len(json.dumps(out)) <= 2000


def test_only_stdlib_imports_with_no_process_or_network_modules():
    allowed = {
        "__future__", "argparse", "collections", "contextlib", "dataclasses", "datetime",
        "json", "logging", "os", "pathlib", "pwd", "re", "signal", "socket", "socketserver",
        "sqlite3", "stat", "struct", "sys", "threading", "time",
    }
    for path in SRC.glob("*.py"):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0:
                names = [node.module]
            else:
                continue
            for name in names:
                assert name.split(".")[0] in allowed, f"{path.name} imports {name}"
        assert "AF_INET" not in path.read_text(), path.name


def test_client_never_touches_databases():
    tree = ast.parse((SRC / "client.py").read_text())
    imported = {
        n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module
    } | {a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
    assert "sqlite3" not in imported and "store" not in imported


def _tmpdir() -> Path:
    # Resolved because /tmp is a symlink; sun_path's 104-byte limit rules out tmp_path.
    return Path(tempfile.mkdtemp(prefix="mr-", dir="/tmp")).resolve()


@pytest.fixture
def running(store):
    # sun_path is limited to 104 bytes, so keep the path short.
    root = _tmpdir()
    sock_path = root / "state" / "s.sock"
    server = service.bind(store, sock_path)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield sock_path
    server.shutdown()
    server.server_close()
    shutil.rmtree(root)


def raw_exchange(path: Path, payload: bytes) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(str(path))
        s.sendall(payload)
        s.shutdown(socket.SHUT_WR)
        data = b""
        while chunk := s.recv(65536):
            data += chunk
    return json.loads(data)


def test_socket_and_directory_are_owner_only(running):
    assert stat.S_IMODE(os.lstat(running).st_mode) == 0o600
    assert stat.S_IMODE(os.lstat(running.parent).st_mode) == 0o700
    assert os.lstat(running.parent).st_uid == os.getuid()


def test_end_to_end_ops(running):
    assert client.call("check", {}, str(running))["result"]["full_disk_access"] is True
    thread = client.call("thread", {"target": "Alex Rivera"}, str(running))
    assert thread["ok"] and thread["result"]["rows"][2]["text"] == "decoded body 100% real"
    assert client.call("chats", {"limit": 2}, str(running))["result"]["rows"][0]["chat_id"] == 13


@pytest.mark.parametrize(
    "payload, message",
    [
        (b'{"op": "send", "args": {"to": "+15551230001", "text": "hi"}}\n', "unknown op"),
        (b'{"op": "check"', "one line of JSON"),
        (b"\xff\xfe\n", "one line of JSON"),
        (b"", "one line of JSON"),
        (b'{"op": "search", "args": {"query": "' + b"a" * 5000 + b'"}}\n', "larger than"),
    ],
)
def test_socket_rejects_bad_requests(running, payload, message):
    response = raw_exchange(running, payload)
    assert response["ok"] is False and message in response["error"]


def test_service_errors_reach_the_client(running):
    response = client.call("thread", {"target": "Alex"}, str(running))
    assert response == {
        "ok": False,
        "error": "2 contacts match 'Alex'; run `contact` and pass a phone number or email",
    }


def test_peer_uid_is_the_connecting_user(running):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as a:
        a.connect(str(running))
        assert service.peer_uid(a) == os.getuid()


def test_bind_refuses_a_non_socket_in_the_way(store):
    root = _tmpdir()
    try:
        (root / "s.sock").write_text("not a socket")
        with pytest.raises(SystemExit, match="not a socket"):
            service.bind(store, root / "s.sock")
    finally:
        shutil.rmtree(root)


def test_bind_tightens_a_loose_directory(store):
    root = _tmpdir()
    try:
        os.chmod(root, 0o755)
        server = service.bind(store, root / "s.sock")
        server.server_close()
        assert stat.S_IMODE(os.lstat(root).st_mode) == 0o700
    finally:
        shutil.rmtree(root)


def test_bind_refuses_a_symlinked_directory(store):
    root = _tmpdir()
    try:
        (root / "real").mkdir()
        (root / "link").symlink_to(root / "real")
        with pytest.raises(SystemExit, match="not a plain directory"):
            service.bind(store, root / "link" / "s.sock")
    finally:
        shutil.rmtree(root)


def test_service_main_rejects_arguments():
    assert service.main(["--send"]) == 2


def test_bind_never_changes_permissions_through_a_path(store, monkeypatch):
    def refuse(*args, **kwargs):
        raise AssertionError("path-based chmod follows symlinks")

    monkeypatch.setattr(os, "chmod", refuse)
    monkeypatch.setattr(os, "lchmod", refuse, raising=False)
    root = _tmpdir()
    try:
        server = service.bind(store, root / "state" / "s.sock")
        assert stat.S_IMODE(os.lstat(root / "state" / "s.sock").st_mode) == 0o600
        server.server_close()
    finally:
        shutil.rmtree(root)


def test_bind_refuses_a_symlink_at_the_socket_name(store):
    root = _tmpdir()
    try:
        victim = root / "victim"
        victim.write_text("protected")
        victim.chmod(0o644)
        (root / "s.sock").symlink_to(victim)
        with pytest.raises(SystemExit, match="not a socket"):
            service.bind(store, root / "s.sock")
        assert stat.S_IMODE(victim.stat().st_mode) == 0o644 and victim.read_text() == "protected"
    finally:
        shutil.rmtree(root)


def test_close_only_removes_its_own_socket_even_if_the_directory_is_swapped(store):
    root = _tmpdir()
    try:
        server = service.bind(store, root / "state" / "s.sock")
        (root / "state").rename(root / "moved")
        (root / "other").mkdir()
        (root / "other" / "s.sock").write_text("someone else's file")
        (root / "state").symlink_to(root / "other")
        server.server_close()
        assert (root / "other" / "s.sock").read_text() == "someone else's file"
        assert not (root / "moved" / "s.sock").exists()
    finally:
        shutil.rmtree(root)
