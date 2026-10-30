import Foundation
import ReaderShared

/// A request that is well-formed but can't be answered (shown to the caller).
public struct RequestError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Contact: Equatable {
    public var name: String
    public var aliases: [String]
    public var phones: [String] = []
    public var emails: [String] = []

    var keys: Set<String> { Set((phones + emails).map(handleKey).filter { !$0.isEmpty }) }

    var json: JSONValue {
        ["name": .string(name), "phones": .array(phones.map(JSONValue.string)),
         "emails": .array(emails.map(JSONValue.string))]
    }
}

/// Read-only queries against chat.db and the AddressBook databases.
public final class Store {
    let chatDBPath: () -> String
    let addressBookPaths: () -> [String]

    public init(
        chatDB: @escaping () -> String = { Paths.chatDB },
        addressBooks: @escaping () -> [String] = Store.defaultAddressBooks
    ) {
        chatDBPath = chatDB
        addressBookPaths = addressBooks
    }

    public static func defaultAddressBooks() -> [String] {
        let root = Paths.addressBookRoot
        let fm = FileManager.default
        var paths = ((try? fm.contentsOfDirectory(atPath: root + "/Sources")) ?? []).sorted()
            .map { "\(root)/Sources/\($0)/AddressBook-v22.abcddb" }
            .filter { fm.fileExists(atPath: $0) }
        let topLevel = root + "/AddressBook-v22.abcddb"
        if fm.fileExists(atPath: topLevel) { paths.append(topLevel) }
        return paths
    }

    func openChat() throws -> ReadOnlyDB {
        let path = chatDBPath()
        do {
            return try ReadOnlyDB(path: path)
        } catch let e as SQLiteError {
            throw RequestError("cannot open \(path): \(e). The service binary needs Full Disk Access.")
        }
    }

    // MARK: contacts

    public func contacts() -> [Contact] {
        var seen = Set<String>()
        var result: [Contact] = []
        for path in addressBookPaths() {
            guard let db = try? ReadOnlyDB(path: path), let people = try? readAddressBook(db) else {
                continue
            }
            for c in people {
                let ident = c.name + "\u{0}" + c.keys.sorted().joined(separator: ",")
                if seen.insert(ident).inserted { result.append(c) }
            }
        }
        return result
    }

    func namesByKey() -> [String: String] {
        var names: [String: String] = [:]
        for c in contacts() {
            for k in c.keys where names[k] == nil { names[k] = c.name }
        }
        return names
    }

    public func contact(query: String, limit: Int) -> JSONValue {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let qKey = (q.contains("@") || isPhone(q)) ? handleKey(q) : nil
        var matches = contacts().filter { c in
            if let qKey { return c.keys.contains(qKey) }
            return c.aliases.contains { containsFolded($0, q) }
        }
        matches.sort { $0.name.lowercased() < $1.name.lowercased() }
        return ["rows": .array(matches.prefix(limit).map(\.json)), "total": .int(matches.count)]
    }

    // MARK: messages

    public func check() -> JSONValue {
        let path = chatDBPath()
        var report: [String: JSONValue] = [
            "service_version": .string(serviceVersion),
            "chat_db": .string(path),
            "chat_db_exists": .bool(FileManager.default.fileExists(atPath: path)),
        ]
        do {
            let db = try openChat()
            let last = try db.query("SELECT MAX(date) AS last FROM message").first?.int("last")
            report["full_disk_access"] = true
            report["last_message_at"] = JSONValue(appleTimeToISO(last))
        } catch {
            report["full_disk_access"] = false
            report["error"] = .string("\(error)")
        }
        let books = addressBookPaths()
        report["addressbook_dbs_found"] = .int(books.count)
        report["addressbook_dbs_readable"] = .int(books.filter { (try? ReadOnlyDB(path: $0)) != nil }.count)
        return .object(report)
    }

    public func recent(hours: Int, limit: Int) throws -> JSONValue {
        let db = try openChat()
        let rows = try db.query(
            messageSelect + " WHERE m.date >= ? ORDER BY m.date DESC LIMIT ?",
            [.int(appleNanosSince(seconds: Double(hours) * 3600)), .int(Int64(limit))])
        return ["rows": .array(try render(db, rows))]
    }

    public func search(query: String, days: Int, limit: Int) throws -> JSONValue {
        let db = try openChat()
        var matched: [SQLRow] = []
        // Match in Swift, not with SQL LIKE: LIKE folds only ASCII case and
        // can't see text that exists only in attributedBody.
        try db.each(
            messageSelect + " WHERE m.date >= ? ORDER BY m.date DESC",
            [.int(appleNanosSince(seconds: Double(days) * 86400))]
        ) { row in
            if containsFolded(body(of: row), query) { matched.append(row) }
            return matched.count < limit
        }
        return ["rows": .array(try render(db, matched))]
    }

