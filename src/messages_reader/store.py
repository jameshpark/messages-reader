"""Read-only queries against chat.db and the AddressBook databases.

Every connection is opened with SQLite URI ``mode=ro``, ``PRAGMA query_only``
and an authorizer that denies anything other than reading, so no statement
issued here can modify a database even by mistake.
"""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Callable, Iterable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import __version__, paths

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
MAX_TEXT_CHARS = 4000
# Tapbacks and sticker reactions carry associated_message_type 2000-3999.
_REACTION_TYPES = range(2000, 4000)
_PHONE_RE = re.compile(r"\+?[\d\s().-]{7,}")
_CHAT_TARGET_RE = re.compile(r"chat:(\d{1,18})")

_ALLOWED_SQL_ACTIONS = frozenset(
    {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION}
)


class RequestError(Exception):
    """A request that is well-formed but can't be answered (shown to the caller)."""


def _authorize(action: int, *_: object) -> int:
    return sqlite3.SQLITE_OK if action in _ALLOWED_SQL_ACTIONS else sqlite3.SQLITE_DENY


def open_readonly(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True, timeout=5)
    try:
        conn.execute("PRAGMA query_only = ON")
        conn.set_authorizer(_authorize)
    except BaseException:
        conn.close()
        raise
    conn.row_factory = sqlite3.Row
    return conn


def decode_attributed_body(blob: bytes | None) -> str | None:
    """Pull the message text out of an ``attributedBody`` typedstream blob.

    New macOS versions often leave ``message.text`` NULL and store the text
    only here. The blob is an NSArchiver typedstream of an
    NSAttributedString: the first ``NSString`` class name is followed by a
    5-byte header and a length-prefixed UTF-8 string. Lengths below 0x80 are
    one byte; 0x81/0x82/0x83 introduce a 2/3/4-byte little-endian length.

    Adapted from mac_messages_mcp (MIT, Copyright (c) 2023 Carter Lasalle).
    """
    if not blob:
        return None
    idx = blob.find(b"NSString")
    if idx < 0:
        return None
    pos = idx + len(b"NSString") + 5
    if pos >= len(blob):
        return None
    lead = blob[pos]
    pos += 1
    if lead < 0x80:
        length = lead
    elif lead in (0x81, 0x82, 0x83):
        width = lead - 0x7F
        if pos + width > len(blob):
            return None
        length = int.from_bytes(blob[pos : pos + width], "little")
        pos += width
    else:
        return None
    if pos + length > len(blob):
        return None
    return blob[pos : pos + length].decode("utf-8", errors="replace")


def apple_time_to_iso(value: int | None) -> str | None:
    if not value:
        return None
    # Since macOS 10.13 dates are nanoseconds since 2001; older rows used seconds.
    seconds = value / 1e9 if abs(value) > 1e11 else value
    return (APPLE_EPOCH + timedelta(seconds=seconds)).astimezone().isoformat(timespec="seconds")


def apple_ns_since(delta: timedelta) -> int:
    return int((datetime.now(timezone.utc) - delta - APPLE_EPOCH).total_seconds() * 1e9)


def handle_key(handle: str) -> str:
    """Normalize a phone number or email so differently formatted handles compare equal."""
    handle = handle.strip()
    if "@" in handle:
        return handle.casefold()
    digits = re.sub(r"\D", "", handle)
    return digits[-10:] if len(digits) >= 10 else digits


def _clean_text(text: str | None) -> str:
    if not text:
        return ""
    # U+FFFC marks where an attachment sits inline; U+FFFD-only bodies are undecodable.
    text = text.replace("￼", "").strip()
    if text and set(text) == {"�"}:
        return ""
    return text


def _cap(text: str) -> tuple[str, bool]:
    if len(text) <= MAX_TEXT_CHARS:
        return text, False
    return text[:MAX_TEXT_CHARS], True


@dataclass
class Contact:
    name: str
    phones: list[str] = field(default_factory=list)
    emails: list[str] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)

    def keys(self) -> set[str]:
        return {handle_key(h) for h in self.phones + self.emails if handle_key(h)}

    def as_dict(self) -> dict:
        return {"name": self.name, "phones": self.phones, "emails": self.emails}


