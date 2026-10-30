from __future__ import annotations

import hashlib
import os
import sqlite3
from pathlib import Path

import pytest

from conftest import typedstream
from messages_reader.store import (
    MAX_TEXT_CHARS,
    RequestError,
    Store,
    decode_attributed_body,
    open_readonly,
)


@pytest.mark.parametrize("text", ["hi", "x" * 127, "é" * 200, "long " * 20000])
def test_decode_attributed_body_round_trips(text):
    assert decode_attributed_body(typedstream(text)) == text


@pytest.mark.parametrize("blob", [None, b"", b"no marker here", b"NSString\x01\x94", typedstream("abc")[:-60]])
def test_decode_attributed_body_rejects_malformed(blob):
    assert decode_attributed_body(blob) in (None, "")


def test_recent_decodes_attributed_body_and_names_senders(store):
    rows = store.recent(hours=24, limit=50)["rows"]
    by_id = {r["id"]: r for r in rows}
    assert 9 not in by_id  # older than the window
    assert by_id[2]["text"] == "decoded body 100% real"
    assert by_id[2]["sender_name"] == "Alex Rivera"
    assert by_id[3]["from_me"] and by_id[3]["text"] == "my reply"
    assert by_id[4]["sender_name"] == "Alex Rivera"  # handle and contact formatted differently
    assert by_id[5]["sender_name"] == "Sam Okafor"
    assert by_id[6]["text"] == "" and by_id[6]["attachments"] == ["IMG_1.HEIC"]
    assert by_id[7]["kind"] == "reaction"
    assert by_id[8]["sender_name"] is None
    assert [r["id"] for r in rows] == sorted(by_id, reverse=True)  # newest first


def test_recent_respects_limit(store):
    assert len(store.recent(hours=24, limit=2)["rows"]) == 2


def test_search_matches_text_and_attributed_body_rows(store):
    assert {r["id"] for r in store.search("HELLO", days=30, limit=50)["rows"]} == {1, 5}
    assert [r["id"] for r in store.search("attributedbody", days=30, limit=50)["rows"]] == [4]


def test_search_treats_like_wildcards_literally(store):
    assert [r["id"] for r in store.search("100%", days=30, limit=50)["rows"]] == [2]
    assert store.search("_", days=30, limit=50)["rows"] == []


def test_search_window_and_limit(store):
    assert store.search("old message", days=30, limit=50)["rows"] == []
    assert len(store.search("old message", days=3650, limit=50)["rows"]) == 1
    assert len(store.search("e", days=30, limit=3)["rows"]) == 3


@pytest.mark.parametrize("target", ["alex@example.com", "ALEX@example.com"])
def test_thread_by_email_excludes_group_chats(store, target):
    result = store.thread(target, limit=50)
    assert result["chat_ids"] == [10]
    assert [r["id"] for r in result["rows"]] == [9, 1, 2, 3, 6, 7]  # oldest first, no group msg 5


def test_thread_by_name_covers_all_their_one_to_one_chats(store):
    result = store.thread("alex rivera", limit=50)
    assert sorted(result["chat_ids"]) == [10, 11]
    assert [r["id"] for r in result["rows"]] == [9, 1, 2, 3, 4, 6, 7]


@pytest.mark.parametrize("target", ["(555) 123-0001", "+15551230001", "5551230001"])
def test_thread_by_phone_in_any_format(store, target):
    assert [r["id"] for r in store.thread(target, limit=50)["rows"]] == [4]


def test_thread_by_chat_id_includes_group(store):
    assert [r["id"] for r in store.thread("chat:12", limit=50)["rows"]] == [5]


def test_thread_limit_keeps_newest(store):
    assert [r["id"] for r in store.thread("alex@example.com", limit=2)["rows"]] == [6, 7]


@pytest.mark.parametrize(
    "target, message",
    [
        ("Alex", "2 contacts match"),
        ("Nobody", "no contact matches"),
        ("chat:999", "no chat with id"),
        ("+1 555 999 9999", "no Messages handle"),
    ],
)
def test_thread_errors(store, target, message):
    with pytest.raises(RequestError, match=message):
        store.thread(target, limit=50)


def test_contact_lookup(store):
    assert [c["name"] for c in store.contact("alex", limit=10)["rows"]] == ["Alex Rivera", "Alexis Chen"]
    assert store.contact("sammy", limit=10)["rows"][0]["phones"] == ["+1 555 123 0002"]
    assert store.contact("555.123.0003", limit=10)["rows"][0]["name"] == "Alexis Chen"
    assert store.contact("alex@EXAMPLE.com", limit=10)["rows"][0]["name"] == "Alex Rivera"
    assert store.contact("acme", limit=10)["rows"][0]["name"] == "Acme Dental"
    capped = store.contact("e", limit=1)
    assert len(capped["rows"]) == 1 and capped["total"] > 1


