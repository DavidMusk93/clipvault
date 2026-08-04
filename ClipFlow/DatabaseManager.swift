import Foundation
import SQLite3

enum DatabaseError: Error {
    case connectionFailed
    case statementFailed(String)
    case queryFailed(String)
}

/// Cursor for keyset pagination: (timestamp DESC, id DESC)
struct ClipCursor: Equatable {
    let timestamp: Double
    let id: String

    /// Wire format: "{timestamp}:{uuid}"
    func encode() -> String {
        "\(timestamp):\(id)"
    }

    static func decode(_ raw: String) -> ClipCursor? {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let ts = Double(parts[0]), !parts[1].isEmpty else { return nil }
        return ClipCursor(timestamp: ts, id: parts[1])
    }
}

struct ClipPage {
    let items: [ClipboardItem]
    let nextCursor: ClipCursor?
}

/// SQLite-backed store for Keepsake.
/// Runtime profile follows `sqlite-runtime-tricks` skill (WAL, busy_timeout, ANALYZE,
/// FTS5, batched mass-delete, sqlite3_backup online backup).
final class DatabaseManager: ObservableObject {
    private let dbPath: URL
    private let dbQueue = DispatchQueue(label: "com.clipflow.database", qos: .userInitiated)
    private var db: OpaquePointer?
    private var optimizeTimer: DispatchSourceTimer?

    /// Mass-delete batch size so one writer never holds the lock for the full table.
    private static let deleteBatchSize = 500
    /// How often long-lived connections run `PRAGMA optimize` (seconds).
    private static let optimizeIntervalSeconds: Double = 6 * 3600

    init() {
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory.appendingPathComponent("com.clipflow.app")
        let appDir = docsDir.appendingPathComponent("ClipFlow")

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("clipflow.db")

        initializeDatabase()
        startOptimizeTimer()
    }

    var dbFileURL: URL { dbPath }

    // MARK: - Open / pragmas / schema

    private func initializeDatabase() {
        if openAndConfigure() {
            createTables()
            bootstrapFTSIfNeeded()
            runAnalyze()
        } else {
            print("Failed to open SQLite database at \(dbPath.path)")
        }
    }