class Store:
    def __init__(
        self,
        chat_db: Callable[[], Path] = paths.chat_db_path,
        addressbook_dbs: Callable[[], list[Path]] = paths.addressbook_db_paths,
    ) -> None:
        self._chat_db = chat_db
        self._addressbook_dbs = addressbook_dbs

    @contextmanager
    def _chat(self) -> Iterator[sqlite3.Connection]:
        path = self._chat_db()
        try:
            conn = open_readonly(path)
        except sqlite3.OperationalError as e:
            raise RequestError(
                f"cannot open {path}: {e}. The service binary needs Full Disk Access."
            ) from e
        try:
            yield conn
        finally:
            conn.close()

    # ----- contacts -------------------------------------------------------

    def contacts(self) -> list[Contact]:
        seen: set[tuple] = set()
        result: list[Contact] = []
        for db in self._addressbook_dbs():
            try:
                conn = open_readonly(db)
            except sqlite3.Error:
                continue
            try:
                for contact in _read_addressbook(conn):
                    ident = (contact.name, tuple(sorted(contact.keys())))
                    if ident not in seen:
                        seen.add(ident)
                        result.append(contact)
            except sqlite3.Error:
                continue
            finally:
                conn.close()
        return result

    def _names_by_key(self) -> dict[str, str]:
        names: dict[str, str] = {}
        for contact in self.contacts():
            for key in contact.keys():
                names.setdefault(key, contact.name)
        return names

    def contact(self, query: str, limit: int) -> dict:
        q = query.strip()
        q_key = handle_key(q) if ("@" in q or _PHONE_RE.fullmatch(q)) else None
        needle = q.casefold()
        matches = []
        for contact in self.contacts():
            if q_key:
                hit = q_key in contact.keys()
            else:
                hit = any(needle in alias.casefold() for alias in contact.aliases)
            if hit:
                matches.append(contact.as_dict())
        matches.sort(key=lambda c: c["name"].casefold())
        return {"rows": matches[:limit], "total": len(matches)}

    # ----- messages -------------------------------------------------------

    def check(self) -> dict:
        db = self._chat_db()
        report: dict = {
            "service_version": __version__,
            "chat_db": str(db),
            "chat_db_exists": db.exists(),
        }
        try:
            with self._chat() as conn:
                last = conn.execute("SELECT MAX(date) FROM message").fetchone()[0]
            report["full_disk_access"] = True
            report["last_message_at"] = apple_time_to_iso(last)
        except RequestError as e:
            report["full_disk_access"] = False
            report["error"] = str(e)
        dbs = self._addressbook_dbs()
        readable = 0
        for path in dbs:
            try:
                open_readonly(path).close()
                readable += 1
            except sqlite3.Error:
                pass
        report["addressbook_dbs_found"] = len(dbs)
        report["addressbook_dbs_readable"] = readable
        return report

    def recent(self, hours: int, limit: int) -> dict:
        since = apple_ns_since(timedelta(hours=hours))
        with self._chat() as conn:
            rows = conn.execute(
                f"{_MESSAGE_SELECT} WHERE m.date >= ? ORDER BY m.date DESC LIMIT ?",
                (since, limit),
            ).fetchall()
            return {"rows": self._render(conn, rows)}

    def search(self, query: str, days: int, limit: int) -> dict:
        since = apple_ns_since(timedelta(days=days))
        needle = query.casefold()
        like = "%" + re.sub(r"([\\%_])", r"\\\1", query) + "%"
        matched = []
        with self._chat() as conn:
            # text LIKE prefilters plain-text rows; attributedBody-only rows
            # have to be decoded before they can be matched.
            cursor = conn.execute(
                f"""{_MESSAGE_SELECT}
                WHERE m.date >= ?
                  AND (m.text LIKE ? ESCAPE '\\'
                       OR (COALESCE(m.text, '') = '' AND m.attributedBody IS NOT NULL))
                ORDER BY m.date DESC""",
                (since, like),
            )
            for row in cursor:
                body = _clean_text(row["text"] or decode_attributed_body(row["attributedBody"]))
                if needle in body.casefold():
                    matched.append(row)
                    if len(matched) >= limit:
                        break
            return {"rows": self._render(conn, matched)}

    def thread(self, target: str, limit: int) -> dict:
        with self._chat() as conn:
            chat_ids = self._resolve_chats(conn, target)
            marks = ",".join("?" * len(chat_ids))
            rows = conn.execute(
                f"""{_MESSAGE_SELECT}
                WHERE m.ROWID IN (SELECT message_id FROM chat_message_join WHERE chat_id IN ({marks}))
                ORDER BY m.date DESC LIMIT ?""",
                (*chat_ids, limit),
            ).fetchall()
            rendered = self._render(conn, rows)
        rendered.reverse()
        return {"chat_ids": chat_ids, "rows": rendered}

    def chats(self, limit: int) -> dict:
        names = self._names_by_key()
        with self._chat() as conn:
            rows = conn.execute(
                """SELECT c.ROWID AS chat_id, c.display_name, c.chat_identifier,
                          MAX(cmj.message_date) AS last_date
                   FROM chat c JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                   GROUP BY c.ROWID ORDER BY last_date DESC LIMIT ?""",
                (limit,),
            ).fetchall()
            members = _chat_members(conn, [r["chat_id"] for r in rows])
        result = []
        for r in rows:
            handles = members.get(r["chat_id"], [])
            result.append(
                {
                    "chat_id": r["chat_id"],
                    "name": r["display_name"] or None,
                    "identifier": r["chat_identifier"],
                    "is_group": len(handles) > 1,
                    "participants": [
                        {"handle": h, "name": names.get(handle_key(h))} for h in handles
                    ],
                    "last_message_at": apple_time_to_iso(r["last_date"]),
                }
            )
        return {"rows": result}

    def attachments(self, target: str | None, days: int, limit: int) -> dict:
        since = apple_ns_since(timedelta(days=days))
        names = self._names_by_key()
        with self._chat() as conn:
            where, params = "m.date >= ?", [since]
            if target:
                chat_ids = self._resolve_chats(conn, target)
                where += (
                    " AND m.ROWID IN (SELECT message_id FROM chat_message_join"
                    f" WHERE chat_id IN ({','.join('?' * len(chat_ids))}))"
                )
                params += chat_ids
            rows = conn.execute(
                f"""SELECT a.transfer_name, a.mime_type, a.total_bytes, m.date,
                           m.is_from_me, h.id AS handle,
                           (SELECT chat_id FROM chat_message_join WHERE message_id = m.ROWID LIMIT 1) AS chat_id
                    FROM attachment a
                    JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                    JOIN message m ON m.ROWID = maj.message_id
                    LEFT JOIN handle h ON h.ROWID = m.handle_id
                    WHERE {where} ORDER BY m.date DESC LIMIT ?""",
                (*params, limit),
            ).fetchall()
        return {
            "rows": [
                {
                    "date": apple_time_to_iso(r["date"]),
                    "chat_id": r["chat_id"],
                    **_sender(r["is_from_me"], r["handle"], names),
                    "name": r["transfer_name"],
                    "mime_type": r["mime_type"],
                    "bytes": r["total_bytes"],
                }
                for r in rows
            ]
        }

    # ----- helpers --------------------------------------------------------

    def _resolve_chats(self, conn: sqlite3.Connection, target: str) -> list[int]:
        target = target.strip()
        m = _CHAT_TARGET_RE.fullmatch(target)
        if m:
            chat_id = int(m.group(1))
            if not conn.execute("SELECT 1 FROM chat WHERE ROWID = ?", (chat_id,)).fetchone():
                raise RequestError(f"no chat with id {chat_id}")
            return [chat_id]
        if "@" in target or _PHONE_RE.fullmatch(target):
            keys = {handle_key(target)}
        else:
            needle = target.casefold()
            found = [
                c for c in self.contacts() if any(needle in a.casefold() for a in c.aliases)
            ]
            exact = [c for c in found if c.name.casefold() == needle]
            found = exact or found
            if not found:
                raise RequestError(f"no contact matches {target!r}")
            if len(found) > 1:
                raise RequestError(
                    f"{len(found)} contacts match {target!r}; run `contact` and pass a phone number or email"
                )
            keys = found[0].keys()
        keys.discard("")
        if not keys:
            raise RequestError(f"{target!r} is not a usable phone number or email")
        handle_ids = [
            r["ROWID"]
            for r in conn.execute("SELECT ROWID, id FROM handle")
            if handle_key(r["id"]) in keys
        ]
        if not handle_ids:
            raise RequestError(f"no Messages handle matches {target!r}")
        marks = ",".join("?" * len(handle_ids))
        # One-to-one chats only: a chat whose sole participant is this person.
        chat_ids = [
            r[0]
            for r in conn.execute(
                f"""SELECT chat_id FROM chat_handle_join GROUP BY chat_id
                    HAVING COUNT(*) = 1 AND MAX(handle_id) IN ({marks})""",
                handle_ids,
            )
        ]
        if not chat_ids:
            raise RequestError(f"no one-to-one chat with {target!r}")
        return chat_ids

    def _render(self, conn: sqlite3.Connection, rows: list[sqlite3.Row]) -> list[dict]:
        names = self._names_by_key()
        files = _attachment_names(conn, [r["id"] for r in rows if r["cache_has_attachments"]])
        out = []
        for r in rows:
            text, truncated = _cap(
                _clean_text(r["text"] or decode_attributed_body(r["attributedBody"]))
            )
            if r["item_type"]:
                kind = "event"
            elif (r["associated_message_type"] or 0) in _REACTION_TYPES:
                kind = "reaction"
            else:
                kind = "message"
            row = {
                "id": r["id"],
                "date": apple_time_to_iso(r["date"]),
                "chat_id": r["chat_id"],
                **_sender(r["is_from_me"], r["handle"], names),
                "kind": kind,
                "text": text,
                "attachments": files.get(r["id"], []),
            }
            if truncated:
                row["truncated"] = True
            out.append(row)
        return out


