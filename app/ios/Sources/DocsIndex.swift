import Foundation
import SQLite3

/// The bundled Python docs' search index (D37): web/docs/<python>.sqlite,
/// built by scripts/build-docs.py. Chunks (sections, API entries, glossary
/// terms) as Markdown with an FTS5 index, and a symbol table. Read-only; one
/// connection per version, all on one serial queue.
///
/// A ref is a page path with an optional anchor: "library/json.html#json.loads".
final class DocsIndex: @unchecked Sendable {
    struct Hit: Sendable {
        let ref: String
        let title: String
        let kind: String
        let breadcrumb: String
        let snippet: String

        func json(_ version: String) -> [String: Any] {
            ["ref": ref, "link": "docs:\(version)/\(ref)", "title": title, "kind": kind, "breadcrumb": breadcrumb, "snippet": snippet, "version": version]
        }
    }

    struct Page: Sendable {
        let ref: String
        let title: String
        let markdown: String
    }

    static let shared = DocsIndex()

    let queue = DispatchQueue(label: "eu.ronacher.Terrarium.docs", qos: .userInitiated)
    private var connections: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func htmlRoot(_ version: String) -> URL {
        Bundle.main.resourceURL!.appendingPathComponent("web/docs/\(version)", isDirectory: true)
    }

    /// The page in the viewer: app://app/docs/<version>/<ref>.
    static func url(_ version: String, ref: String) -> URL {
        URL(string: "app://app/docs/\(version)/\(ref)")! // AppSchemeHandler.scheme
    }

    // MARK: async API (off the main thread)

    func search(_ query: String, version: String, limit: Int = 20) async -> [Hit] {
        await run { (try? self.searchSync(query, version: version, limit: limit)) ?? [] }
    }

    func read(_ ref: String, version: String) async -> Page? {
        await run { try? self.readSync(ref, version: version) }
    }

