"""`messages-read`: command-line client for the messages-reader service.

Talks only to the service's Unix socket; it never opens a database itself.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys

from . import paths

TIMEOUT_SECONDS = 60
EXIT_SERVICE_ERROR = 1
EXIT_UNREACHABLE = 3


def call(op: str, args: dict, socket_path: str | None = None) -> dict:
    request = json.dumps({"op": op, "args": args}).encode() + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(socket_path or str(paths.socket_path()))
        sock.sendall(request)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    return json.loads(b"".join(chunks))


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="messages-read", description="Read-only access to Messages history."
    )
    p.add_argument("--json", action="store_true", help="print the raw JSON result")
    sub = p.add_subparsers(dest="op", required=True)

    sub.add_parser("check", help="report whether the service can read Messages")

    s = sub.add_parser("recent", help="recent messages across all chats")
    s.add_argument("--hours", type=int)
    s.add_argument("--limit", type=int)

    s = sub.add_parser("search", help="messages containing text")
    s.add_argument("query")
    s.add_argument("--days", type=int)
    s.add_argument("--limit", type=int)

    s = sub.add_parser(
        "thread", help="a one-to-one thread (phone, email or contact name) or chat:<id>"
    )
    s.add_argument("target")
    s.add_argument("--limit", type=int)

    s = sub.add_parser("contact", help="look up contacts by name, phone or email")
    s.add_argument("query")
    s.add_argument("--limit", type=int)

    s = sub.add_parser("chats", help="most recently active chats")
    s.add_argument("--limit", type=int)

    s = sub.add_parser("attachments", help="list attachments (metadata only)")
    s.add_argument("target", nargs="?")
    s.add_argument("--days", type=int)
    s.add_argument("--limit", type=int)
    return p


def _who(row: dict) -> str:
    if row.get("from_me"):
        return "me"
    name, handle = row.get("sender_name"), row.get("sender") or "?"
    return f"{name} <{handle}>" if name else handle


def _print_messages(rows: list[dict]) -> None:
    for row in rows:
        text = row["text"]
        if row["attachments"]:
            text = (text + " " if text else "") + " ".join(
                f"[attachment: {a}]" for a in row["attachments"]
            )
        if row.get("truncated"):
            text += " [truncated]"
        prefix = f"{(row['date'] or '')[:16].replace('T', ' ')}  chat:{row['chat_id']}  {_who(row)}"
        if row["kind"] != "message":
            prefix += f" ({row['kind']})"
        print(f"{prefix}: " + text.replace("\n", "\n    "))


def _print(op: str, result: dict) -> None:
    if op == "check":
        for key, value in result.items():
            print(f"{key}: {value}")
        return
    rows = result.get("rows", [])
    if op in ("recent", "search", "thread"):
        _print_messages(rows)
    elif op == "contact":
        for c in rows:
            print(f"{c['name']}: " + ", ".join(c["phones"] + c["emails"]))
        if result.get("total", 0) > len(rows):
            print(f"... {result['total'] - len(rows)} more")
    elif op == "chats":
        for c in rows:
            people = ", ".join(
                f"{p['name']} <{p['handle']}>" if p["name"] else p["handle"]
                for p in c["participants"]
            )
            label = c["name"] or people or c["identifier"]
            when = (c["last_message_at"] or "")[:16].replace("T", " ")
            print(f"chat:{c['chat_id']}  {when}  {label}" + (f"  [{people}]" if c["name"] else ""))
    elif op == "attachments":
        for a in rows:
            when = (a["date"] or "")[:16].replace("T", " ")
            print(f"{when}  chat:{a['chat_id']}  {_who(a)}  {a['name']}  {a['mime_type']}  {a['bytes']} bytes")
    if result.get("truncated"):
        print("[output truncated to the size cap]")


def main(argv: list[str] | None = None) -> int:
    ns = _parser().parse_args(argv)
    args = {
        k: v for k, v in vars(ns).items() if k not in ("op", "json") and v is not None
    }
    try:
        response = call(ns.op, args)
    except (FileNotFoundError, ConnectionRefusedError) as e:
        print(
            f"messages-read: service not reachable at {paths.socket_path()} ({e.strerror})",
            file=sys.stderr,
        )
        return EXIT_UNREACHABLE
    except (OSError, ValueError) as e:
        print(f"messages-read: {e}", file=sys.stderr)
        return EXIT_UNREACHABLE
    if not response.get("ok"):
        print(f"messages-read: {response.get('error')}", file=sys.stderr)
        return EXIT_SERVICE_ERROR
    if ns.json:
        json.dump(response["result"], sys.stdout, ensure_ascii=False, indent=1)
        print()
    else:
        _print(ns.op, response["result"])
    return 0
