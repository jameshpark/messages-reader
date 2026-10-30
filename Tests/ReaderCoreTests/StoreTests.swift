import Foundation
import Testing
@testable import ReaderCore
@testable import ReaderShared

@Suite struct DecodeTests {
    @Test(arguments: ["hi", String(repeating: "x", count: 127), String(repeating: "é", count: 200),
                      String(repeating: "long ", count: 20000)])
    func roundTrips(_ text: String) {
        #expect(decodeAttributedBody(typedstream(text)) == text)
    }

    @Test(arguments: [nil, [], Array("no marker here".utf8), Array("NSString".utf8) + [0x01, 0x94],
                      Array(typedstream("abc").dropLast(60))] as [[UInt8]?])
    func rejectsMalformed(_ blob: [UInt8]?) {
        let decoded = decodeAttributedBody(blob)
        #expect(decoded == nil || decoded == "")
    }

    // Regression (long-text decoding): NSArchiver output for NSAttributedString of
    // n "a"s, from the NSString marker through the length (generated with
    // Foundation on macOS 27). 0x82 is followed by 4 bytes, not 3.
    @Test(arguments: [
        ([0x81, 0xFF, 0x7F] as [UInt8], 32767),
        ([0x82, 0x00, 0x80, 0x00, 0x00], 32768),
        ([0x82, 0x70, 0x11, 0x01, 0x00], 70000),
    ])
    func matchesFoundationLengthEncoding(_ length: [UInt8], _ n: Int) {
        let blob = Array("\u{04}\u{0B}streamtyped".utf8) + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
            + length + Array(repeating: UInt8(ascii: "a"), count: n) + [0x86]
        #expect(decodeAttributedBody(blob) == String(repeating: "a", count: n))
    }
}

@Suite final class StoreTests {
    let f = makeFixture()
    var store: Store { f.store }
    deinit { removeTree(f.dir) }

    @Test func recentDecodesAttributedBodyAndNamesSenders() throws {
        let rows = try store.recent(hours: 24, limit: 50).rows
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"]!.int!, $0) })
        #expect(byID[9] == nil)  // older than the window
        #expect(byID[2]?["text"] == "decoded body 100% real")
        #expect(byID[2]?["sender_name"] == "Alex Rivera")
        #expect(byID[3]?["from_me"] == true && byID[3]?["text"] == "my reply")
        #expect(byID[4]?["sender_name"] == "Alex Rivera")  // handle and contact formatted differently
        #expect(byID[5]?["sender_name"] == "Sam Okafor")
        #expect(byID[6]?["text"] == "" && byID[6]?["attachments"] == ["IMG_1.HEIC"])
        #expect(byID[7]?["kind"] == "reaction")
        #expect(byID[8]?["sender_name"] == .null)
        #expect(rows.map { $0["id"]!.int! } == byID.keys.sorted(by: >))  // newest first
    }

    @Test func recentRespectsLimit() throws {
        #expect(try store.recent(hours: 24, limit: 2).rows.count == 2)
    }

    @Test func searchMatchesTextAndAttributedBodyRows() throws {
        #expect(Set(try store.search(query: "HELLO", days: 30, limit: 50).ids) == [1, 5])
        #expect(try store.search(query: "attributedbody", days: 30, limit: 50).ids == [4])
    }

    @Test func searchTreatsWildcardsLiterally() throws {
        #expect(try store.search(query: "100%", days: 30, limit: 50).ids == [2])
        #expect(try store.search(query: "_", days: 30, limit: 50).ids == [])
    }

    @Test func searchWindowAndLimit() throws {
        #expect(try store.search(query: "old message", days: 30, limit: 50).ids == [])
        #expect(try store.search(query: "old message", days: 3650, limit: 50).ids.count == 1)
        #expect(try store.search(query: "e", days: 30, limit: 3).ids.count == 3)
    }

    // Regression (non-ASCII search): SQL LIKE folds only ASCII case.
    @Test func searchFoldsUnicodeCaseInPlainTextRows() throws {
        f.addMessage(20, handle: 4, chat: 13, text: "Rendez-vous à l'École")
        f.addMessage(21, handle: 4, chat: 13, text: "Die Straße ist gesperrt")
        f.addMessage(22, handle: 4, chat: 13, text: nil, body: typedstream("ÉCOLE again"))
        #expect(try store.search(query: "école", days: 30, limit: 10).ids == [22, 20])
        #expect(try store.search(query: "STRASSE", days: 30, limit: 10).ids == [21])
    }

    @Test(arguments: ["alex@example.com", "ALEX@example.com"])
    func threadByEmailExcludesGroupChats(_ target: String) throws {
        let result = try store.thread(target: target, limit: 50)
        #expect(result["chat_ids"] == [10])
        #expect(result.ids == [9, 1, 2, 3, 6, 7])  // oldest first, no group message 5
    }