    public func thread(target: String, limit: Int) throws -> JSONValue {
        let db = try openChat()
        let chatIDs = try resolveChats(db, target)
        let rows = try db.query(
            messageSelect + """
                 WHERE m.ROWID IN (SELECT message_id FROM chat_message_join WHERE chat_id IN (\(marks(chatIDs.count))))
                 ORDER BY m.date DESC LIMIT ?
                """,
            chatIDs.map { .int($0) } + [.int(Int64(limit))])
        return [
            "chat_ids": .array(chatIDs.map { .int(Int($0)) }),
            "rows": .array(try render(db, rows).reversed()),
        ]
    }

    public func chats(limit: Int) throws -> JSONValue {
        let names = namesByKey()
        let db = try openChat()
        let rows = try db.query(
            """
            SELECT c.ROWID AS chat_id, c.display_name, c.chat_identifier,
                   MAX(cmj.message_date) AS last_date
            FROM chat c JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.ROWID ORDER BY last_date DESC LIMIT ?
            """, [.int(Int64(limit))])
        let members = try chatMembers(db, rows.compactMap { $0.int("chat_id") })
        return ["rows": .array(rows.map { r in
            let handles = members[r.int("chat_id") ?? -1] ?? []
            let display = r.text("display_name") ?? ""
            return [
                "chat_id": .int(Int(r.int("chat_id") ?? 0)),
                "name": display.isEmpty ? .null : .string(display),
                "identifier": JSONValue(r.text("chat_identifier")),
                "is_group": .bool(handles.count > 1),
                "participants": .array(handles.map { h in
                    ["handle": .string(h), "name": JSONValue(names[handleKey(h)])]
                }),
                "last_message_at": JSONValue(appleTimeToISO(r.int("last_date"))),
            ]
        })]
    }

    public func attachments(target: String?, days: Int, limit: Int) throws -> JSONValue {
        let names = namesByKey()
        let db = try openChat()
        var whereSQL = "m.date >= ?"
        var params: [SQLValue] = [.int(appleNanosSince(seconds: Double(days) * 86400))]
        if let target {
            let chatIDs = try resolveChats(db, target)
            whereSQL += " AND m.ROWID IN (SELECT message_id FROM chat_message_join WHERE chat_id IN (\(marks(chatIDs.count))))"
            params += chatIDs.map { .int($0) }
        }
        let rows = try db.query(
            """
            SELECT a.transfer_name, a.mime_type, a.total_bytes, m.date, m.is_from_me, h.id AS handle,
                   (SELECT chat_id FROM chat_message_join WHERE message_id = m.ROWID LIMIT 1) AS chat_id
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE \(whereSQL) ORDER BY m.date DESC LIMIT ?
            """, params + [.int(Int64(limit))])
        return ["rows": .array(rows.map { r in
            var row = sender(r, names)
            row["date"] = JSONValue(appleTimeToISO(r.int("date")))
            row["chat_id"] = JSONValue(r.int("chat_id").map(Int.init))
            row["name"] = JSONValue(r.text("transfer_name"))
            row["mime_type"] = JSONValue(r.text("mime_type"))
            row["bytes"] = JSONValue(r.int("total_bytes").map(Int.init))
            return .object(row)
        })]
    }

    // MARK: helpers

    func resolveChats(_ db: ReadOnlyDB, _ rawTarget: String) throws -> [Int64] {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let idText = target.dropFirst(5)
        if target.hasPrefix("chat:"), (1...18).contains(idText.count),
            idText.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int64(idText)
        {
            guard try !db.query("SELECT 1 FROM chat WHERE ROWID = ?", [.int(id)]).isEmpty else {
                throw RequestError("no chat with id \(id)")
            }
            return [id]
        }
        var keys: Set<String>
        if target.contains("@") || isPhone(target) {
            keys = [handleKey(target)]
        } else {
            let found = contacts().filter { c in c.aliases.contains { containsFolded($0, target) } }
            let exact = found.filter { $0.name.compare(target, options: .caseInsensitive) == .orderedSame }
            let chosen = exact.isEmpty ? found : exact
            if chosen.isEmpty { throw RequestError("no contact matches '\(target)'") }
            if chosen.count > 1 {
                throw RequestError(
                    "\(chosen.count) contacts match '\(target)'; run `contact` and pass a phone number or email")
            }
            keys = chosen[0].keys
        }
        keys.remove("")
        if keys.isEmpty { throw RequestError("'\(target)' is not a usable phone number or email") }
        let handleIDs = try db.query("SELECT ROWID, id FROM handle")
            .filter { keys.contains(handleKey($0.text("id") ?? "")) }
            .compactMap { $0.int("ROWID") }
        if handleIDs.isEmpty { throw RequestError("no Messages handle matches '\(target)'") }
        // One-to-one chats only: a chat whose sole participant is this person.
        let chatIDs = try db.query(
            """
            SELECT chat_id FROM chat_handle_join GROUP BY chat_id
            HAVING COUNT(*) = 1 AND MAX(handle_id) IN (\(marks(handleIDs.count)))
            """, handleIDs.map { .int($0) }
        ).compactMap { $0.int("chat_id") }
        if chatIDs.isEmpty { throw RequestError("no one-to-one chat with '\(target)'") }
        return chatIDs
    }

