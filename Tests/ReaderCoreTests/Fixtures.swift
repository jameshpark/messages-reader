// Synthetic chat.db and AddressBook fixtures with the columns the store reads.

import Foundation
import SQLite3
@testable import ReaderCore
import ReaderShared

/// Test-only writable connection for building fixtures.
final class WritableDB {
    private var db: OpaquePointer?

    init(_ path: String) {
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
    }

    deinit { close() }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    func exec(_ sql: String) {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        precondition(rc == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    func run(_ sql: String, _ params: [SQLValue]) {
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v): sqlite3_bind_blob(stmt, idx, v, Int32(v.count), transient)
            }
        }
        precondition(sqlite3_step(stmt) == SQLITE_DONE, String(cString: sqlite3_errmsg(db)))
    }

    func maxDate() -> Int64 {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT MAX(date) FROM message", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        return sqlite3_column_int64(stmt, 0)
    }
}

/// An attributedBody blob shaped like the ones Messages writes.
func typedstream(_ text: String) -> [UInt8] {
    let data = Array(text.utf8)
    let n = data.count
    // Same integer encoding NSArchiver writes (checked with Foundation on macOS 27).
    let length: [UInt8]
    if n < 0x80 {
        length = [UInt8(n)]
    } else if n < 0x8000 {
        length = [0x81, UInt8(n & 0xFF), UInt8(n >> 8)]
    } else {
        length = [0x82] + (0..<4).map { UInt8((n >> (8 * $0)) & 0xFF) }
    }
    let head: [UInt8] = Array("\u{04}\u{0B}streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12]
        + Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8)
        + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
    let tail: [UInt8] = [0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x05, 0x92, 0x84, 0x84, 0x84, 0x0C]
        + Array("NSDictionary".utf8) + [0x00, 0x94, 0x84, 0x01, 0x69, 0x01, 0x86, 0x86]
    return head + length + data + tail
}

func appleNS(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince(appleEpoch) * 1e9)
}

func makeTempDir() -> String {
    // /private/tmp, resolved, and short: sun_path is limited to 104 bytes.
    var template = Array("/private/tmp/mr-XXXXXX".utf8CString)
    precondition(mkdtemp(&template) != nil)
    let path = String(cString: template)
    // Socket setup in a parallel test may have umask 0177 applied process-wide.
    chmod(path, 0o700)
    return path
}

func makeDir(_ path: String) {
    mkdir(path, 0o700)
    chmod(path, 0o700)
}

func removeTree(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

struct Fixture {
    let dir: String
    let chat: String
    let ab: String

    var store: Store {
        let chat = self.chat, ab = self.ab
        return Store(chatDB: { chat }, addressBooks: { [ab] })
    }

    func addMessage(_ rowid: Int64, handle: Int64, chat chatID: Int64, text: String?, body: [UInt8]? = nil) {
        let db = WritableDB(chat)
        let date = db.maxDate() + 1
        db.run(
            "INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me) VALUES (?, ?, ?, ?, ?, ?, 0)",
            [.int(rowid), .text("guid-\(rowid)"), text.map(SQLValue.text) ?? .null, body.map(SQLValue.blob) ?? .null,
             .int(handle), .int(date)])
        db.run("INSERT INTO chat_message_join VALUES (?, ?, ?)", [.int(chatID), .int(rowid), .int(date)])
    }
}

let chatSchema = """
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

let addressBookSchema = """
    CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT,
                              ZORGANIZATION TEXT, ZNICKNAME TEXT);
    CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
    CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT);
    """

func makeFixture() -> Fixture {
    let dir = makeTempDir()
    let f = Fixture(dir: dir, chat: dir + "/chat.db", ab: dir + "/AddressBook-v22.abcddb")
    let now = Date()

    let db = WritableDB(f.chat)
    db.exec("PRAGMA journal_mode=WAL")  // as Messages uses
    db.exec(chatSchema)
    db.exec("""
        INSERT INTO handle VALUES (1, 'alex@example.com', 'iMessage'), (2, '+15551230001', 'SMS'),
            (3, '+15551230002', 'iMessage'), (4, '+15551230099', 'iMessage');
        INSERT INTO chat VALUES (10, 'iMessage;-;alex@example.com', 'alex@example.com', '', 45),
            (11, 'SMS;-;+15551230001', '+15551230001', '', 45),
            (12, 'iMessage;+;chat123', 'chat123', 'Trip planning', 43),
            (13, 'iMessage;-;+15551230099', '+15551230099', '', 45);
        INSERT INTO chat_handle_join VALUES (10, 1), (11, 2), (12, 1), (12, 3), (13, 4);
        """)
    // (rowid, text, attributedBody, handle, minutes ago, from_me, chat, reaction type, has attachments)
    let messages: [(Int64, String?, [UInt8]?, Int64, Double, Int64, Int64, Int64, Int64)] = [
        (1, "hello from text column", nil, 1, 300, 0, 10, 0, 0),
        (2, nil, typedstream("decoded body 100% real"), 1, 200, 0, 10, 0, 0),
        (3, nil, typedstream("my reply"), 1, 100, 1, 10, 0, 0),
        (4, nil, typedstream("sms over attributedBody"), 2, 50, 0, 11, 0, 0),
        (5, nil, typedstream("group hello"), 3, 40, 0, 12, 0, 0),
        (6, "\u{FFFC}", nil, 1, 30, 0, 10, 0, 1),
        (7, nil, typedstream("Loved “my reply”"), 1, 20, 0, 10, 2000, 0),
        (8, "stranger text", nil, 4, 10, 0, 13, 0, 0),
        (9, "old message", nil, 1, 60 * 24 * 400, 0, 10, 0, 0),
    ]
    for (rowid, text, body, handle, ago, me, chat, amt, att) in messages {
        let date = appleNS(now.addingTimeInterval(-ago * 60))
        db.run(
            """
            INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me,
                                 associated_message_type, item_type, cache_has_attachments)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            [.int(rowid), .text("guid-\(rowid)"), text.map(SQLValue.text) ?? .null, body.map(SQLValue.blob) ?? .null,
             .int(handle), .int(date), .int(me), .int(amt), .int(att)])
        db.run("INSERT INTO chat_message_join VALUES (?, ?, ?)", [.int(chat), .int(rowid), .int(date)])
    }
    db.exec("""
        INSERT INTO attachment VALUES (1, '~/Library/Messages/Attachments/x/IMG_1.HEIC', 'image/heic', 'IMG_1.HEIC', 12345);
        INSERT INTO message_attachment_join VALUES (6, 1);
        """)
    db.close()

    let ab = WritableDB(f.ab)
    ab.exec(addressBookSchema)
    ab.exec("""
        INSERT INTO ZABCDRECORD VALUES (1, 'Alex', 'Rivera', NULL, NULL), (2, 'Sam', 'Okafor', NULL, 'Sammy'),
            (3, 'Alexis', 'Chen', NULL, NULL), (4, NULL, NULL, 'Acme Dental', NULL);
        INSERT INTO ZABCDPHONENUMBER VALUES (1, 1, '(555) 123-0001'), (2, 2, '+1 555 123 0002'),
            (3, 3, '555-123-0003'), (4, 4, '555-000-1111');
        INSERT INTO ZABCDEMAILADDRESS VALUES (1, 1, 'Alex@Example.com');
        """)
    ab.close()
    return f
}

extension JSONValue {
    var rows: [JSONValue] { self["rows"]?.array ?? [] }
    var ids: [Int] { rows.compactMap { $0["id"]?.int } }
}