_MESSAGE_SELECT = """
SELECT m.ROWID AS id, m.date, m.is_from_me, m.text, m.attributedBody,
       m.associated_message_type, m.item_type, m.cache_has_attachments,
       h.id AS handle,
       (SELECT chat_id FROM chat_message_join WHERE message_id = m.ROWID LIMIT 1) AS chat_id
FROM message m
LEFT JOIN handle h ON h.ROWID = m.handle_id
"""


def _sender(is_from_me: int, handle: str | None, names: dict[str, str]) -> dict:
    if is_from_me:
        return {"from_me": True, "sender": "me", "sender_name": None}
    return {
        "from_me": False,
        "sender": handle,
        "sender_name": names.get(handle_key(handle)) if handle else None,
    }


def _chat_members(conn: sqlite3.Connection, chat_ids: list[int]) -> dict[int, list[str]]:
    members: dict[int, list[str]] = {}
    for chunk in _chunks(chat_ids):
        for r in conn.execute(
            f"""SELECT chj.chat_id, h.id FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id IN ({','.join('?' * len(chunk))})""",
            chunk,
        ):
            members.setdefault(r[0], []).append(r[1])
    return members


def _attachment_names(conn: sqlite3.Connection, message_ids: list[int]) -> dict[int, list[str]]:
    found: dict[int, list[str]] = {}
    for chunk in _chunks(message_ids):
        for r in conn.execute(
            f"""SELECT maj.message_id, a.transfer_name, a.mime_type
                FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id IN ({','.join('?' * len(chunk))})""",
            chunk,
        ):
            found.setdefault(r[0], []).append(r[1] or r[2] or "attachment")
    return found


def _chunks(items: list[int], size: int = 500) -> Iterable[list[int]]:
    for i in range(0, len(items), size):
        yield items[i : i + size]


def _read_addressbook(conn: sqlite3.Connection) -> list[Contact]:
    people: dict[int, Contact] = {}
    for r in conn.execute(
        "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, ZNICKNAME FROM ZABCDRECORD"
    ):
        full = " ".join(p for p in (r["ZFIRSTNAME"], r["ZLASTNAME"]) if p)
        aliases = [a for a in (full, r["ZORGANIZATION"], r["ZNICKNAME"]) if a]
        if aliases:
            people[r["Z_PK"]] = Contact(name=aliases[0], aliases=aliases)
    for r in conn.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER"):
        if r["ZOWNER"] in people and r["ZFULLNUMBER"]:
            people[r["ZOWNER"]].phones.append(r["ZFULLNUMBER"])
    for r in conn.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"):
        if r["ZOWNER"] in people and r["ZADDRESS"]:
            people[r["ZOWNER"]].emails.append(r["ZADDRESS"])
    return [c for c in people.values() if c.phones or c.emails]