    func render(_ db: ReadOnlyDB, _ rows: [SQLRow]) throws -> [JSONValue] {
        let names = namesByKey()
        let files = try attachmentNames(
            db, rows.filter { ($0.int("cache_has_attachments") ?? 0) != 0 }.compactMap { $0.int("id") })
        return rows.map { r in
            let (text, truncated) = capText(body(of: r))
            let kind: String
            if (r.int("item_type") ?? 0) != 0 {
                kind = "event"
            } else if (2000..<4000).contains(r.int("associated_message_type") ?? 0) {
                // Tapbacks and sticker reactions.
                kind = "reaction"
            } else {
                kind = "message"
            }
            var row = sender(r, names)
            row["id"] = .int(Int(r.int("id") ?? 0))
            row["date"] = JSONValue(appleTimeToISO(r.int("date")))
            row["chat_id"] = JSONValue(r.int("chat_id").map(Int.init))
            row["kind"] = .string(kind)
            row["text"] = .string(text)
            row["attachments"] = .array((files[r.int("id") ?? -1] ?? []).map(JSONValue.string))
            if truncated { row["truncated"] = true }
            return .object(row)
        }
    }

    func attachmentNames(_ db: ReadOnlyDB, _ messageIDs: [Int64]) throws -> [Int64: [String]] {
        var found: [Int64: [String]] = [:]
        for chunk in chunks(messageIDs) {
            for r in try db.query(
                """
                SELECT maj.message_id, a.transfer_name, a.mime_type
                FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id IN (\(marks(chunk.count)))
                """, chunk.map { .int($0) })
            {
                found[r.int("message_id") ?? -1, default: []].append(
                    r.text("transfer_name") ?? r.text("mime_type") ?? "attachment")
            }
        }
        return found
    }

    func chatMembers(_ db: ReadOnlyDB, _ chatIDs: [Int64]) throws -> [Int64: [String]] {
        var members: [Int64: [String]] = [:]
        for chunk in chunks(chatIDs) {
            for r in try db.query(
                """
                SELECT chj.chat_id, h.id FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id IN (\(marks(chunk.count)))
                """, chunk.map { .int($0) })
            {
                members[r.int("chat_id") ?? -1, default: []].append(r.text("id") ?? "")
            }
        }
        return members
    }
}

public let serviceVersion = "0.2.0"

let messageSelect = """
    SELECT m.ROWID AS id, m.date, m.is_from_me, m.text, m.attributedBody,
           m.associated_message_type, m.item_type, m.cache_has_attachments,
           h.id AS handle,
           (SELECT chat_id FROM chat_message_join WHERE message_id = m.ROWID LIMIT 1) AS chat_id
    FROM message m
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    """

private func body(of row: SQLRow) -> String {
    let text = row.text("text") ?? ""
    return cleanText(text.isEmpty ? decodeAttributedBody(row.blob("attributedBody")) : text)
}

private func sender(_ r: SQLRow, _ names: [String: String]) -> [String: JSONValue] {
    if (r.int("is_from_me") ?? 0) != 0 {
        return ["from_me": true, "sender": "me", "sender_name": nil]
    }
    let handle = r.text("handle")
    return [
        "from_me": false,
        "sender": JSONValue(handle),
        "sender_name": JSONValue(handle.flatMap { names[handleKey($0)] }),
    ]
}

private func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

private func chunks(_ items: [Int64], size: Int = 500) -> [[Int64]] {
    stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
}

private func readAddressBook(_ db: ReadOnlyDB) throws -> [Contact] {
    var people: [Int64: Contact] = [:]
    var order: [Int64] = []
    for r in try db.query("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, ZNICKNAME FROM ZABCDRECORD") {
        let full = [r.text("ZFIRSTNAME"), r.text("ZLASTNAME")].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " ")
        let aliases = [full, r.text("ZORGANIZATION") ?? "", r.text("ZNICKNAME") ?? ""].filter { !$0.isEmpty }
        if let pk = r.int("Z_PK"), let first = aliases.first {
            people[pk] = Contact(name: first, aliases: aliases)
            order.append(pk)
        }
    }
    for r in try db.query("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER") {
        if let owner = r.int("ZOWNER"), let number = r.text("ZFULLNUMBER"), people[owner] != nil {
            people[owner]!.phones.append(number)
        }
    }
    for r in try db.query("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS") {
        if let owner = r.int("ZOWNER"), let address = r.text("ZADDRESS"), people[owner] != nil {
            people[owner]!.emails.append(address)
        }
    }
    return order.compactMap { people[$0] }.filter { !$0.phones.isEmpty || !$0.emails.isEmpty }
}
