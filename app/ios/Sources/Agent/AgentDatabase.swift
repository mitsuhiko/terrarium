import Foundation
import SQLite3

/// SQLite for pi-durable's `SqliteDatabase` facade (D32), one connection per
/// named database, all on one serial queue. The databases live in
/// Application Support/agent, not in WebKit's storage (Q2). The page serializes operations
/// itself, so a transaction is just `BEGIN IMMEDIATE`, statements, `COMMIT`
/// in order. A page that reloads in the middle of one leaves it open; `open`
/// and `rollbackAll` roll it back.
///
/// Values cross the bridge as JSON-ish types: null, number, string, and
/// `{"$bigint": "…"}` / `{"$blob": "<base64>"}`. Rows come back as
/// `{columns: [...], rows: [[...]]}` so column order survives.
final class AgentDatabase: @unchecked Sendable {
    struct SqlError: Error, CustomStringConvertible {
        let description: String
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    let queue = DispatchQueue(label: "eu.ronacher.Terrarium.agent.sql")
    private let directory: URL
    private var databases: [String: OpaquePointer] = [:]
    private var statements: [String: [String: OpaquePointer]] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Runs on `queue`.
    func perform(_ body: [String: Any]) throws -> Any {
        let action = body["action"] as? String ?? ""
        let name = body["db"] as? String ?? "main"
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw SqlError(description: "bad database name \(name)")
        }
        switch action {
        case "open": return try open(name)
        case "close": close(name); return NSNull()
        case "delete":
            close(name)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).sqlite\(suffix)"))
            }
            return NSNull()
        default: break
        }
        guard let db = databases[name] else { throw SqlError(description: "database \(name) is not open") }
        let sql = body["sql"] as? String ?? ""
        switch action {
        case "exec":
            try check(db, sqlite3_exec(db, sql, nil, nil, nil))
            return NSNull()
        case "run", "get", "all":
            let stmt = try statement(name, db, sql)
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            let params = body["params"] as? [Any] ?? []
            for (index, value) in params.enumerated() { try bind(db, stmt, Int32(index + 1), value) }
            var rows: [[Any]] = []
            while true {
                let code = sqlite3_step(stmt)
                if code == SQLITE_DONE { break }
                if code != SQLITE_ROW { try check(db, code) }
                if action == "run" { continue }
                rows.append(row(stmt))
                if action == "get" { break }
            }
            if action == "run" { return NSNull() }
            let count = sqlite3_column_count(stmt)
            let columns = (0..<count).map { String(cString: sqlite3_column_name(stmt, $0)) }
            return ["columns": columns, "rows": rows]
        default:
            throw SqlError(description: "unknown sql action \(action)")
        }
    }

    /// Roll back what a page that went away left open (runs on `queue`).
    func rollbackAll() -> [String] {
        var rolledBack: [String] = []
        for (name, db) in databases where sqlite3_get_autocommit(db) == 0 {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            rolledBack.append(name)
        }
        return rolledBack
    }

    private func open(_ name: String) throws -> Any {
        if let db = databases[name] {
            // The page reloaded: whatever it was doing is gone.
            let open = sqlite3_get_autocommit(db) == 0
            if open { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            return ["reopened": true, "rolledBack": open]
        }
        var db: OpaquePointer?
        let path = directory.appendingPathComponent("\(name).sqlite").path
        let code = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let db else {
            throw SqlError(description: "open \(name): \(code)")
        }
        sqlite3_busy_timeout(db, 5000)
        for pragma in ["PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL"] {
            try check(db, sqlite3_exec(db, pragma, nil, nil, nil))
        }
        databases[name] = db
        statements[name] = [:]
        return ["reopened": false, "rolledBack": false]
    }

    private func close(_ name: String) {
        guard let db = databases.removeValue(forKey: name) else { return }
        for stmt in statements.removeValue(forKey: name)?.values ?? [:].values { sqlite3_finalize(stmt) }
        if sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        sqlite3_close_v2(db)
    }

    private func statement(_ name: String, _ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        if let cached = statements[name]?[sql] { return cached }
        var stmt: OpaquePointer?
        try check(db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        guard let stmt else { throw SqlError(description: "empty statement") }
        statements[name]?[sql] = stmt
        return stmt
    }

    private func check(_ db: OpaquePointer, _ code: Int32) throws {
        guard code != SQLITE_OK, code != SQLITE_ROW, code != SQLITE_DONE else { return }
        throw SqlError(description: String(cString: sqlite3_errmsg(db)))
    }

    private func bind(_ db: OpaquePointer, _ stmt: OpaquePointer, _ index: Int32, _ value: Any) throws {
        let code: Int32
        switch value {
        case is NSNull:
            code = sqlite3_bind_null(stmt, index)
        case let text as String:
            code = sqlite3_bind_text(stmt, index, text, -1, Self.transient)
        case let number as NSNumber:
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 9.2e18 {
                code = sqlite3_bind_int64(stmt, index, Int64(double))
            } else {
                code = sqlite3_bind_double(stmt, index, double)
            }
        case let tagged as [String: Any]:
            if let big = tagged["$bigint"] as? String, let int = Int64(big) {
                code = sqlite3_bind_int64(stmt, index, int)
            } else if let b64 = tagged["$blob"] as? String, let data = Data(base64Encoded: b64) {
                code = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), Self.transient) }
            } else {
                throw SqlError(description: "unsupported tagged value \(tagged)")
            }
        default:
            throw SqlError(description: "unsupported value \(type(of: value))")
        }
        try check(db, code)
    }

    private func row(_ stmt: OpaquePointer) -> [Any] {
        (0..<sqlite3_column_count(stmt)).map { column -> Any in
            switch sqlite3_column_type(stmt, column) {
            case SQLITE_INTEGER:
                let int = sqlite3_column_int64(stmt, column)
                return abs(int) <= Self.maxSafeInteger ? NSNumber(value: int) : ["$bigint": String(int)]
            case SQLITE_FLOAT:
                return NSNumber(value: sqlite3_column_double(stmt, column))
            case SQLITE_TEXT:
                let count = Int(sqlite3_column_bytes(stmt, column))
                guard let bytes = sqlite3_column_text(stmt, column) else { return "" }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(stmt, column))
                guard let bytes = sqlite3_column_blob(stmt, column) else { return ["$blob": ""] }
                return ["$blob": Data(bytes: bytes, count: count).base64EncodedString()]
            default:
                return NSNull()
            }
        }
    }
}