    @Test func threadByNameCoversAllTheirOneToOneChats() throws {
        let result = try store.thread(target: "alex rivera", limit: 50)
        #expect(Set(result["chat_ids"]!.array!.compactMap(\.int)) == [10, 11])
        #expect(result.ids == [9, 1, 2, 3, 4, 6, 7])
    }

    @Test(arguments: ["(555) 123-0001", "+15551230001", "5551230001"])
    func threadByPhoneInAnyFormat(_ target: String) throws {
        #expect(try store.thread(target: target, limit: 50).ids == [4])
    }

    @Test func threadByChatIDIncludesGroup() throws {
        #expect(try store.thread(target: "chat:12", limit: 50).ids == [5])
    }

    @Test func threadLimitKeepsNewest() throws {
        #expect(try store.thread(target: "alex@example.com", limit: 2).ids == [6, 7])
    }

    @Test(arguments: [
        ("Alex", "2 contacts match"), ("Nobody", "no contact matches"), ("chat:999", "no chat with id"),
        ("+1 555 999 9999", "no Messages handle"), ("chat:+5", "no contact matches"),
    ])
    func threadErrors(_ target: String, _ message: String) {
        let error = #expect(throws: RequestError.self) { try store.thread(target: target, limit: 50) }
        #expect(error?.description.contains(message) == true, "\(String(describing: error))")
    }

    @Test func contactLookup() {
        #expect(store.contact(query: "alex", limit: 10).rows.map { $0["name"] } == ["Alex Rivera", "Alexis Chen"])
        #expect(store.contact(query: "sammy", limit: 10).rows.first?["phones"] == ["+1 555 123 0002"])
        #expect(store.contact(query: "555.123.0003", limit: 10).rows.first?["name"] == "Alexis Chen")
        #expect(store.contact(query: "alex@EXAMPLE.com", limit: 10).rows.first?["name"] == "Alex Rivera")
        #expect(store.contact(query: "acme", limit: 10).rows.first?["name"] == "Acme Dental")
        let capped = store.contact(query: "e", limit: 1)
        #expect(capped.rows.count == 1 && capped["total"]!.int! > 1)
    }

    @Test func chatsListParticipants() throws {
        let rows = try store.chats(limit: 10).rows
        #expect(rows.map { $0["chat_id"] } == [13, 10, 12, 11])
        let group = rows.first { $0["chat_id"] == 12 }!
        #expect(group["is_group"] == true && group["name"] == "Trip planning")
        #expect(Set(group["participants"]!.array!.compactMap { $0["name"]?.string }) == ["Alex Rivera", "Sam Okafor"])
    }

