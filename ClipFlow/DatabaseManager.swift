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

    func encode() -> String { "\(timestamp):\(id)" }

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

/// SQLite store for Keepsake.
/// Runtime: `sqlite-runtime-tricks` — WAL, busy_timeout, ANALYZE, FTS5 trigram,
/// latest-alive upsert by content_hash, **periodic batched** dupe cleanup, online backup.
final class DatabaseManager: ObservableObject {
    private let dbPath: URL
    private let dbQueue = DispatchQueue(label: "com.clipflow.database", qos: .userInitiated)
    private var db: OpaquePointer?
    private var maintenanceTimer: DispatchSourceTimer?

    private static let deleteBatchSize = 500
    /// Per maintenance tick: max stale rows removed (jvns: short writer batches).
    private static let dedupeBatchSize = 50
    /// How often to run light maintenance (dedupe batch + orphan FTS).
    private static let maintenanceIntervalSeconds: Double = 10 * 60
    /// Heavy optimize cadence (also runs on some maintenance ticks).
    private static let optimizeEveryNMaintenances = 36 // ~6h at 10min
    private var maintenanceTicks = 0

    /// Active FTS tokenizer: "trigram" (fuzzy substring) or "unicode61".
    private var ftsTokenizer: String = "unicode61"

    init() {
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory.appendingPathComponent("com.clipflow.app")
        let appDir = docsDir.appendingPathComponent("ClipFlow")

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("clipflow.db")

        initializeDatabase()
        startMaintenanceTimer()
    }

    var dbFileURL: URL { dbPath }

    // MARK: - Open / pragmas / schema