    @discardableResult
    private func openAndConfigure() -> Bool {
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            return false
        }
        applyConnectionPragmas()
        return true
    }

    /// Per-connection (and durable) runtime profile — run after every open/reopen.
    private func applyConnectionPragmas() {
        guard let db = db else { return }
        // journal_mode persists; others are per-connection.
        execQuiet("PRAGMA journal_mode=WAL;")
        execQuiet("PRAGMA synchronous=NORMAL;")
        execQuiet("PRAGMA busy_timeout=5000;")
        execQuiet("PRAGMA temp_store=MEMORY;")
        execQuiet("PRAGMA foreign_keys=ON;")
        // ~256 MiB mmap window; OS manages physical pages.
        execQuiet("PRAGMA mmap_size=268435456;")
        // Negative cache_size = KiB → ~64 MiB page cache.
        execQuiet("PRAGMA cache_size=-64000;")
        // Passive autocheckpoint default is fine; keep WAL from unbounded growth on bulk ops.
        execQuiet("PRAGMA wal_autocheckpoint=1000;")
        _ = db
    }

    private func createTables() {
        let createSQL = """
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            type TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            text_content TEXT,
            image_data BLOB,
            file_urls TEXT,
            url TEXT,
            rtf_data BLOB,
            pdf_data BLOB,
            html_content TEXT,
            raw_data BLOB,
            source_app TEXT,
            ocr_text TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp);
        CREATE INDEX IF NOT EXISTS idx_ts_id ON clipboard_items(timestamp DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash);
        """
        execQuiet(createSQL)
    }

    /// FTS5 index for search (replaces multi-column `LIKE '%q%'` full scans).
    private func bootstrapFTSIfNeeded() {
        guard let db = db else { return }

        let ftsSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
            id UNINDEXED,
            text_content,
            ocr_text,
            source_app,
            html_content,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """
        execQuiet(ftsSQL)

        // One-time backfill when FTS is empty but base table is not.
        var ftsCount: Int64 = 0
        var baseCount: Int64 = 0
        if let c = scalarInt64("SELECT COUNT(*) FROM clipboard_fts;") { ftsCount = c }
        if let c = scalarInt64("SELECT COUNT(*) FROM clipboard_items;") { baseCount = c }

        if ftsCount == 0 && baseCount > 0 {
            let backfill = """
            INSERT INTO clipboard_fts(id, text_content, ocr_text, source_app, html_content)
            SELECT id,
                   IFNULL(text_content,''),
                   IFNULL(ocr_text,''),
                   IFNULL(source_app,''),
                   IFNULL(html_content,'')
            FROM clipboard_items;
            """
            execQuiet(backfill)
            print("[DatabaseManager] FTS5 backfill: \(baseCount) rows")
        }
        _ = db
    }

    private func runAnalyze() {
        execQuiet("ANALYZE;")
    }

    private func runOptimize() {
        // Recommended by SQLite for long-lived apps (pragma_optimize).
        execQuiet("PRAGMA optimize;")
    }

    private func startOptimizeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: dbQueue)
        timer.schedule(
            deadline: .now() + Self.optimizeIntervalSeconds,
            repeating: Self.optimizeIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.runOptimize()
            // Cheap passive checkpoint so WAL does not grow without bound under clip bursts.
            self?.execQuiet("PRAGMA wal_checkpoint(PASSIVE);")
        }
        timer.resume()
        optimizeTimer = timer
    }

    // MARK: - Helpers

    @discardableResult
    private func execQuiet(_ sql: String) -> Bool {
        guard let db = db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            if let err { sqlite3_free(err) }
            print("[DatabaseManager] SQL error: \(msg) | \(sql.prefix(120))")
            return false
        }
        return true
    }

    private func scalarInt64(_ sql: String) -> Int64? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func upsertFTS(id: String, text: String?, ocr: String?, source: String?, html: String?) {
        // Delete-then-insert keeps FTS in sync with INSERT OR REPLACE on base table.
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM clipboard_fts WHERE id = ?;", -1, &del, nil) == SQLITE_OK {
            bindText(del, 1, id)
            _ = sqlite3_step(del)
        }
        sqlite3_finalize(del)

        let sql = """
        INSERT INTO clipboard_fts(id, text_content, ocr_text, source_app, html_content)
        VALUES (?, ?, ?, ?, ?);
        """
        var ins: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &ins, nil) == SQLITE_OK {
            bindText(ins, 1, id)
            bindText(ins, 2, text ?? "")
            bindText(ins, 3, ocr ?? "")
            bindText(ins, 4, source ?? "")
            bindText(ins, 5, html ?? "")
            _ = sqlite3_step(ins)
        }
        sqlite3_finalize(ins)
    }

    private func deleteFTS(id: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM clipboard_fts WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, id)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Build a safe FTS5 MATCH expression (AND of tokens; ASCII gets prefix `token*`).
    private func ftsMatchQuery(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip FTS operators / quotes; keep letters/digits/CJK/underscore/hyphen.
        let cleaned = trimmed.unicodeScalars.map { s -> Character in
            if CharacterSet.alphanumerics.contains(s) || s == "_" || s == "-" || s.value > 0x7F {
                return Character(s)
            }
            return " "
        }
        let tokens = String(cleaned)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty && $0.count <= 64 }
        guard !tokens.isEmpty else { return nil }
        // AND terms. ASCII: prefix match. Non-ASCII (e.g. CJK): exact token.
        let parts = tokens.map { tok -> String in
            let isAscii = tok.unicodeScalars.allSatisfy { $0.isASCII }
            if isAscii {
                return "\(tok)*"
            }
            return "\"\(tok.replacingOccurrences(of: "\"", with: ""))\""
        }
        return parts.joined(separator: " ")
    }

    // MARK: - CRUD

    func saveItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }

            let sql = """
            INSERT OR REPLACE INTO clipboard_items
            (id, timestamp, type, content_hash, text_content, image_data, file_urls, url, rtf_data, pdf_data, html_content, raw_data, source_app, ocr_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let idStr = item.id.uuidString
                self.bindText(stmt, 1, idStr)
                sqlite3_bind_double(stmt, 2, item.timestamp.timeIntervalSince1970)
                self.bindText(stmt, 3, item.type.rawValue)
                self.bindText(stmt, 4, item.contentHash)

                if let text = item.textContent {
                    self.bindText(stmt, 5, text)
                } else { sqlite3_bind_null(stmt, 5) }

                if let imgData = item.imageData {
                    imgData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(imgData.count), Self.SQLITE_TRANSIENT)
                    }
                } else { sqlite3_bind_null(stmt, 6) }

                let fileURLsStr = item.fileURLs?.map { $0.path }.joined(separator: "|")
                if let fUrls = fileURLsStr {
                    self.bindText(stmt, 7, fUrls)
                } else { sqlite3_bind_null(stmt, 7) }

                if let urlStr = item.url?.absoluteString {
                    self.bindText(stmt, 8, urlStr)
                } else { sqlite3_bind_null(stmt, 8) }

                if let rtfData = item.rtfData {
                    rtfData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 9, ptr.baseAddress, Int32(rtfData.count), Self.SQLITE_TRANSIENT)
                    }
                } else { sqlite3_bind_null(stmt, 9) }

                if let pdfData = item.pdfData {
                    pdfData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 10, ptr.baseAddress, Int32(pdfData.count), Self.SQLITE_TRANSIENT)
                    }
                } else { sqlite3_bind_null(stmt, 10) }

                if let html = item.htmlContent {
                    self.bindText(stmt, 11, html)
                } else { sqlite3_bind_null(stmt, 11) }

                sqlite3_bind_null(stmt, 12)

                if let srcApp = item.sourceApp {
                    self.bindText(stmt, 13, srcApp)
                } else { sqlite3_bind_null(stmt, 13) }

                if let ocr = item.ocrText {
                    self.bindText(stmt, 14, ocr)
                } else { sqlite3_bind_null(stmt, 14) }

                let stepRes = sqlite3_step(stmt)
                sqlite3_finalize(stmt)

                let success = (stepRes == SQLITE_DONE)
                if success {
                    self.upsertFTS(
                        id: idStr,
                        text: item.textContent,
                        ocr: item.ocrText,
                        source: item.sourceApp,
                        html: item.htmlContent
                    )
                }
                DispatchQueue.main.async { completion?(success) }
            } else {
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    /// Metadata-only list (no image BLOB) — required for 10k-scale feeds.
    func fetchItems(limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        fetchPage(limit: limit, cursor: nil, query: nil) { page in
            completion(page.items)
        }
    }

    /// Keyset pagination. Cursor points to last item of previous page.
    /// Search uses FTS5 MATCH; falls back to LIKE only if FTS query cannot be built.
    func fetchPage(
        limit: Int = 30,
        cursor: ClipCursor? = nil,
        query: String? = nil,
        completion: @escaping (ClipPage) -> Void
    ) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                completion(ClipPage(items: [], nextCursor: nil))
                return
            }

            let pageLimit = max(1, min(limit, 100))
            let fetchLimit = pageLimit + 1 // detect hasMore
            let q = query?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasQuery = !(q ?? "").isEmpty
            let ftsMatch = hasQuery ? self.ftsMatchQuery(from: q!) : nil

            // Never SELECT image_data in list path.
            var sql: String
            var useFTS = false

            if hasQuery, ftsMatch != nil {
                useFTS = true
                sql = """
                SELECT c.id, c.timestamp, c.type, c.content_hash, c.text_content, c.file_urls, c.url, c.html_content, c.source_app, c.ocr_text
                FROM clipboard_items c
                WHERE c.id IN (
                    SELECT id FROM clipboard_fts WHERE clipboard_fts MATCH ?
                )
                """
                if cursor != nil {
                    sql += " AND (c.timestamp < ? OR (c.timestamp = ? AND c.id < ?))"
                }
                sql += " ORDER BY c.timestamp DESC, c.id DESC LIMIT ?;"
            } else {
                sql = """
                SELECT id, timestamp, type, content_hash, text_content, file_urls, url, html_content, source_app, ocr_text
                FROM clipboard_items
                """
                var whereParts: [String] = []
                if cursor != nil {
                    whereParts.append("(timestamp < ? OR (timestamp = ? AND id < ?))")
                }
                if hasQuery {
                    // Fallback if FTS tokens empty: bounded LIKE (still better than nothing).
                    whereParts.append("(IFNULL(text_content,'') LIKE ? OR IFNULL(ocr_text,'') LIKE ? OR IFNULL(source_app,'') LIKE ? OR IFNULL(html_content,'') LIKE ?)")
                }
                if !whereParts.isEmpty {
                    sql += " WHERE " + whereParts.joined(separator: " AND ")
                }
                sql += " ORDER BY timestamp DESC, id DESC LIMIT ?;"
            }

            var stmt: OpaquePointer?
            var items: [ClipboardItem] = []

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                var bind = 1
                if useFTS, let match = ftsMatch {
                    self.bindText(stmt, Int32(bind), match); bind += 1
                    if let cursor = cursor {
                        sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
                        sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
                        self.bindText(stmt, Int32(bind), cursor.id); bind += 1
                    }
                } else {
                    if let cursor = cursor {
                        sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
                        sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
                        self.bindText(stmt, Int32(bind), cursor.id); bind += 1
                    }
                    if hasQuery, let q = q {
                        let like = "%\(q)%"
                        for _ in 0..<4 {
                            self.bindText(stmt, Int32(bind), like)
                            bind += 1
                        }
                    }
                }
                sqlite3_bind_int(stmt, Int32(bind), Int32(fetchLimit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let item = self.rowToItem(stmt: stmt) {
                        items.append(item)
                    }
                }
                sqlite3_finalize(stmt)
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                print("[DatabaseManager] fetchPage prepare failed: \(msg)")
            }

            var next: ClipCursor? = nil
            if items.count > pageLimit {
                items = Array(items.prefix(pageLimit))
                if let last = items.last {
                    next = ClipCursor(
                        timestamp: last.timestamp.timeIntervalSince1970,
                        id: last.id.uuidString
                    )
                }
            }

            DispatchQueue.main.async {
                completion(ClipPage(items: items, nextCursor: next))
            }
        }
    }

    /// Map a metadata-only SELECT row (no image blob column).
    private func rowToItem(stmt: OpaquePointer?) -> ClipboardItem? {
        guard let stmt = stmt,
              let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let uuid = UUID(uuidString: idStr),
              let typeStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let hash = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) else {
            return nil
        }

        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let textContent = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        // columns: 0 id, 1 ts, 2 type, 3 hash, 4 text, 5 file_urls, 6 url, 7 html, 8 source, 9 ocr
        let htmlContent = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let sourceApp = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let ocrText = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

        return ClipboardItem(
            id: uuid,
            timestamp: timestamp,
            type: ClipboardType(rawValue: typeStr) ?? .text,
            contentHash: hash,
            textContent: textContent,
            imageData: nil,
            htmlContent: htmlContent,
            ocrText: ocrText,
            sourceApp: sourceApp
        )
    }

    func deleteItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        deleteItem(id: item.id, completion: completion)
    }

    func deleteItem(id: UUID, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }

            let sql = "DELETE FROM clipboard_items WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                self.bindText(stmt, 1, id.uuidString)
                let stepRes = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                if stepRes == SQLITE_DONE {
                    self.deleteFTS(id: id.uuidString)
                }
                DispatchQueue.main.async { completion?(stepRes == SQLITE_DONE) }
            } else {
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    func searchItems(query: String, limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        fetchPage(limit: limit, cursor: nil, query: query) { page in
            completion(page.items)
        }
    }

    func fetchImageData(id: UUID, completion: @escaping (Data?) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion(nil); return }
            let sql = "SELECT image_data FROM clipboard_items WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                self.bindText(stmt, 1, id.uuidString)

                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let blobPtr = sqlite3_column_blob(stmt, 0) {
                        let size = sqlite3_column_bytes(stmt, 0)
                        if size > 0 {
                            let data = Data(bytes: blobPtr, count: Int(size))
                            sqlite3_finalize(stmt)
                            DispatchQueue.main.async { completion(data) }
                            return
                        }
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// Batched wipe — avoids one multi-second write lock that starves backup/monitor writers.
    func clearAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }

            var ok = true
            // Clear FTS first (smaller); then base in batches.
            if !self.execQuiet("DELETE FROM clipboard_fts;") {
                ok = false
            }

            let batchSQL = """
            DELETE FROM clipboard_items WHERE id IN (
                SELECT id FROM clipboard_items LIMIT \(Self.deleteBatchSize)
            );
            """
            var guardLoops = 0
            while ok && guardLoops < 1_000_000 {
                guardLoops += 1
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, batchSQL, nil, nil, &err)
                if rc != SQLITE_OK {
                    let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
                    if let err { sqlite3_free(err) }
                    print("[DatabaseManager] clearAll batch error: \(msg)")
                    ok = false
                    break
                }
                let changed = sqlite3_changes(db)
                if changed == 0 { break }
            }

            self.execQuiet("PRAGMA wal_checkpoint(PASSIVE);")
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    // MARK: - Online backup / restore (sqlite3_backup)

    enum DBFileError: LocalizedError {
        case notOpen
        case openFailed(String)
        case backupFailed(String)
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .notOpen: return "数据库未打开"
            case .openFailed(let s): return "打开失败: \(s)"
            case .backupFailed(let s): return "备份失败: \(s)"
            case .replaceFailed(let s): return "替换失败: \(s)"
            }
        }
    }

    /// Consistent online backup via sqlite3_backup API (safe while readers/writers active).
    func onlineBackup(to destURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let src = self.db else {
                completion(.failure(DBFileError.notOpen))
                return
            }
            try? FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }

            var dest: OpaquePointer?
            if sqlite3_open(destURL.path, &dest) != SQLITE_OK {
                let msg = dest.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                if let dest { sqlite3_close(dest) }
                completion(.failure(DBFileError.openFailed(msg)))
                return
            }
            guard let destDB = dest else {
                completion(.failure(DBFileError.openFailed("nil handle")))
                return
            }

            guard let backup = sqlite3_backup_init(destDB, "main", src, "main") else {
                let msg = String(cString: sqlite3_errmsg(destDB))
                sqlite3_close(destDB)
                completion(.failure(DBFileError.backupFailed(msg)))
                return
            }

            var rc: Int32 = SQLITE_OK
            repeat {
                rc = sqlite3_backup_step(backup, 64)
                if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                    sqlite3_sleep(25)
                    continue
                }
            } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED

            let finishRC = sqlite3_backup_finish(backup)
            if rc != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(destDB))
                sqlite3_close(destDB)
                try? FileManager.default.removeItem(at: destURL)
                completion(.failure(DBFileError.backupFailed("step=\(rc) finish=\(finishRC) \(msg)")))
                return
            }
            sqlite3_exec(destDB, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
            sqlite3_close(destDB)
            completion(.success(()))
        }
    }

    func itemCount(completion: @escaping (Int) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                completion(0)
                return
            }
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clipboard_items;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int64(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
            completion(count)
            _ = db
        }
    }

    /// Close live handle, replace file, reopen. Used by CloudDocs restore.
    func replaceDatabaseFile(with sourceURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                completion(.failure(DBFileError.notOpen))
                return
            }
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                completion(.failure(DBFileError.replaceFailed("source missing")))
                return
            }

            if let db = self.db {
                self.runOptimize()
                sqlite3_close(db)
                self.db = nil
            }

            let dest = self.dbPath
            let bak = dest.deletingLastPathComponent().appendingPathComponent("clipflow.pre-restore.db")
            do {
                if FileManager.default.fileExists(atPath: bak.path) {
                    try FileManager.default.removeItem(at: bak)
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.moveItem(at: dest, to: bak)
                }
                for ext in ["-wal", "-shm"] {
                    let side = URL(fileURLWithPath: dest.path + ext)
                    try? FileManager.default.removeItem(at: side)
                }
                try FileManager.default.copyItem(at: sourceURL, to: dest)
            } catch {
                _ = self.openAndConfigure()
                completion(.failure(DBFileError.replaceFailed(error.localizedDescription)))
                return
            }

            if !self.openAndConfigure() {
                let msg = self.db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "reopen failed"
                completion(.failure(DBFileError.openFailed(msg)))
                return
            }
            self.createTables()
            self.bootstrapFTSIfNeeded()
            self.runAnalyze()
            completion(.success(()))
        }
    }

    deinit {
        optimizeTimer?.cancel()
        optimizeTimer = nil
        if let db = db {
            // Best-effort; deinit may not be on dbQueue.
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
        }
    }
}