def test_chats_lists_participants(store):
    rows = store.chats(limit=10)["rows"]
    assert [r["chat_id"] for r in rows] == [13, 10, 12, 11]
    group = next(r for r in rows if r["chat_id"] == 12)
    assert group["is_group"] and group["name"] == "Trip planning"
    assert {p["name"] for p in group["participants"]} == {"Alex Rivera", "Sam Okafor"}


def test_attachments_lists_metadata_only(store):
    rows = store.attachments(target=None, days=30, limit=10)["rows"]
    assert rows == [
        {
            "date": rows[0]["date"],
            "chat_id": 10,
            "from_me": False,
            "sender": "alex@example.com",
            "sender_name": "Alex Rivera",
            "name": "IMG_1.HEIC",
            "mime_type": "image/heic",
            "bytes": 12345,
        }
    ]
    assert store.attachments(target="+15551230001", days=30, limit=10)["rows"] == []


def test_long_text_is_capped(dbs):
    chat, ab = dbs
    conn = sqlite3.connect(chat)
    conn.execute("UPDATE message SET text = ? WHERE ROWID = 1", ("y" * (MAX_TEXT_CHARS + 50),))
    conn.commit()
    conn.close()
    rows = Store(lambda: chat, lambda: [ab]).thread("chat:10", limit=50)["rows"]
    row = next(r for r in rows if r["id"] == 1)
    assert len(row["text"]) == MAX_TEXT_CHARS and row["truncated"]


@pytest.mark.parametrize(
    "sql",
    [
        "INSERT INTO handle VALUES (99, 'x', 'y')",
        "UPDATE message SET text = 'x'",
        "DELETE FROM message",
        "DROP TABLE message",
        "CREATE TABLE evil (x)",
        "ATTACH DATABASE ':memory:' AS other",
        "PRAGMA query_only = OFF",
        "PRAGMA journal_mode = DELETE",
        "VACUUM",
    ],
)
def test_connections_refuse_every_write(dbs, sql):
    conn = open_readonly(dbs[0])
    with pytest.raises(sqlite3.DatabaseError):
        conn.execute(sql)
    conn.close()


def test_open_readonly_never_creates_a_database(tmp_path):
    with pytest.raises(sqlite3.OperationalError):
        open_readonly(tmp_path / "missing.db")
    assert not (tmp_path / "missing.db").exists()


def test_store_operations_leave_database_unchanged(dbs, store):
    chat, ab = dbs
    before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in (chat, ab)}
    store.check()
    store.recent(hours=24, limit=50)
    store.search("e", days=3650, limit=50)
    store.thread("Alex Rivera", limit=50)
    store.contact("alex", limit=10)
    store.chats(limit=10)
    store.attachments(target=None, days=30, limit=10)
    assert {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in (chat, ab)} == before


def test_reads_uncheckpointed_wal_while_writer_is_open(dbs, store):
    chat, _ = dbs
    writer = sqlite3.connect(chat)
    writer.execute("PRAGMA wal_autocheckpoint = 0")
    writer.execute("UPDATE message SET text = 'fresh in wal' WHERE ROWID = 8")
    writer.commit()
    try:
        assert store.search("fresh in wal", days=30, limit=5)["rows"][0]["id"] == 8
    finally:
        writer.close()


def test_check_reports_access(store):
    report = store.check()
    assert report["full_disk_access"] is True
    assert report["last_message_at"]
    assert report["addressbook_dbs_readable"] == 1


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores file modes")
def test_check_reports_missing_access(dbs):
    chat, ab = dbs
    os.chmod(chat, 0)
    try:
        report = Store(lambda: chat, lambda: [ab]).check()
        assert report["full_disk_access"] is False
        assert "Full Disk Access" in report["error"]
        with pytest.raises(RequestError, match="Full Disk Access"):
            Store(lambda: chat, lambda: [ab]).recent(hours=1, limit=1)
    finally:
        os.chmod(chat, 0o600)


def test_missing_addressbook_still_answers(dbs):
    chat, _ = dbs
    store = Store(lambda: chat, lambda: [Path("/nonexistent/AddressBook-v22.abcddb")])
    rows = store.recent(hours=24, limit=50)["rows"]
    assert rows and all(r["sender_name"] is None for r in rows)