    private func initializeDatabase() {
        if openAndConfigure() {
            createTables()
            migrateSchema()
            bootstrapFTSIfNeeded()
            runAnalyze()
            // Drain residual dups after boot in short batches (not one giant DELETE).
            dbQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.drainDuplicates(maxBatches: 40)
            }
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

    private func applyConnectionPragmas() {
        guard db != nil else { return }
        execQuiet("PRAGMA journal_mode=WAL;")
        execQuiet("PRAGMA synchronous=NORMAL;")
        execQuiet("PRAGMA busy_timeout=5000;")
        execQuiet("PRAGMA temp_store=MEMORY;")
        execQuiet("PRAGMA foreign_keys=ON;")
        execQuiet("PRAGMA mmap_size=268435456;")
        execQuiet("PRAGMA cache_size=-64000;")
        execQuiet("PRAGMA wal_autocheckpoint=1000;")
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
        CREATE TABLE IF NOT EXISTS keepsake_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp);
        CREATE INDEX IF NOT EXISTS idx_ts_id ON clipboard_items(timestamp DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash);
        """
        execQuiet(createSQL)
    }

    private func migrateSchema() {
        // copy_count: how many times this exact content was re-copied (latest-alive).
        if !columnExists("clipboard_items", "copy_count") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN copy_count INTEGER NOT NULL DEFAULT 1;")
        }
    }

    private func columnExists(_ table: String, _ column: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }), name == column {
                return true
            }
        }
        return false
    }

    private func metaGet(_ key: String) -> String? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, "SELECT value FROM keepsake_meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    private func metaSet(_ key: String, _ value: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "INSERT INTO keepsake_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            -1, &stmt, nil
        ) == SQLITE_OK {
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - FTS (trigram when available → substring / fuzzy)

    private func probeTrigramSupport() -> Bool {
        guard let db = db else { return false }
        // Temp virtual table; drop immediately.
        var err: UnsafeMutablePointer<CChar>?
        let create = "CREATE VIRTUAL TABLE IF NOT EXISTS _keepsake_trigram_probe USING fts5(x, tokenize='trigram');"
        let rc = sqlite3_exec(db, create, nil, nil, &err)
        if let err { sqlite3_free(err) }
        sqlite3_exec(db, "DROP TABLE IF EXISTS _keepsake_trigram_probe;", nil, nil, nil)
        return rc == SQLITE_OK
    }

    private func bootstrapFTSIfNeeded() {
        guard db != nil else { return }

        let wantTrigram = probeTrigramSupport()
        let target = wantTrigram ? "trigram" : "unicode61"
        let stored = metaGet("fts_tokenizer")
        let ftsExists = tableExists("clipboard_fts")

        let needRebuild = !ftsExists || stored != target
        if needRebuild {
            if ftsExists {
                execQuiet("DROP TABLE IF EXISTS clipboard_fts;")
                print("[DatabaseManager] Rebuilding FTS with tokenizer=\(target)")
            }
            let tokClause = target == "trigram"
                ? "tokenize = 'trigram'"
                : "tokenize = 'unicode61 remove_diacritics 2'"
            let ftsSQL = """
            CREATE VIRTUAL TABLE clipboard_fts USING fts5(
                id UNINDEXED,
                text_content,
                ocr_text,
                source_app,
                html_content,
                \(tokClause)
            );
            """
            if execQuiet(ftsSQL) {
                metaSet("fts_tokenizer", target)
                ftsTokenizer = target
                backfillFTS()
            }
        } else {
            ftsTokenizer = target
            // Backfill if empty but base has rows
            let ftsCount = scalarInt64("SELECT COUNT(*) FROM clipboard_fts;") ?? 0
            let baseCount = scalarInt64("SELECT COUNT(*) FROM clipboard_items;") ?? 0
            if ftsCount == 0 && baseCount > 0 {
                backfillFTS()
            }
        }
    }

    private func tableExists(_ name: String) -> Bool {
        let n = name.replacingOccurrences(of: "'", with: "''")
        return (scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table','view') AND name='\(n)';") ?? 0) > 0
    }

    private func backfillFTS() {
        let backfill = """
        INSERT INTO clipboard_fts(id, text_content, ocr_text, source_app, html_content)
        SELECT id,
               IFNULL(text_content,''),
               IFNULL(ocr_text,''),
               IFNULL(source_app,''),
               IFNULL(html_content,'')
        FROM clipboard_items;
        """
        if execQuiet(backfill) {
            let n = scalarInt64("SELECT COUNT(*) FROM clipboard_fts;") ?? 0
            print("[DatabaseManager] FTS5 backfill: \(n) rows tokenizer=\(ftsTokenizer)")
        }
    }

    private func runAnalyze() { execQuiet("ANALYZE;") }
    private func runOptimize() { execQuiet("PRAGMA optimize;") }

    private func startMaintenanceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: dbQueue)
        timer.schedule(
            deadline: .now() + Self.maintenanceIntervalSeconds,
            repeating: Self.maintenanceIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.runMaintenanceTick(forceOptimize: false)
        }
        timer.resume()
        maintenanceTimer = timer
    }

    /// Periodic work: batched latest-alive collapse + FTS orphan prune + optional optimize.
    /// Never deletes the whole table in one shot (sqlite-runtime-tricks §3).
    private func runMaintenanceTick(forceOptimize: Bool) {
        guard db != nil else { return }
        maintenanceTicks += 1

        let removed = drainDuplicates(maxBatches: 4)
        if removed > 0 {
            print("[DatabaseManager] maintenance: dedupe_removed=\(removed)")
        }

        // Passive WAL checkpoint every tick (cheap).
        execQuiet("PRAGMA wal_checkpoint(PASSIVE);")

        if forceOptimize || maintenanceTicks % Self.optimizeEveryNMaintenances == 0 {
            runOptimize()
            // Occasional FTS optimize (merge segments) — also batched by SQLite internally.
            execQuiet("INSERT INTO clipboard_fts(clipboard_fts) VALUES('optimize');")
            runAnalyze()
        }
    }

    /// Run up to `maxBatches` short DELETE batches until no more stale dups.
    @discardableResult
    private func drainDuplicates(maxBatches: Int) -> Int {
        var total = 0
        for _ in 0..<maxBatches {
            let n = dedupeStaleBatch(limit: Self.dedupeBatchSize)
            total += n
            if n == 0 { break }
            // FTS orphans for this batch
            _ = pruneOrphanFTS(limit: Self.dedupeBatchSize)
        }
        if total > 0 {
            print("[DatabaseManager] drainDuplicates total=\(total)")
        }
        return total
    }

    /// Keep only the newest row per content_hash; delete up to `limit` losers this tick.
    @discardableResult
    private func dedupeStaleBatch(limit: Int) -> Int {
        guard let db = db, limit > 0 else { return 0 }
        // Loser = exists another row with same hash that is strictly newer, or same ts with larger id.
        let sql = """
        DELETE FROM clipboard_items
        WHERE id IN (
            SELECT c.id
            FROM clipboard_items c
            WHERE EXISTS (
                SELECT 1 FROM clipboard_items k
                WHERE k.content_hash = c.content_hash
                  AND (
                    k.timestamp > c.timestamp
                    OR (k.timestamp = c.timestamp AND k.id > c.id)
                  )
            )
            LIMIT \(limit)
        );
        """
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            if let err { sqlite3_free(err) }
            print("[DatabaseManager] dedupe batch error: \(msg)")
            return 0
        }
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    private func pruneOrphanFTS(limit: Int) -> Int {
        guard let db = db, limit > 0 else { return 0 }
        let sql = """
        DELETE FROM clipboard_fts WHERE id IN (
            SELECT f.id FROM clipboard_fts f
            WHERE NOT EXISTS (SELECT 1 FROM clipboard_items c WHERE c.id = f.id)
            LIMIT \(limit)
        );
        """
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            if let err { sqlite3_free(err) }
            return 0
        }
        return Int(sqlite3_changes(db))
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
            print("[DatabaseManager] SQL error: \(msg) | \(sql.prefix(140))")
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

    private func findIdByContentHash(_ hash: String) -> String? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        // Prefer newest if residual dups exist before cleanup drains them.
        let sql = "SELECT id FROM clipboard_items WHERE content_hash = ? ORDER BY timestamp DESC, id DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bindText(stmt, 1, hash)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    private func upsertFTS(id: String, text: String?, ocr: String?, source: String?, html: String?) {
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

    /// FTS5 MATCH string. Trigram: substring-friendly phrase. unicode61: prefix tokens.
    private func ftsMatchQuery(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if ftsTokenizer == "trigram" {
            // Trigram needs ≥3 chars for matches; escape double quotes.
            guard trimmed.count >= 3 else { return nil }
            let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

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
        return tokens.map { tok -> String in
            let isAscii = tok.unicodeScalars.allSatisfy { $0.isASCII }
            if isAscii { return "\(tok)*" }
            return "\"\(tok.replacingOccurrences(of: "\"", with: ""))\""
        }.joined(separator: " ")
    }

    // MARK: - CRUD (latest-alive)

    /// Insert new content, or **bump** existing same `content_hash` to newest (no new row).
    func saveItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }

            if let existingId = self.findIdByContentHash(item.contentHash) {
                let ok = self.bumpLatestAlive(
                    id: existingId,
                    item: item
                )
                DispatchQueue.main.async { completion?(ok) }
                return
            }

            let ok = self.insertNewItem(item, db: db)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// Same content re-copied: keep one row, refresh timestamp / source / count; keep stable id.
    private func bumpLatestAlive(id: String, item: ClipboardItem) -> Bool {
        guard let db = db else { return false }
        // Optionally refresh text/ocr/source if new capture has richer fields (same hash ⇒ body same).
        let sql = """
        UPDATE clipboard_items SET
            timestamp = ?,
            source_app = COALESCE(?, source_app),
            copy_count = COALESCE(copy_count, 1) + 1
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_double(stmt, 1, item.timestamp.timeIntervalSince1970)
        bindText(stmt, 2, item.sourceApp)
        bindText(stmt, 3, id)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        // FTS body unchanged for same hash — no FTS rewrite needed.
        return rc == SQLITE_DONE
    }

