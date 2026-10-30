"""Synthetic chat.db and AddressBook fixtures with the columns the store reads."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from messages_reader.store import APPLE_EPOCH, Store

CHAT_SCHEMA = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT,
                   display_name TEXT, style INTEGER);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
                      handle_id INTEGER, date INTEGER, is_from_me INTEGER,
                      associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
                      cache_has_attachments INTEGER DEFAULT 0);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT,
                         transfer_name TEXT, total_bytes INTEGER);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
"""

AB_SCHEMA = """
CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT,
                          ZORGANIZATION TEXT, ZNICKNAME TEXT);
CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT);
"""


def typedstream(text: str) -> bytes:
    """An attributedBody blob shaped like the ones Messages writes."""
    data = text.encode()
    n = len(data)
    if n < 0x80:
        length = bytes([n])
    elif n < 0x10000:
        length = b"\x81" + n.to_bytes(2, "little")
    else:
        length = b"\x82" + n.to_bytes(3, "little")
    return (
        b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00"
        b"\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+"
        + length
        + data
        + b"\x86\x84\x02iI\x01\x05\x92\x84\x84\x84\x0cNSDictionary\x00\x94\x84\x01i\x01\x86\x86"
    )


def apple_ns(dt: datetime) -> int:
    return int((dt - APPLE_EPOCH).total_seconds() * 1e9)


NOW = datetime.now(timezone.utc)


def build_chat_db(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")  # as Messages uses
    conn.executescript(CHAT_SCHEMA)
    conn.executemany(
        "INSERT INTO handle VALUES (?, ?, ?)",
        [
            (1, "alex@example.com", "iMessage"),
            (2, "+15551230001", "SMS"),
            (3, "+15551230002", "iMessage"),
            (4, "+15551230099", "iMessage"),
        ],
    )
    conn.executemany(
        "INSERT INTO chat VALUES (?, ?, ?, ?, ?)",
        [
            (10, "iMessage;-;alex@example.com", "alex@example.com", "", 45),
            (11, "SMS;-;+15551230001", "+15551230001", "", 45),
            (12, "iMessage;+;chat123", "chat123", "Trip planning", 43),
            (13, "iMessage;-;+15551230099", "+15551230099", "", 45),
        ],
    )
    conn.executemany(
        "INSERT INTO chat_handle_join VALUES (?, ?)",
        [(10, 1), (11, 2), (12, 1), (12, 3), (13, 4)],
    )
    # (rowid, text, attributedBody, handle, minutes ago, from_me, chat, extra)
    messages = [
        (1, "hello from text column", None, 1, 300, 0, 10, {}),
        (2, None, typedstream("decoded body 100% real"), 1, 200, 0, 10, {}),
        (3, None, typedstream("my reply"), 1, 100, 1, 10, {}),
        (4, None, typedstream("sms over attributedBody"), 2, 50, 0, 11, {}),
        (5, None, typedstream("group hello"), 3, 40, 0, 12, {}),
        (6, "￼", None, 1, 30, 0, 10, {"cache_has_attachments": 1}),
        (7, None, typedstream("Loved “my reply”"), 1, 20, 0, 10, {"associated_message_type": 2000}),
        (8, "stranger text", None, 4, 10, 0, 13, {}),
        (9, "old message", None, 1, 60 * 24 * 400, 0, 10, {}),
    ]
    for rowid, text, body, handle, ago, me, chat, extra in messages:
        date = apple_ns(NOW - timedelta(minutes=ago))
        conn.execute(
            """INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me,
                                    associated_message_type, item_type, cache_has_attachments)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)""",
            (
                rowid,
                f"guid-{rowid}",
                text,
                body,
                handle,
                date,
                me,
                extra.get("associated_message_type", 0),
                extra.get("cache_has_attachments", 0),
            ),
        )
        conn.execute("INSERT INTO chat_message_join VALUES (?, ?, ?)", (chat, rowid, date))
    conn.execute(
        "INSERT INTO attachment VALUES (1, '~/Library/Messages/Attachments/x/IMG_1.HEIC', 'image/heic', 'IMG_1.HEIC', 12345)"
    )
    conn.execute("INSERT INTO message_attachment_join VALUES (6, 1)")
    conn.commit()
    conn.close()


def build_addressbook(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(AB_SCHEMA)
    conn.executemany(
        "INSERT INTO ZABCDRECORD VALUES (?, ?, ?, ?, ?)",
        [
            (1, "Alex", "Rivera", None, None),
            (2, "Sam", "Okafor", None, "Sammy"),
            (3, "Alexis", "Chen", None, None),
            (4, None, None, "Acme Dental", None),
        ],
    )
    conn.executemany(
        "INSERT INTO ZABCDPHONENUMBER VALUES (?, ?, ?)",
        [(1, 1, "(555) 123-0001"), (2, 2, "+1 555 123 0002"), (3, 3, "555-123-0003"), (4, 4, "555-000-1111")],
    )
    conn.executemany("INSERT INTO ZABCDEMAILADDRESS VALUES (?, ?, ?)", [(1, 1, "Alex@Example.com")])
    conn.commit()
    conn.close()


@pytest.fixture
def dbs(tmp_path: Path) -> tuple[Path, Path]:
    chat = tmp_path / "chat.db"
    ab = tmp_path / "AddressBook-v22.abcddb"
    build_chat_db(chat)
    build_addressbook(ab)
    return chat, ab


@pytest.fixture
def store(dbs: tuple[Path, Path]) -> Store:
    chat, ab = dbs
    return Store(chat_db=lambda: chat, addressbook_dbs=lambda: [ab])