# NSArchiver output for NSAttributedString of 32768 and 70000 "a"s, from the
# NSString marker through the length (generated with Foundation on macOS 27).
@pytest.mark.parametrize(
    "header, n",
    [
        (b"NSString\x01\x94\x84\x01+\x81\xff\x7f", 32767),
        (b"NSString\x01\x94\x84\x01+\x82\x00\x80\x00\x00", 32768),
        (b"NSString\x01\x94\x84\x01+\x82\x70\x11\x01\x00", 70000),
    ],
)
def test_decode_matches_foundation_length_encoding(header, n):
    assert decode_attributed_body(b"\x04\x0bstreamtyped" + header + b"a" * n + b"\x86") == "a" * n


def _add_message(chat: Path, rowid: int, handle: int, chat_id: int, text: str | None, body: bytes | None = None):
    conn = sqlite3.connect(chat)
    date = conn.execute("SELECT MAX(date) FROM message").fetchone()[0] + 1
    conn.execute(
        "INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me) VALUES (?, ?, ?, ?, ?, ?, 0)",
        (rowid, f"guid-{rowid}", text, body, handle, date),
    )
    conn.execute("INSERT INTO chat_message_join VALUES (?, ?, ?)", (chat_id, rowid, date))
    conn.commit()
    conn.close()


def test_search_folds_unicode_case_in_plain_text_rows(dbs, store):
    chat, _ = dbs
    _add_message(chat, 20, 4, 13, "Rendez-vous à l'École")
    _add_message(chat, 21, 4, 13, "Die Straße ist gesperrt")
    _add_message(chat, 22, 4, 13, None, typedstream("ÉCOLE again"))
    assert [r["id"] for r in store.search("école", days=30, limit=10)["rows"]] == [22, 20]
    assert [r["id"] for r in store.search("STRASSE", days=30, limit=10)["rows"]] == [21]


def test_phone_numbers_from_different_countries_never_merge(dbs):
    chat, ab = dbs
    conn = sqlite3.connect(chat)
    conn.execute("INSERT INTO handle VALUES (5, '+12079460123', 'iMessage')")
    conn.execute("INSERT INTO chat VALUES (14, 'iMessage;-;+12079460123', '+12079460123', '', 45)")
    conn.execute("INSERT INTO chat_handle_join VALUES (14, 5)")
    conn.commit()
    conn.close()
    _add_message(chat, 30, 5, 14, "from Maine")
    conn = sqlite3.connect(ab)
    conn.execute("INSERT INTO ZABCDRECORD VALUES (5, 'Pat', 'London', NULL, NULL)")
    conn.execute("INSERT INTO ZABCDPHONENUMBER VALUES (5, 5, '+44 20 7946 0123')")
    conn.commit()
    conn.close()
    store = Store(lambda: chat, lambda: [ab])
    assert next(r for r in store.recent(hours=1, limit=50)["rows"] if r["id"] == 30)["sender_name"] is None
    assert store.contact("+1 207 946 0123", limit=10)["rows"] == []
    with pytest.raises(RequestError, match="no Messages handle"):
        store.thread("Pat London", limit=10)
    assert [r["id"] for r in store.thread("(207) 946-0123", limit=10)["rows"]] == [30]


@pytest.mark.parametrize(
    "raw, key",
    [
        ("+1 (555) 123-0001", "15551230001"),
        ("(555) 123-0001", "15551230001"),
        ("15551230001", "15551230001"),
        ("+44 20 7946 0123", "442079460123"),
        ("12345", "12345"),
        (" Alex@Example.COM ", "alex@example.com"),
    ],
)
def test_handle_key(raw, key):
    from messages_reader.store import handle_key

    assert handle_key(raw) == key


def test_sms_short_codes_are_numeric_targets(dbs):
    chat, ab = dbs
    conn = sqlite3.connect(chat)
    conn.execute("INSERT INTO handle VALUES (6, '12345', 'SMS')")
    conn.execute("INSERT INTO chat VALUES (15, 'SMS;-;12345', '12345', '', 45)")
    conn.execute("INSERT INTO chat_handle_join VALUES (15, 6)")
    conn.commit()
    conn.close()
    _add_message(chat, 40, 6, 15, "Your code is 000000")
    store = Store(lambda: chat, lambda: [ab])
    assert [r["id"] for r in store.thread("12345", limit=10)["rows"]] == [40]
    assert store.attachments(target="12345", days=30, limit=10)["rows"] == []