    private func insertNewItem(_ item: ClipboardItem, db: OpaquePointer) -> Bool {
        let sql = """
        INSERT INTO clipboard_items
        (id, timestamp, type, content_hash, text_content, image_data, file_urls, url, rtf_data, pdf_data, html_content, raw_data, source_app, ocr_text, copy_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }

        let idStr = item.id.uuidString
        bindText(stmt, 1, idStr)
        sqlite3_bind_double(stmt, 2, item.timestamp.timeIntervalSince1970)
        bindText(stmt, 3, item.type.rawValue)
        bindText(stmt, 4, item.contentHash)

        if let text = item.textContent { bindText(stmt, 5, text) } else { sqlite3_bind_null(stmt, 5) }

        if let imgData = item.imageData {
            imgData.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(imgData.count), Self.SQLITE_TRANSIENT)
            }
        } else { sqlite3_bind_null(stmt, 6) }

        let fileURLsStr = item.fileURLs?.map { $0.path }.joined(separator: "|")
        if let fUrls = fileURLsStr { bindText(stmt, 7, fUrls) } else { sqlite3_bind_null(stmt, 7) }

        if let urlStr = item.url?.absoluteString { bindText(stmt, 8, urlStr) } else { sqlite3_bind_null(stmt, 8) }

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

        if let html = item.htmlContent { bindText(stmt, 11, html) } else { sqlite3_bind_null(stmt, 11) }
        sqlite3_bind_null(stmt, 12)
        if let srcApp = item.sourceApp { bindText(stmt, 13, srcApp) } else { sqlite3_bind_null(stmt, 13) }
        if let ocr = item.ocrText { bindText(stmt, 14, ocr) } else { sqlite3_bind_null(stmt, 14) }

        let stepRes = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard stepRes == SQLITE_DONE else { return false }

        upsertFTS(
            id: idStr,
            text: item.textContent,
            ocr: item.ocrText,
            source: item.sourceApp,
            html: item.htmlContent
        )
        return true
    }

    func fetchItems(limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        fetchPage(limit: limit, cursor: nil, query: nil) { page in
            completion(page.items)
        }
    }

    /// Keyset pagination. Search: FTS5 (trigram substring when available) → LIKE fallback.
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
            let fetchLimit = pageLimit + 1
            let q = query?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasQuery = !(q ?? "").isEmpty
            let ftsMatch = hasQuery ? self.ftsMatchQuery(from: q!) : nil

            var items: [ClipboardItem] = []

            if hasQuery, let match = ftsMatch {
                items = self.runSearchFTS(db: db, match: match, cursor: cursor, fetchLimit: fetchLimit)
                // Hybrid: if FTS empty (e.g. odd tokens), fall back to LIKE once.
                if items.isEmpty {
                    items = self.runSearchLike(db: db, q: q!, cursor: cursor, fetchLimit: fetchLimit)
                }
            } else if hasQuery, let q = q {
                // Short query (<3) with trigram: LIKE path.
                items = self.runSearchLike(db: db, q: q, cursor: cursor, fetchLimit: fetchLimit)
            } else {
                items = self.runList(db: db, cursor: cursor, fetchLimit: fetchLimit)
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

    private func runSearchFTS(
        db: OpaquePointer,
        match: String,
        cursor: ClipCursor?,
        fetchLimit: Int
    ) -> [ClipboardItem] {
        // bm25 rank when available; stable secondary sort by time.
        var sql = """
        SELECT c.id, c.timestamp, c.type, c.content_hash, c.text_content, c.file_urls, c.url, c.html_content, c.source_app, c.ocr_text
        FROM clipboard_fts f
        JOIN clipboard_items c ON c.id = f.id
        WHERE clipboard_fts MATCH ?
        """
        if cursor != nil {
            sql += " AND (c.timestamp < ? OR (c.timestamp = ? AND c.id < ?))"
        }
        sql += " ORDER BY bm25(clipboard_fts), c.timestamp DESC, c.id DESC LIMIT ?;"

        var stmt: OpaquePointer?
        var items: [ClipboardItem] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            print("[DatabaseManager] FTS prepare failed: \(msg)")
            return []
        }
        var bind = 1
        bindText(stmt, Int32(bind), match); bind += 1
        if let cursor = cursor {
            sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
            sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
            bindText(stmt, Int32(bind), cursor.id); bind += 1
        }
        sqlite3_bind_int(stmt, Int32(bind), Int32(fetchLimit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = rowToItem(stmt: stmt) { items.append(item) }
        }
        sqlite3_finalize(stmt)
        return items
    }

    private func runSearchLike(
        db: OpaquePointer,
        q: String,
        cursor: ClipCursor?,
        fetchLimit: Int
    ) -> [ClipboardItem] {
        var sql = """
        SELECT id, timestamp, type, content_hash, text_content, file_urls, url, html_content, source_app, ocr_text
        FROM clipboard_items
        WHERE (IFNULL(text_content,'') LIKE ? OR IFNULL(ocr_text,'') LIKE ? OR IFNULL(source_app,'') LIKE ? OR IFNULL(html_content,'') LIKE ?)
        """
        if cursor != nil {
            sql += " AND (timestamp < ? OR (timestamp = ? AND id < ?))"
        }
        sql += " ORDER BY timestamp DESC, id DESC LIMIT ?;"

        var stmt: OpaquePointer?
        var items: [ClipboardItem] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bind = 1
        let like = "%\(q)%"
        for _ in 0..<4 {
            bindText(stmt, Int32(bind), like); bind += 1
        }
        if let cursor = cursor {
            sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
            sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
            bindText(stmt, Int32(bind), cursor.id); bind += 1
        }
        sqlite3_bind_int(stmt, Int32(bind), Int32(fetchLimit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = rowToItem(stmt: stmt) { items.append(item) }
        }
        sqlite3_finalize(stmt)
        return items
    }

    private func runList(db: OpaquePointer, cursor: ClipCursor?, fetchLimit: Int) -> [ClipboardItem] {
        var sql = """
        SELECT id, timestamp, type, content_hash, text_content, file_urls, url, html_content, source_app, ocr_text
        FROM clipboard_items
        """
        if cursor != nil {
            sql += " WHERE (timestamp < ? OR (timestamp = ? AND id < ?))"
        }
        sql += " ORDER BY timestamp DESC, id DESC LIMIT ?;"

        var stmt: OpaquePointer?
        var items: [ClipboardItem] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bind = 1
        if let cursor = cursor {
            sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
            sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
            bindText(stmt, Int32(bind), cursor.id); bind += 1
        }
        sqlite3_bind_int(stmt, Int32(bind), Int32(fetchLimit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = rowToItem(stmt: stmt) { items.append(item) }
        }
        sqlite3_finalize(stmt)
        return items
    }

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

    /// Batched wipe — short writer batches only.
    func clearAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }

            var ok = true
            if !self.execQuiet("DELETE FROM clipboard_fts;") { ok = false }

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
                if sqlite3_changes(db) == 0 { break }
            }

            self.execQuiet("PRAGMA wal_checkpoint(PASSIVE);")
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    // MARK: - Online backup / restore

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
            self.migrateSchema()
            self.bootstrapFTSIfNeeded()
            self.runAnalyze()
            completion(.success(()))
        }
    }

    deinit {
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        if let db = db {
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
        }
    }
}