    @Test func attachmentsListMetadataOnly() throws {
        let rows = try store.attachments(target: nil, days: 30, limit: 10).rows
        #expect(rows == [[
            "date": rows[0]["date"]!, "chat_id": 10, "from_me": false, "sender": "alex@example.com",
            "sender_name": "Alex Rivera", "name": "IMG_1.HEIC", "mime_type": "image/heic", "bytes": 12345,
        ]])
        #expect(try store.attachments(target: "+15551230001", days: 30, limit: 10).rows == [])
    }

    @Test func longTextIsCapped() throws {
        WritableDB(f.chat).run("UPDATE message SET text = ? WHERE ROWID = 1",
                               [.text(String(repeating: "y", count: maxTextScalars + 50))])
        let row = try store.thread(target: "chat:10", limit: 50).rows.first { $0["id"] == 1 }!
        #expect(row["text"]?.string?.count == maxTextScalars && row["truncated"] == true)
    }

    @Test(arguments: [
        "INSERT INTO handle VALUES (99, 'x', 'y')", "UPDATE message SET text = 'x'", "DELETE FROM message",
        "DROP TABLE message", "CREATE TABLE evil (x)", "ATTACH DATABASE ':memory:' AS other",
        "PRAGMA query_only = OFF", "PRAGMA journal_mode = DELETE", "VACUUM",
    ])
    func connectionsRefuseEveryWrite(_ sql: String) throws {
        let db = try ReadOnlyDB(path: f.chat)
        #expect(throws: SQLiteError.self) { try db.query(sql) }
    }

    @Test func openReadOnlyNeverCreatesADatabase() {
        let missing = f.dir + "/missing.db"
        #expect(throws: SQLiteError.self) { try ReadOnlyDB(path: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test func storeOperationsLeaveDatabasesUnchanged() throws {
        let before = try [f.chat, f.ab].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        _ = store.check()
        _ = try store.recent(hours: 24, limit: 50)
        _ = try store.search(query: "e", days: 3650, limit: 50)
        _ = try store.thread(target: "Alex Rivera", limit: 50)
        _ = store.contact(query: "alex", limit: 10)
        _ = try store.chats(limit: 10)
        _ = try store.attachments(target: nil, days: 30, limit: 10)
        #expect(try [f.chat, f.ab].map { try Data(contentsOf: URL(fileURLWithPath: $0)) } == before)
    }

    @Test func readsUncheckpointedWALWhileWriterIsOpen() throws {
        let writer = WritableDB(f.chat)
        writer.exec("PRAGMA wal_autocheckpoint = 0")
        writer.exec("UPDATE message SET text = 'fresh in wal' WHERE ROWID = 8")
        #expect(try store.search(query: "fresh in wal", days: 30, limit: 5).ids == [8])
        writer.close()
    }

    @Test func checkReportsAccess() {
        let report = store.check()
        #expect(report["full_disk_access"] == true)
        #expect(report["last_message_at"]?.string != nil)
        #expect(report["addressbook_dbs_readable"] == 1)
    }

    @Test func checkReportsMissingAccess() throws {
        chmod(f.chat, 0)
        defer { chmod(f.chat, 0o600) }
        let report = store.check()
        #expect(report["full_disk_access"] == false)
        #expect(report["error"]?.string?.contains("Full Disk Access") == true)
        let error = #expect(throws: RequestError.self) { try store.recent(hours: 1, limit: 1) }
        #expect(error?.description.contains("Full Disk Access") == true)
    }

    @Test func missingAddressBookStillAnswers() throws {
        let chat = f.chat
        let rows = try Store(chatDB: { chat }, addressBooks: { ["/nonexistent/AddressBook-v22.abcddb"] })
            .recent(hours: 24, limit: 50).rows
        #expect(!rows.isEmpty && rows.allSatisfy { $0["sender_name"] == .null })
    }

    // Regression (mixed-up international numbers): last-10-digit keys merged
    // +44 20 7946 0123 with +1 207 946 0123.
    @Test func phoneNumbersFromDifferentCountriesNeverMerge() throws {
        let db = WritableDB(f.chat)
        db.exec("""
            INSERT INTO handle VALUES (5, '+12079460123', 'iMessage');
            INSERT INTO chat VALUES (14, 'iMessage;-;+12079460123', '+12079460123', '', 45);
            INSERT INTO chat_handle_join VALUES (14, 5);
            """)
        db.close()
        f.addMessage(30, handle: 5, chat: 14, text: "from Maine")
        let ab = WritableDB(f.ab)
        ab.exec("""
            INSERT INTO ZABCDRECORD VALUES (5, 'Pat', 'London', NULL, NULL);
            INSERT INTO ZABCDPHONENUMBER VALUES (5, 5, '+44 20 7946 0123');
            """)
        ab.close()
        #expect(try store.recent(hours: 1, limit: 50).rows.first { $0["id"] == 30 }?["sender_name"] == .null)
        #expect(store.contact(query: "+1 207 946 0123", limit: 10).rows == [])
        let error = #expect(throws: RequestError.self) { try store.thread(target: "Pat London", limit: 10) }
        #expect(error?.description.contains("no Messages handle") == true)
        #expect(try store.thread(target: "(207) 946-0123", limit: 10).ids == [30])
    }

    // Regression (SMS short codes): 5-6 digit senders were treated as contact names.
    @Test func smsShortCodesAreNumericTargets() throws {
        let db = WritableDB(f.chat)
        db.exec("""
            INSERT INTO handle VALUES (6, '12345', 'SMS');
            INSERT INTO chat VALUES (15, 'SMS;-;12345', '12345', '', 45);
            INSERT INTO chat_handle_join VALUES (15, 6);
            """)
        db.close()
        f.addMessage(40, handle: 6, chat: 15, text: "Your code is 000000")
        #expect(try store.thread(target: "12345", limit: 10).ids == [40])
        #expect(try store.attachments(target: "12345", days: 30, limit: 10).rows == [])
    }
}

@Suite struct HandleKeyTests {
    @Test(arguments: [
        ("+1 (555) 123-0001", "15551230001"), ("(555) 123-0001", "15551230001"), ("15551230001", "15551230001"),
        ("+44 20 7946 0123", "442079460123"), ("12345", "12345"), (" Alex@Example.COM ", "alex@example.com"),
    ])
    func handleKeys(_ raw: String, _ key: String) {
        #expect(handleKey(raw) == key)
    }

    @Test(arguments: [("12345", true), ("+1 (555) 123-0001", true), ("12", false), ("Alex", false),
                      ("555-ABC", false), ("+", false), ("chat:12", false)])
    func phoneDetection(_ value: String, _ expected: Bool) {
        #expect(isPhone(value) == expected)
    }
}