    /// The ref of an API entry or module ("json.loads", "pathlib._local.Path.glob", "builtins.split").
    func lookup(_ symbol: String, version: String) async -> (ref: String, title: String)? {
        await run { try? self.lookupSync(symbol, version: version) }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: queries (on `queue`)

    private struct DocsError: Error {
        let message: String
    }

    private func db(_ version: String) throws -> OpaquePointer {
        if let db = connections[version] { return db }
        guard version.allSatisfy({ $0.isNumber || $0 == "." }) else { throw DocsError(message: "bad version") }
        let path = Bundle.main.resourceURL!.appendingPathComponent("web/docs/\(version).sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { throw DocsError(message: "no docs for \(version)") }
        var db: OpaquePointer?
        // immutable: the bundle is read-only, no locking or journal needed.
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            throw DocsError(message: "cannot open the docs index")
        }
        connections[version] = db
        return db
    }

    private func rows(_ db: OpaquePointer, _ sql: String, _ params: [Any] = []) throws -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DocsError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            if let s = p as? String { sqlite3_bind_text(stmt, Int32(i + 1), s, -1, Self.transient) }
            else if let n = p as? Int { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n)) }
        }
        var out: [[Any?]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw DocsError(message: String(cString: sqlite3_errmsg(db))) }
            out.append((0..<sqlite3_column_count(stmt)).map { c -> Any? in
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, c))
                case SQLITE_NULL: return nil
                default: return sqlite3_column_text(stmt, c).map { String(cString: $0) }
                }
            })
        }
        return out
    }

    private static func ref(_ path: String, _ anchor: String) -> String {
        anchor.isEmpty ? path : "\(path)#\(anchor)"
    }

    private static let chunkColumns = "p.path, c.anchor, c.title, c.kind, c.breadcrumb"

    private func hit(_ row: [Any?], snippet: String = "") -> Hit {
        Hit(ref: Self.ref(row[0] as? String ?? "", row[1] as? String ?? ""), title: row[2] as? String ?? "", kind: row[3] as? String ?? "",
            breadcrumb: row[4] as? String ?? "", snippet: snippet)
    }

    func searchSync(_ query: String, version: String, limit: Int) throws -> [Hit] {
        let db = try db(version)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [Hit] = []
        var seen = Set<String>()
        func add(_ h: Hit) {
            if hits.count < limit, seen.insert(h.ref).inserted { hits.append(h) }
        }
        // A name first: json.loads, str.split, Path.glob, loads.
        if q.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil {
            let lower = q.lowercased()
            let sql = """
                SELECT \(Self.chunkColumns), s.name FROM symbols s JOIN chunks c ON c.id = s.chunk JOIN pages p ON p.id = c.page
                WHERE s.lower = ?1 OR s.lower LIKE '%.' || ?2 ESCAPE '\\'
                ORDER BY s.lower = ?1 DESC, length(s.name) LIMIT 8
                """
            for row in try rows(db, sql, [lower, lower.replacingOccurrences(of: "_", with: "\\_")]) { add(hit(row)) }
        }
        // Then words, ranked by bm25 (title and symbol weigh most).
        let words = q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if !words.isEmpty {
            let quoted = words.map { "\"\($0)\"" }
            for match in [quoted.joined(separator: " ") + "*", quoted.joined(separator: " OR ")] where hits.count < limit {
                let sql = """
                    SELECT \(Self.chunkColumns), snippet(chunks_fts, 3, '', '', '…', 24) FROM chunks_fts
                    JOIN chunks c ON c.id = chunks_fts.rowid JOIN pages p ON p.id = c.page
                    WHERE chunks_fts MATCH ?1 ORDER BY bm25(chunks_fts, 10.0, 8.0, 2.0, 1.0) LIMIT ?2
                    """
                for row in try rows(db, sql, [match, limit * 2]) { add(hit(row, snippet: row[5] as? String ?? "")) }
                if words.count == 1 { break }
            }
        }
        return hits
    }

    func lookupSync(_ symbol: String, version: String) throws -> (ref: String, title: String)? {
        let db = try db(version)
        var parts = symbol.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        // Builtins are documented without a module: str.split, print.
        let builtins = parts.first == "builtins"
        if builtins { parts.removeFirst() }
        guard !parts.isEmpty else { return nil }
        let base = "SELECT \(Self.chunkColumns) FROM symbols s JOIN chunks c ON c.id = s.chunk JOIN pages p ON p.id = c.page"
        if let row = try rows(db, "\(base) WHERE s.name = ? LIMIT 1", [parts.joined(separator: ".")]).first {
            let h = hit(row)
            return (h.ref, h.title)
        }
        // Defined in one module, documented in another (pathlib._local.Path.glob -> pathlib.Path.glob),
        // or a method reached through its module (pathlib.glob -> pathlib.Path.glob): the shortest
        // name in the same module that ends the same way. Builtins prefer methods (split -> str.split).
        let prefix = builtins ? "" : parts[0] + "."
        for k in (builtins ? 0 : 1)..<parts.count {
            let suffix = parts[k...].joined(separator: ".")
            let sql = """
                \(base) WHERE s.name = ?1 || ?2 OR s.name LIKE ?1 || '%.' || ?2
                ORDER BY c.kind = 'method' DESC, length(s.name) LIMIT 1
                """
            if let row = try rows(db, sql, [prefix, suffix]).first {
                let h = hit(row)
                return (h.ref, h.title)
            }
        }
        return nil
    }

    func readSync(_ ref: String, version: String) throws -> Page? {
        let db = try db(version)
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        guard let path = parts.first, !path.isEmpty else { return nil }
        guard let page = try rows(db, "SELECT id, title FROM pages WHERE path = ?", [path]).first, let pageID = page[0] as? Int else { return nil }
        var range = (0, Int.max)
        var title = page[1] as? String ?? path
        if parts.count == 2 {
            guard let chunk = try rows(db, "SELECT ord, end_ord, title FROM chunks WHERE page = ? AND anchor = ?", [pageID, parts[1]]).first else { return nil }
            range = (chunk[0] as? Int ?? 0, chunk[1] as? Int ?? 0)
            title = chunk[2] as? String ?? title
        }
        let chunks = try rows(db, "SELECT depth, kind, title, body FROM chunks WHERE page = ? AND ord BETWEEN ? AND ? ORDER BY ord",
                              [pageID, range.0, min(range.1, Int(Int32.max))])
        let top = chunks.first?[0] as? Int ?? 0
        var out: [String] = []
        for c in chunks {
            let depth = (c[0] as? Int ?? 0) - top
            let kind = c[1] as? String ?? ""
            let heading = c[2] as? String ?? ""
            let body = c[3] as? String ?? ""
            let hashes = String(repeating: "#", count: min(depth + 1, 6))
            if ["section", "module"].contains(kind) {
                out.append("\(hashes) \(heading)")
            } else if kind == "term" {
                out.append("**\(heading)**")
            } else {
                out.append("\(hashes) `\(heading)` (\(kind))")
            }
            if !body.isEmpty { out.append(body) }
        }
        return Page(ref: ref, title: title, markdown: out.joined(separator: "\n\n"))
    }
}
