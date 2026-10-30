import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case text(String)
    case blob([UInt8])
}

public typealias SQLRow = [String: SQLValue]

extension Dictionary where Key == String, Value == SQLValue {
    func int(_ key: String) -> Int64? { if case .int(let v)? = self[key] { return v }; return nil }
    func text(_ key: String) -> String? { if case .text(let v)? = self[key] { return v }; return nil }
    func blob(_ key: String) -> [UInt8]? { if case .blob(let v)? = self[key] { return v }; return nil }
}

/// Only reading is authorized; every other statement kind is denied by SQLite itself.
private let readOnlyAuthorizer: @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32 = { _, action, _, _, _, _ in
    switch action {
    case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION: return SQLITE_OK
    default: return SQLITE_DENY
    }
}

/// A read-only SQLite connection: URI `mode=ro`, SQLITE_OPEN_READONLY,
/// `PRAGMA query_only`, and an authorizer that denies anything but reads.
public final class ReadOnlyDB {
    private var db: OpaquePointer?

    public init(path: String) throws {
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(rc)"
            sqlite3_close(db)
            db = nil
            throw SQLiteError(description: message)
        }
        sqlite3_busy_timeout(db, 5000)
        do {
            try execute("PRAGMA query_only = ON")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
        sqlite3_set_authorizer(db, readOnlyAuthorizer, nil)
    }

    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> SQLiteError {
        SQLiteError(description: String(cString: sqlite3_errmsg(db)))
    }

    /// Run `sql`, calling `body` per row until it returns false.
    public func each(_ sql: String, _ params: [SQLValue] = [], _ body: (SQLRow) throws -> Bool) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
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
        let columns = Int(sqlite3_column_count(stmt))
        let names = (0..<columns).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw lastError() }
            var row = SQLRow(minimumCapacity: columns)
            for (i, name) in names.enumerated() {
                let c = Int32(i)
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if n > 0, let p = sqlite3_column_blob(stmt, c) {
                        row[name] = .blob(Array(UnsafeRawBufferPointer(start: p, count: n)))
                    } else {
                        row[name] = .blob([])
                    }
                case SQLITE_FLOAT: row[name] = .int(Int64(sqlite3_column_double(stmt, c)))
                default: row[name] = .null
                }
            }
            if try !body(row) { return }
        }
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        var rows: [SQLRow] = []
        try each(sql, params) { rows.append($0); return true }
        return rows
    }
}
