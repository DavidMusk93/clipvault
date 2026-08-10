import Foundation
import SQLite3

enum DatabaseError: Error {
    case connectionFailed
    case statementFailed(String)
    case queryFailed(String)
}

/// Cursor for keyset pagination: (timestamp DESC, id DESC).
///
/// Wire format: `{hex(Double.bitPattern)}:{uuid}` so the timestamp round-trips **bit-exact**
/// through JSON/URL. Default `"\(double)"` / short decimal forms can round **up** and make
/// `timestamp < ?` re-include the previous page's last row (first-scroll duplicates).
struct ClipCursor: Equatable {
    let timestamp: Double
    let id: String

    func encode() -> String {
        let bits = String(timestamp.bitPattern, radix: 16)
        return "\(bits):\(id)"
    }

    static func decode(_ raw: String) -> ClipCursor? {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let id = parts[1]
        // Preferred: hex IEEE-754 bits
        if let bits = UInt64(parts[0], radix: 16) {
            return ClipCursor(timestamp: Double(bitPattern: bits), id: id)
        }
        // Backward compat: legacy decimal timestamp strings
        guard let ts = Double(parts[0]) else { return nil }
        return ClipCursor(timestamp: ts, id: id)
    }
}

struct ClipPage {
    let items: [ClipboardItem]
    let nextCursor: ClipCursor?
}

/// SQLite store for ClipVault.
/// Runtime: `sqlite-runtime-tricks` — WAL, busy_timeout, ANALYZE, FTS5 trigram,
/// latest-alive upsert by content_hash, **periodic batched** dupe cleanup, online backup.
final class DatabaseManager: ObservableObject {
    private let appDir: URL
    private let dbPath: URL
    /// Content-addressed blob store: `blobs/{content_hash}.bin` (images/pdf/rtf out of SQLite).
    private let blobsDir: URL
    private let dbQueue = DispatchQueue(label: "com.clipflow.database", qos: .userInitiated)
    private var db: OpaquePointer?
    private var maintenanceTimer: DispatchSourceTimer?
    private let fm = FileManager.default

    private static let deleteBatchSize = 500
    /// Per maintenance tick: max stale rows removed (jvns: short writer batches).
    private static let dedupeBatchSize = 50
    /// How often to run light maintenance (dedupe batch + orphan FTS).
    private static let maintenanceIntervalSeconds: Double = 10 * 60
    /// Heavy optimize cadence (also runs on some maintenance ticks).
    private static let optimizeEveryNMaintenances = 36 // ~6h at 10min
    /// Inline BLOB larger than this is written to CAS and nulled in SQLite.
    private static let inlineBlobMaxBytes = 0 // always externalize image/pdf/rtf payloads
    private var maintenanceTicks = 0

    /// Active FTS tokenizer: "trigram" (fuzzy substring) or "unicode61".
    private var ftsTokenizer: String = "unicode61"

    init() {
        appDir = Self.resolveDataRoot()
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("clipflow.db")
        blobsDir = appDir.appendingPathComponent("blobs", isDirectory: true)
        try? fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appDir.appendingPathComponent("config", isDirectory: true), withIntermediateDirectories: true)
        try? fm.createDirectory(at: appDir.appendingPathComponent("logs", isDirectory: true), withIntermediateDirectories: true)
        print("[Database] data root: \(appDir.path)")

        initializeDatabase()
        startMaintenanceTimer()
    }

    /// Local data root (db + CAS blobs + config).
    /// - `CLIPVAULT_HOME` or legacy `KEEPSAKE_HOME` env wins (recommended for LaunchAgent).
    /// - Under launchd (`XPC_SERVICE_NAME`): always Application Support — macOS TCC
    ///   blocks Documents for agents and can hang forever on `sqlite3_open`.
    /// - Interactive shell: prefer existing `~/Documents/ClipFlow` for backward compat,
    ///   else Application Support (`~/Library/Application Support/Keepsake` — legacy folder name; product brand is ClipVault).
    static func resolveDataRoot() -> URL {
        let fm = FileManager.default
        if let raw = (ProcessInfo.processInfo.environment["CLIPVAULT_HOME"]
            ?? ProcessInfo.processInfo.environment["KEEPSAKE_HOME"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Keepsake", isDirectory: true)
        let underLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != nil
        if underLaunchd {
            return appSupport
        }
        let docs = (fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
            .appendingPathComponent("ClipFlow", isDirectory: true)
        if fm.fileExists(atPath: docs.appendingPathComponent("clipflow.db").path) {
            return docs
        }
        return appSupport
    }

    var dbFileURL: URL { dbPath }
    /// Public for CloudDocs backup CAS sync.
    var blobsDirectoryURL: URL { blobsDir }

    // MARK: - Content-addressed blobs (sqlite skill §6)

    func blobFileURL(hash: String) -> URL {
        blobsDir.appendingPathComponent(hash + ".bin")
    }

    @discardableResult
    func writeBlobFile(hash: String, data: Data) -> Bool {
        let url = blobFileURL(hash: hash)
        if fm.fileExists(atPath: url.path) { return true }
        do {
            try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[DatabaseManager] blob write failed: \(error)")
            return false
        }
    }

    func readBlobFile(hash: String) -> Data? {
        let url = blobFileURL(hash: hash)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Import a blob from backup CAS into local store (restore path).
    func importBlobIfNeeded(hash: String, from source: URL) {
        let dest = blobFileURL(hash: hash)
        if fm.fileExists(atPath: dest.path) { return }
        try? fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: dest)
    }

    // MARK: - Open / pragmas / schema

    private func initializeDatabase() {
        if openAndConfigure() {
            createTables()
            migrateSchema()
            bootstrapFTSIfNeeded()
            runAnalyze()
            // Blob peel + VACUUM off critical path (VACUUM on 40MB+ can block boot for minutes).
            dbQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                self.migrateInlineBlobsToFiles(maxBatches: 200)
                self.maybeVacuumAfterBlobMigration()
                self.drainDuplicates(maxBatches: 40)
                // Undo any substr_fold soft-deletes (feature removed — too aggressive).
                let restored = self.restoreSubstrFoldVictims(limit: 5000)
                if restored > 0 {
                    print("[DatabaseManager] restored substr_fold victims=\(restored)")
                }
                self.runAnalyze()
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
        CREATE TABLE IF NOT EXISTS clipboard_events (
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            event_ts REAL NOT NULL,
            type TEXT NOT NULL,
            source_app TEXT,
            kind TEXT NOT NULL DEFAULT 'capture',
            detail TEXT
        );
        CREATE TABLE IF NOT EXISTS operation_logs (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            action TEXT NOT NULL,
            item_id TEXT,
            content_hash TEXT,
            detail TEXT,
            source TEXT NOT NULL DEFAULT 'system'
        );
        CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp);
        CREATE INDEX IF NOT EXISTS idx_ts_id ON clipboard_items(timestamp DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash);
        CREATE INDEX IF NOT EXISTS idx_events_hash_ts ON clipboard_events(content_hash, event_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_item_ts ON clipboard_events(item_id, event_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_ts ON clipboard_events(event_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_oplogs_ts ON operation_logs(ts DESC);
        """
        execQuiet(createSQL)
    }

    /// Soft-delete TTL (seconds). Default 30 days.
    private static let trashTTLSeconds: Double = 30 * 24 * 3600

    private func migrateSchema() {
        // copy_count: how many times this exact content was re-copied (latest-alive).
        if !columnExists("clipboard_items", "copy_count") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN copy_count INTEGER NOT NULL DEFAULT 1;")
        }
        if !columnExists("clipboard_items", "deleted_at") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN deleted_at REAL;")
        }
        if !columnExists("clipboard_items", "first_seen_at") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN first_seen_at REAL;")
            // Backfill from timestamp for existing rows.
            execQuiet("UPDATE clipboard_items SET first_seen_at = timestamp WHERE first_seen_at IS NULL;")
        }
        if !columnExists("clipboard_events", "detail") {
            execQuiet("ALTER TABLE clipboard_events ADD COLUMN detail TEXT;")
        }
        // User judgment projections (payload remains immutable — see applyUserContext).
        if !columnExists("clipboard_items", "user_note") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN user_note TEXT;")
        }
        if !columnExists("clipboard_items", "user_stage") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN user_stage TEXT;")
        }
        if !columnExists("clipboard_items", "user_rating") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN user_rating INTEGER;")
        }
        if !columnExists("clipboard_items", "user_context_updated_at") {
            execQuiet("ALTER TABLE clipboard_items ADD COLUMN user_context_updated_at REAL;")
        }
        // Append-only user evaluations (each submit = one history row).
        execQuiet("""
        CREATE TABLE IF NOT EXISTS user_evaluations (
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL,
            content_hash TEXT,
            ts REAL NOT NULL,
            rating INTEGER,
            note TEXT,
            source TEXT NOT NULL DEFAULT 'web'
        );
        CREATE INDEX IF NOT EXISTS idx_eval_item_ts ON user_evaluations(item_id, ts DESC);
        """)
        // Ensure aux tables exist on upgraded DBs.
        execQuiet("""
        CREATE TABLE IF NOT EXISTS clipboard_events (
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            event_ts REAL NOT NULL,
            type TEXT NOT NULL,
            source_app TEXT,
            kind TEXT NOT NULL DEFAULT 'capture',
            detail TEXT
        );
        CREATE TABLE IF NOT EXISTS operation_logs (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            action TEXT NOT NULL,
            item_id TEXT,
            content_hash TEXT,
            detail TEXT,
            source TEXT NOT NULL DEFAULT 'system'
        );
        CREATE INDEX IF NOT EXISTS idx_events_hash_ts ON clipboard_events(content_hash, event_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_item_ts ON clipboard_events(item_id, event_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_ts ON clipboard_events(event_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_oplogs_ts ON operation_logs(ts DESC);
        CREATE INDEX IF NOT EXISTS idx_deleted_at ON clipboard_items(deleted_at);
        """)
        // Bootstrap events for existing items that have no history yet (one seed event).
        execQuiet("""
        INSERT INTO clipboard_events (id, item_id, content_hash, event_ts, type, source_app, kind)
        SELECT lower(hex(randomblob(16))), c.id, c.content_hash, c.timestamp, c.type, c.source_app, 'seed'
        FROM clipboard_items c
        WHERE NOT EXISTS (SELECT 1 FROM clipboard_events e WHERE e.item_id = c.id)
        LIMIT 5000;
        """)
    }

    /// Pull image/pdf/rtf out of SQLite into `blobs/{hash}.bin` (content-addressed).
    @discardableResult
    private func migrateInlineBlobsToFiles(maxBatches: Int) -> Int {
        guard db != nil else { return 0 }
        var total = 0
        for _ in 0..<maxBatches {
            let n = migrateInlineBlobsBatch(limit: 8)
            total += n
            if n == 0 { break }
        }
        if total > 0 {
            print("[DatabaseManager] migrated \(total) inline BLOBs → \(blobsDir.path)")
        }
        return total
    }

    private func migrateInlineBlobsBatch(limit: Int) -> Int {
        guard let db = db else { return 0 }
        // Prefer images (dominant size); also peel pdf/rtf.
        let sql = """
        SELECT id, content_hash, image_data, rtf_data, pdf_data FROM clipboard_items
        WHERE (image_data IS NOT NULL AND length(image_data) > 0)
           OR (rtf_data IS NOT NULL AND length(rtf_data) > 0)
           OR (pdf_data IS NOT NULL AND length(pdf_data) > 0)
        LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var ids: [(String, String, Data?, Data?, Data?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let hash = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) else { continue }
            var img: Data?
            var rtf: Data?
            var pdf: Data?
            if let p = sqlite3_column_blob(stmt, 2) {
                let n = Int(sqlite3_column_bytes(stmt, 2))
                if n > 0 { img = Data(bytes: p, count: n) }
            }
            if let p = sqlite3_column_blob(stmt, 3) {
                let n = Int(sqlite3_column_bytes(stmt, 3))
                if n > 0 { rtf = Data(bytes: p, count: n) }
            }
            if let p = sqlite3_column_blob(stmt, 4) {
                let n = Int(sqlite3_column_bytes(stmt, 4))
                if n > 0 { pdf = Data(bytes: p, count: n) }
            }
            ids.append((id, hash, img, rtf, pdf))
        }
        sqlite3_finalize(stmt)

        var done = 0
        for (id, hash, img, rtf, pdf) in ids {
            // Primary payload for images is content_hash-named; rtf/pdf use suffix keys.
            if let img = img {
                _ = writeBlobFile(hash: hash, data: img)
            }
            if let rtf = rtf {
                _ = writeBlobFile(hash: hash + ".rtf", data: rtf)
            }
            if let pdf = pdf {
                _ = writeBlobFile(hash: hash + ".pdf", data: pdf)
            }
            let upd = """
            UPDATE clipboard_items SET
              image_data = NULL,
              rtf_data = CASE WHEN rtf_data IS NOT NULL THEN NULL ELSE rtf_data END,
              pdf_data = CASE WHEN pdf_data IS NOT NULL THEN NULL ELSE pdf_data END
            WHERE id = ?;
            """
            // Always null the large columns we externalized
            let upd2 = "UPDATE clipboard_items SET image_data=NULL, rtf_data=NULL, pdf_data=NULL WHERE id=?;"
            var u: OpaquePointer?
            if sqlite3_prepare_v2(db, upd2, -1, &u, nil) == SQLITE_OK {
                bindText(u, 1, id)
                if sqlite3_step(u) == SQLITE_DONE { done += 1 }
            }
            sqlite3_finalize(u)
            _ = upd
        }
        return done
    }

    private func maybeVacuumAfterBlobMigration() {
        let remaining = scalarInt64("""
            SELECT COUNT(*) FROM clipboard_items
            WHERE (image_data IS NOT NULL AND length(image_data)>0)
               OR (rtf_data IS NOT NULL AND length(rtf_data)>0)
               OR (pdf_data IS NOT NULL AND length(pdf_data)>0);
            """) ?? 0
        guard remaining == 0 else { return }

        // Re-VACUUM if file still fat (interrupted vacuum / freelist not reclaimed).
        let pages = scalarInt64("PRAGMA page_count;") ?? 0
        let pageSize = scalarInt64("PRAGMA page_size;") ?? 4096
        let bytes = pages * pageSize
        let already = metaGet("blob_vacuum_v1") == "1"
        if already && bytes < 2_000_000 { return }

        print("[DatabaseManager] VACUUM after blob externalization (pages=\(pages) ~\(bytes / 1024)KB)…")
        if execQuiet("VACUUM;") {
            metaSet("blob_vacuum_v1", "1")
            let pages2 = scalarInt64("PRAGMA page_count;") ?? 0
            print("[DatabaseManager] VACUUM done pages=\(pages2)")
        }
    }

    /// List content hashes that still have a local blob file (for backup CAS sync).
    func listLocalBlobHashes() -> [String] {
        guard let files = try? fm.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard name.hasSuffix(".bin") else { return nil }
            return String(name.dropLast(4))
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

        let purged = purgeExpiredTrash(limit: Self.deleteBatchSize)
        if purged > 0 {
            print("[DatabaseManager] maintenance: trash_purged=\(purged)")
        }
        _ = pruneOperationLogs(maxAgeDays: 90, limit: 500)

        // Passive WAL checkpoint every tick (cheap).
        execQuiet("PRAGMA wal_checkpoint(PASSIVE);")

        // Keep peeling any residual inline BLOBs (new code paths should not insert them).
        _ = migrateInlineBlobsBatch(limit: 4)
        maybeVacuumAfterBlobMigration()

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
        // Prefer alive row; fall back to any (bump restores soft-deleted).
        let sql = "SELECT id FROM clipboard_items WHERE content_hash = ? ORDER BY CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END, timestamp DESC, id DESC LIMIT 1;"
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

    /// Outcome of a local capture write (for multi-device op-log).
    enum ItemSaveResult: Equatable {
        case failed
        case inserted
        case bumped(existingId: UUID)
    }

    /// Insert new content, or **bump** existing same `content_hash` to newest (no new row).
    func saveItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        saveItemDetailed(item) { result in
            completion?(result != .failed)
        }
    }

    func saveItemDetailed(_ item: ClipboardItem, completion: ((ItemSaveResult) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion?(.failed) }
                return
            }

            if let existingId = self.findIdByContentHash(item.contentHash) {
                let ok = self.bumpLatestAlive(id: existingId, item: item)
                let uuid = UUID(uuidString: existingId)
                DispatchQueue.main.async {
                    if ok, let uuid {
                        completion?(.bumped(existingId: uuid))
                    } else {
                        completion?(ok ? .inserted : .failed)
                    }
                }
                return
            }

            let ok = self.insertNewItem(item, db: db)
            DispatchQueue.main.async { completion?(ok ? .inserted : .failed) }
        }
    }

    // MARK: - Multi-device sync helpers


    func metaValue(forKey key: String, completion: @escaping (String?) -> Void) {
        dbQueue.async { [weak self] in
            let v = self?.metaGet(key)
            DispatchQueue.main.async { completion(v) }
        }
    }

    func setMetaValue(_ key: String, _ value: String, completion: (() -> Void)? = nil) {
        dbQueue.async { [weak self] in
            self?.metaSet(key, value)
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Synchronous meta access — **must** be called on `dbQueue` only (sync service workers).
    func metaGetSync(_ key: String) -> String? { metaGet(key) }
    func metaSetSync(_ key: String, _ value: String) { metaSet(key, value) }

    /// Run work on the database serial queue (sync apply / bootstrap).
    func performSyncWork(_ body: @escaping () -> Void) {
        dbQueue.async(execute: body)
    }

    /// Blob keys present locally for a content hash (image / rtf / pdf suffixes).
    func existingBlobKeys(for contentHash: String) -> [String] {
        var keys: [String] = []
        let candidates = [contentHash, contentHash + ".rtf", contentHash + ".pdf"]
        for k in candidates {
            if fm.fileExists(atPath: blobFileURL(hash: k).path) {
                keys.append(k)
            }
        }
        return keys
    }

    /// Keyset export of metadata rows (no BLOBs) for one-shot sync bootstrap.
    func exportItemsForSync(
        limit: Int,
        cursor: ClipCursor?,
        completion: @escaping (_ items: [ClipboardItem], _ next: ClipCursor?) -> Void
    ) {
        fetchPage(limit: limit, cursor: cursor, query: nil, completion: { page in
            completion(page.items, page.nextCursor)
        })
    }

    /// Apply remote upsert. Content-hash latest-alive: same body does not create a second row.
    /// Returns whether the local DB changed.
    @discardableResult
    func applySyncUpsertLocked(
        id: UUID,
        timestamp: Date,
        typeRaw: String,
        contentHash: String,
        textContent: String?,
        htmlContent: String?,
        ocrText: String?,
        sourceApp: String?,
        urlString: String?,
        fileURLPaths: [String]?,
        copyCount: Int
    ) -> Bool {
        guard let db = db else { return false }
        let idStr = id.uuidString
        let type = ClipboardType(rawValue: typeRaw) ?? .other

        // Same content already present under any id → bump that row (dedupe across hosts).
        if let existing = findIdByContentHash(contentHash) {
            if existing == idStr {
                return refreshRemoteFields(
                    id: idStr,
                    timestamp: timestamp,
                    sourceApp: sourceApp,
                    ocrText: ocrText,
                    textContent: textContent,
                    htmlContent: htmlContent,
                    copyCount: copyCount
                )
            }
            // Different id, same body: bump existing, keep local id stable.
            let item = ClipboardItem(
                id: UUID(uuidString: existing) ?? id,
                timestamp: timestamp,
                type: type,
                contentHash: contentHash,
                textContent: textContent,
                htmlContent: htmlContent,
                ocrText: ocrText,
                sourceApp: sourceApp
            )
            return bumpLatestAlive(id: existing, item: item)
        }

        // Row with this id already? (re-delivery)
        if rowExists(id: idStr) {
            return refreshRemoteFields(
                id: idStr,
                timestamp: timestamp,
                sourceApp: sourceApp,
                ocrText: ocrText,
                textContent: textContent,
                htmlContent: htmlContent,
                copyCount: copyCount
            )
        }

        let urls = fileURLPaths?.compactMap { URL(fileURLWithPath: $0) }
        let url = urlString.flatMap { URL(string: $0) }
        let item = ClipboardItem(
            id: id,
            timestamp: timestamp,
            type: type,
            contentHash: contentHash,
            textContent: textContent,
            fileURLs: urls,
            url: url,
            htmlContent: htmlContent,
            ocrText: ocrText,
            sourceApp: sourceApp
        )
        guard insertNewItem(item, db: db) else { return false }
        if copyCount > 1 {
            _ = setCopyCount(id: idStr, count: copyCount)
        }
        return true
    }

    @discardableResult
    func applySyncTombstoneLocked(id: UUID) -> Bool {
        guard let db = db else { return false }
        let idStr = id.uuidString
        var hash: String?
        var hStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT content_hash FROM clipboard_items WHERE id = ?;", -1, &hStmt, nil) == SQLITE_OK {
            bindText(hStmt, 1, idStr)
            if sqlite3_step(hStmt) == SQLITE_ROW {
                hash = sqlite3_column_text(hStmt, 0).map { String(cString: $0) }
            }
        }
        sqlite3_finalize(hStmt)

        let sql = "DELETE FROM clipboard_items WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, idStr)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { return false }
        // sqlite3_changes: 0 means already gone — still success for idempotent tombstone.
        deleteFTS(id: idStr)
        if let hash { gcBlobIfUnreferenced(hash: hash) }
        return true
    }

    private func rowExists(id: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM clipboard_items WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        bindText(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func setCopyCount(id: String, count: Int) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        let sql = "UPDATE clipboard_items SET copy_count = MAX(COALESCE(copy_count, 1), ?) WHERE id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int(stmt, 1, Int32(max(1, count)))
        bindText(stmt, 2, id)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE
    }

    private func refreshRemoteFields(
        id: String,
        timestamp: Date,
        sourceApp: String?,
        ocrText: String?,
        textContent: String?,
        htmlContent: String?,
        copyCount: Int
    ) -> Bool {
        guard let db = db else { return false }
        let sql = """
        UPDATE clipboard_items SET
            timestamp = MAX(timestamp, ?),
            source_app = COALESCE(?, source_app),
            ocr_text = CASE WHEN ? IS NOT NULL AND length(?) > length(COALESCE(ocr_text, '')) THEN ? ELSE ocr_text END,
            text_content = COALESCE(text_content, ?),
            html_content = COALESCE(html_content, ?),
            copy_count = MAX(COALESCE(copy_count, 1), ?)
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
        bindText(stmt, 2, sourceApp)
        bindText(stmt, 3, ocrText)
        bindText(stmt, 4, ocrText)
        bindText(stmt, 5, ocrText)
        bindText(stmt, 6, textContent)
        bindText(stmt, 7, htmlContent)
        sqlite3_bind_int(stmt, 8, Int32(max(1, copyCount)))
        bindText(stmt, 9, id)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { return false }
        // Refresh FTS with best-known fields
        var t: String?
        var o: String?
        var s: String?
        var h: String?
        var q: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "SELECT text_content, ocr_text, source_app, html_content FROM clipboard_items WHERE id = ?;",
            -1, &q, nil
        ) == SQLITE_OK {
            bindText(q, 1, id)
            if sqlite3_step(q) == SQLITE_ROW {
                t = sqlite3_column_text(q, 0).map { String(cString: $0) }
                o = sqlite3_column_text(q, 1).map { String(cString: $0) }
                s = sqlite3_column_text(q, 2).map { String(cString: $0) }
                h = sqlite3_column_text(q, 3).map { String(cString: $0) }
            }
        }
        sqlite3_finalize(q)
        upsertFTS(id: id, text: t, ocr: o, source: s, html: h)
        return true
    }

    /// Same content re-copied: keep one row, refresh timestamp / source / count; keep stable id.
    /// If row was soft-deleted, re-copy restores it to the main library.
    private func bumpLatestAlive(id: String, item: ClipboardItem) -> Bool {
        guard let db = db else { return false }
        let sql = """
        UPDATE clipboard_items SET
            timestamp = ?,
            source_app = COALESCE(?, source_app),
            copy_count = COALESCE(copy_count, 1) + 1,
            deleted_at = NULL
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_double(stmt, 1, item.timestamp.timeIntervalSince1970)
        bindText(stmt, 2, item.sourceApp)
        bindText(stmt, 3, id)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { return false }
        // Re-index FTS if restored from trash (FTS may have been removed on soft-delete).
        upsertFTS(
            id: id,
            text: item.textContent,
            ocr: item.ocrText,
            source: item.sourceApp,
            html: item.htmlContent
        )
        recordClipboardEvent(
            itemId: id,
            contentHash: item.contentHash,
            eventTs: item.timestamp,
            type: item.type.rawValue,
            sourceApp: item.sourceApp,
            kind: "capture"
        )
        appendOperationLogSync(
            action: "capture_bump",
            itemId: id,
            contentHash: item.contentHash,
            detail: "source=\(item.sourceApp ?? "-")",
            source: "clipboard"
        )
        return true
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

        // Images/pdf/rtf live in CAS files (skill §6) — keep SQLite lean for backups.
        if let imgData = item.imageData, !imgData.isEmpty {
            _ = writeBlobFile(hash: item.contentHash, data: imgData)
        }
        sqlite3_bind_null(stmt, 6)

        let fileURLsStr = item.fileURLs?.map { $0.path }.joined(separator: "|")
        if let fUrls = fileURLsStr { bindText(stmt, 7, fUrls) } else { sqlite3_bind_null(stmt, 7) }

        if let urlStr = item.url?.absoluteString { bindText(stmt, 8, urlStr) } else { sqlite3_bind_null(stmt, 8) }

        if let rtfData = item.rtfData, !rtfData.isEmpty {
            _ = writeBlobFile(hash: item.contentHash + ".rtf", data: rtfData)
        }
        sqlite3_bind_null(stmt, 9)

        if let pdfData = item.pdfData, !pdfData.isEmpty {
            _ = writeBlobFile(hash: item.contentHash + ".pdf", data: pdfData)
        }
        sqlite3_bind_null(stmt, 10)

        if let html = item.htmlContent { bindText(stmt, 11, html) } else { sqlite3_bind_null(stmt, 11) }
        sqlite3_bind_null(stmt, 12)
        if let srcApp = item.sourceApp { bindText(stmt, 13, srcApp) } else { sqlite3_bind_null(stmt, 13) }
        if let ocr = item.ocrText { bindText(stmt, 14, ocr) } else { sqlite3_bind_null(stmt, 14) }

        let stepRes = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard stepRes == SQLITE_DONE else { return false }

        // first_seen_at on insert
        let fsSQL = "UPDATE clipboard_items SET first_seen_at = COALESCE(first_seen_at, ?) WHERE id = ?;"
        var fs: OpaquePointer?
        if sqlite3_prepare_v2(db, fsSQL, -1, &fs, nil) == SQLITE_OK {
            sqlite3_bind_double(fs, 1, item.timestamp.timeIntervalSince1970)
            bindText(fs, 2, idStr)
            _ = sqlite3_step(fs)
        }
        sqlite3_finalize(fs)

        upsertFTS(
            id: idStr,
            text: item.textContent,
            ocr: item.ocrText,
            source: item.sourceApp,
            html: item.htmlContent
        )
        recordClipboardEvent(
            itemId: idStr,
            contentHash: item.contentHash,
            eventTs: item.timestamp,
            type: item.type.rawValue,
            sourceApp: item.sourceApp,
            kind: "capture"
        )
        appendOperationLogSync(
            action: "capture_insert",
            itemId: idStr,
            contentHash: item.contentHash,
            detail: "type=\(item.type.rawValue)",
            source: "clipboard"
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
        trashOnly: Bool = false,
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

            if trashOnly {
                // Trash view: no FTS; optional LIKE on alive fields of deleted rows.
                if hasQuery, let q = q {
                    items = self.runSearchLike(db: db, q: q, cursor: cursor, fetchLimit: fetchLimit, trashOnly: true)
                } else {
                    items = self.runList(db: db, cursor: cursor, fetchLimit: fetchLimit, trashOnly: true)
                }
            } else if hasQuery, let match = ftsMatch {
                items = self.runSearchFTS(db: db, match: match, cursor: cursor, fetchLimit: fetchLimit)
                // Hybrid: always merge LIKE (text/ocr/html/source/note) so OCR hits are never
                // lost when FTS tokenizer/ranking under-matches CJK or short tokens.
                let likeItems = self.runSearchLike(db: db, q: q!, cursor: cursor, fetchLimit: fetchLimit)
                if items.isEmpty {
                    items = likeItems
                } else if !likeItems.isEmpty {
                    var seen = Set(items.map { $0.id })
                    for it in likeItems where !seen.contains(it.id) {
                        items.append(it)
                        seen.insert(it.id)
                        if items.count >= fetchLimit { break }
                    }
                    // Keep recency for overflow — re-sort by timestamp desc
                    items.sort { a, b in
                        if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
                        return a.id.uuidString > b.id.uuidString
                    }
                    if items.count > fetchLimit {
                        items = Array(items.prefix(fetchLimit))
                    }
                }
            } else if hasQuery, let q = q {
                // Short query (<3) with trigram: LIKE path.
                items = self.runSearchLike(db: db, q: q, cursor: cursor, fetchLimit: fetchLimit)
            } else {
                items = self.runList(db: db, cursor: cursor, fetchLimit: fetchLimit, trashOnly: trashOnly)
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

    /// Exclusive keyset: strictly older than (timestamp, id) in DESC order.
    private func bindKeysetCursor(_ stmt: OpaquePointer?, startBind: Int, cursor: ClipCursor) -> Int {
        var bind = startBind
        sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
        sqlite3_bind_double(stmt, Int32(bind), cursor.timestamp); bind += 1
        bindText(stmt, Int32(bind), cursor.id); bind += 1
        // Extra guard: never re-emit the boundary row even if float compare glitches.
        bindText(stmt, Int32(bind), cursor.id); bind += 1
        return bind
    }

    private static let keysetSQL =
        "(timestamp < ? OR (timestamp = ? AND id < ?)) AND id != ?"
    private static let keysetSQLAliased =
        "(c.timestamp < ? OR (c.timestamp = ? AND c.id < ?)) AND c.id != ?"

    private func runSearchFTS(
        db: OpaquePointer,
        match: String,
        cursor: ClipCursor?,
        fetchLimit: Int
    ) -> [ClipboardItem] {
        var sql = """
        SELECT c.id, c.timestamp, c.type, c.content_hash, c.text_content, c.file_urls, c.url, c.html_content, c.source_app, c.ocr_text,
               COALESCE(c.copy_count, 1), c.deleted_at, c.first_seen_at,
               c.user_note, c.user_stage, c.user_rating, c.user_context_updated_at
        FROM clipboard_fts f
        JOIN clipboard_items c ON c.id = f.id
        WHERE clipboard_fts MATCH ? AND c.deleted_at IS NULL
        """
        if cursor != nil {
            sql += " AND \(Self.keysetSQLAliased)"
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
            bind = bindKeysetCursor(stmt, startBind: bind, cursor: cursor)
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
        fetchLimit: Int,
        trashOnly: Bool = false
    ) -> [ClipboardItem] {
        var sql = "SELECT id, timestamp, type, content_hash, text_content, file_urls, url, html_content, source_app, ocr_text, COALESCE(copy_count, 1), deleted_at, first_seen_at, user_note, user_stage, user_rating, user_context_updated_at FROM clipboard_items WHERE "
        if trashOnly {
            sql += "deleted_at IS NOT NULL"
        } else {
            sql += "deleted_at IS NULL"
        }
        sql += " AND (IFNULL(text_content,'') LIKE ? OR IFNULL(ocr_text,'') LIKE ? OR IFNULL(source_app,'') LIKE ? OR IFNULL(html_content,'') LIKE ? OR IFNULL(user_note,'') LIKE ? OR IFNULL(user_stage,'') LIKE ?)"
        if cursor != nil {
            sql += " AND " + Self.keysetSQL
        }
        if trashOnly {
            sql += " ORDER BY deleted_at DESC, id DESC LIMIT ?;"
        } else {
            sql += " ORDER BY timestamp DESC, id DESC LIMIT ?;"
        }

        var stmt: OpaquePointer?
        var items: [ClipboardItem] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bind = 1
        let like = "%\(q)%"
        for _ in 0..<6 {
            bindText(stmt, Int32(bind), like); bind += 1
        }
        if let cursor = cursor {
            bind = bindKeysetCursor(stmt, startBind: bind, cursor: cursor)
        }
        sqlite3_bind_int(stmt, Int32(bind), Int32(fetchLimit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = rowToItem(stmt: stmt) { items.append(item) }
        }
        sqlite3_finalize(stmt)
        return items
    }

    private func runList(db: OpaquePointer, cursor: ClipCursor?, fetchLimit: Int, trashOnly: Bool = false) -> [ClipboardItem] {
        var sql = "SELECT id, timestamp, type, content_hash, text_content, file_urls, url, html_content, source_app, ocr_text, COALESCE(copy_count, 1), deleted_at, first_seen_at, user_note, user_stage, user_rating, user_context_updated_at FROM clipboard_items WHERE "
        if trashOnly {
            sql += "deleted_at IS NOT NULL"
        } else {
            sql += "deleted_at IS NULL"
        }
        if cursor != nil {
            sql += " AND " + Self.keysetSQL
        }
        if trashOnly {
            sql += " ORDER BY deleted_at DESC, id DESC LIMIT ?;"
        } else {
            sql += " ORDER BY timestamp DESC, id DESC LIMIT ?;"
        }

        var stmt: OpaquePointer?
        var items: [ClipboardItem] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var bind = 1
        if let cursor = cursor {
            bind = bindKeysetCursor(stmt, startBind: bind, cursor: cursor)
        }
        sqlite3_bind_int(stmt, Int32(bind), Int32(fetchLimit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = rowToItem(stmt: stmt) { items.append(item) }
        }
        sqlite3_finalize(stmt)
        return items
    }

    /// Columns: id, timestamp, type, content_hash, text, file_urls, url, html, source, ocr,
    /// copy_count, deleted_at, first_seen_at, user_note, user_stage, user_rating, user_context_updated_at
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
        let fileURLs: [URL]? = {
            guard let raw = sqlite3_column_text(stmt, 5).map({ String(cString: $0) }),
                  !raw.isEmpty else { return nil }
            let urls = raw.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            return urls.isEmpty ? nil : urls
        }()
        let url: URL? = sqlite3_column_text(stmt, 6).map { String(cString: $0) }.flatMap { URL(string: $0) }
        let htmlContent = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let sourceApp = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let ocrText = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

        let colCount = sqlite3_column_count(stmt)
        var copyCount = 1
        var deletedAt: Date? = nil
        var firstSeenAt: Date? = nil
        var userNote: String? = nil
        var userStage: String? = nil
        var userRating: Double? = nil
        var userContextUpdatedAt: Date? = nil
        if colCount >= 11 {
            copyCount = max(1, Int(sqlite3_column_int(stmt, 10)))
        }
        if colCount >= 12, sqlite3_column_type(stmt, 11) != SQLITE_NULL {
            deletedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        }
        if colCount >= 13, sqlite3_column_type(stmt, 12) != SQLITE_NULL {
            firstSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        }
        if colCount >= 14, sqlite3_column_type(stmt, 13) != SQLITE_NULL {
            userNote = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
        }
        if colCount >= 15, sqlite3_column_type(stmt, 14) != SQLITE_NULL {
            userStage = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
        }
        if colCount >= 16, sqlite3_column_type(stmt, 15) != SQLITE_NULL {
            userRating = sqlite3_column_double(stmt, 15)
        }
        if colCount >= 17, sqlite3_column_type(stmt, 16) != SQLITE_NULL {
            userContextUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))
        }

        return ClipboardItem(
            id: uuid,
            timestamp: timestamp,
            type: ClipboardType(rawValue: typeStr) ?? .text,
            contentHash: hash,
            textContent: textContent,
            imageData: nil,
            fileURLs: fileURLs,
            url: url,
            htmlContent: htmlContent,
            ocrText: ocrText,
            sourceApp: sourceApp,
            copyCount: copyCount,
            deletedAt: deletedAt,
            firstSeenAt: firstSeenAt,
            userNote: userNote,
            userStage: userStage,
            userRating: userRating,
            userContextUpdatedAt: userContextUpdatedAt
        )
    }

    // MARK: - User evaluations (append-only history; never mutates capture payload)

    enum UserContextError: Error, LocalizedError {
        case notFound
        case invalidRating(Double)
        case ratingLocked
        case needRating
        case emptyUpdate
        case db

        var errorDescription: String? {
            switch self {
            case .notFound: return "条目不存在"
            case .invalidRating(let r): return "评分须为 0.5–5 星（半星步进）: \(r)"
            case .ratingLocked: return "评分更新失败"
            case .needRating: return "请选择星级或填写备注"
            case .emptyUpdate: return "请填写评分或备注"
            case .db: return "数据库写入失败"
            }
        }
    }

    /// One evaluation submission. Always inserts a history row (even if values match latest).
    /// Updates projection columns to latest note/rating only. **Never** touches capture payload.
    func submitEvaluation(
        id: UUID,
        rating: Double?,
        note: String?,
        evaluationId: UUID? = nil,
        source: String = "web",
        completion: @escaping (Result<(item: ClipboardItem, evaluationId: String), Error>) -> Void
    ) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(.failure(UserContextError.db)) }
                return
            }
            do {
                let r = try self.submitEvaluationLocked(
                    id: id, rating: rating, note: note,
                    evaluationId: evaluationId, source: source
                )
                DispatchQueue.main.async { completion(.success(r)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    @discardableResult
    func submitEvaluationLocked(
        id: UUID,
        rating: Double?,
        note: String?,
        evaluationId: UUID? = nil,
        source: String
    ) throws -> (item: ClipboardItem, evaluationId: String) {
        guard let db = db else { throw UserContextError.db }
        let idStr = id.uuidString

        var contentHash = ""
        var typeRaw = "text"
        var q: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT content_hash, type FROM clipboard_items WHERE id = ? LIMIT 1;",
            -1, &q, nil
        ) == SQLITE_OK else { throw UserContextError.db }
        bindText(q, 1, idStr)
        guard sqlite3_step(q) == SQLITE_ROW else {
            sqlite3_finalize(q)
            throw UserContextError.notFound
        }
        contentHash = sqlite3_column_text(q, 0).map { String(cString: $0) } ?? ""
        typeRaw = sqlite3_column_text(q, 1).map { String(cString: $0) } ?? "text"
        sqlite3_finalize(q)

        let noteNorm: String? = {
            guard let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
            return String(n.prefix(4000))
        }()
        let ratingNorm: Double?
        if let rating {
            guard let n = ClipboardItem.normalizeRating(rating) else {
                throw UserContextError.invalidRating(rating)
            }
            ratingNorm = n
        } else {
            ratingNorm = nil
        }
        // Stars may be re-set any time (half-star steps); each submit is still one history row.
        guard ratingNorm != nil || noteNorm != nil else { throw UserContextError.emptyUpdate }

        let eid = (evaluationId ?? UUID()).uuidString
        let now = Date()

        // Idempotent insert by id (multi-device re-delivery).
        var exists = false
        var eChk: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT 1 FROM user_evaluations WHERE id = ? LIMIT 1;", -1, &eChk, nil) == SQLITE_OK {
            bindText(eChk, 1, eid)
            exists = sqlite3_step(eChk) == SQLITE_ROW
        }
        sqlite3_finalize(eChk)

        if !exists {
            let ins = """
            INSERT INTO user_evaluations (id, item_id, content_hash, ts, rating, note, source)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, ins, -1, &stmt, nil) == SQLITE_OK else { throw UserContextError.db }
            bindText(stmt, 1, eid)
            bindText(stmt, 2, idStr)
            bindText(stmt, 3, contentHash)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
            if let ratingNorm { sqlite3_bind_double(stmt, 5, ratingNorm) }
            else { sqlite3_bind_null(stmt, 5) }
            bindText(stmt, 6, noteNorm)
            bindText(stmt, 7, source)
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard rc == SQLITE_DONE else { throw UserContextError.db }
        }

        // Projection: latest rating (if any) + latest note; always latest row ts.
        var latestRating: Double?
        var latestNote: String?
        var latestTs = now.timeIntervalSince1970
        var lq: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "SELECT note, rating, ts FROM user_evaluations WHERE item_id = ? ORDER BY ts DESC LIMIT 1;",
            -1, &lq, nil
        ) == SQLITE_OK {
            bindText(lq, 1, idStr)
            if sqlite3_step(lq) == SQLITE_ROW {
                if sqlite3_column_type(lq, 0) != SQLITE_NULL {
                    latestNote = sqlite3_column_text(lq, 0).map { String(cString: $0) }
                }
                if sqlite3_column_type(lq, 1) != SQLITE_NULL {
                    latestRating = sqlite3_column_double(lq, 1)
                }
                latestTs = sqlite3_column_double(lq, 2)
            }
        }
        sqlite3_finalize(lq)
        // If latest row has no rating, keep last non-null rating for header display.
        if latestRating == nil {
            var rq: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT rating FROM user_evaluations WHERE item_id = ? AND rating IS NOT NULL ORDER BY ts DESC LIMIT 1;",
                -1, &rq, nil
            ) == SQLITE_OK {
                bindText(rq, 1, idStr)
                if sqlite3_step(rq) == SQLITE_ROW {
                    latestRating = sqlite3_column_double(rq, 0)
                }
            }
            sqlite3_finalize(rq)
        }
        if latestNote == nil {
            var nq: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT note FROM user_evaluations WHERE item_id = ? AND note IS NOT NULL AND length(note) > 0 ORDER BY ts DESC LIMIT 1;",
                -1, &nq, nil
            ) == SQLITE_OK {
                bindText(nq, 1, idStr)
                if sqlite3_step(nq) == SQLITE_ROW {
                    latestNote = sqlite3_column_text(nq, 0).map { String(cString: $0) }
                }
            }
            sqlite3_finalize(nq)
        }

        let up = """
        UPDATE clipboard_items SET
            user_note = ?,
            user_rating = ?,
            user_context_updated_at = ?,
            user_stage = NULL
        WHERE id = ?;
        """
        var u: OpaquePointer?
        guard sqlite3_prepare_v2(db, up, -1, &u, nil) == SQLITE_OK else { throw UserContextError.db }
        bindText(u, 1, latestNote)
        if let latestRating { sqlite3_bind_double(u, 2, latestRating) }
        else { sqlite3_bind_null(u, 2) }
        sqlite3_bind_double(u, 3, latestTs)
        bindText(u, 4, idStr)
        let urc = sqlite3_step(u)
        sqlite3_finalize(u)
        guard urc == SQLITE_DONE else { throw UserContextError.db }

        var detailObj: [String: Any] = [
            "evaluationId": eid,
            "rating": ratingNorm as Any
        ]
        if let noteNorm { detailObj["note"] = noteNorm }
        let detailStr = String(
            data: (try? JSONSerialization.data(withJSONObject: detailObj)) ?? Data(),
            encoding: .utf8
        )

        if !exists {
            _ = appendOperationLogSync(
                action: "user_evaluation",
                itemId: idStr,
                contentHash: contentHash,
                detail: detailStr,
                source: source
            )
            _ = recordClipboardEvent(
                itemId: idStr,
                contentHash: contentHash,
                eventTs: now,
                type: typeRaw,
                sourceApp: source,
                kind: "user_evaluation",
                detail: detailStr
            )
        }

        guard let item = fetchItemByIdLocked(idStr) else { throw UserContextError.db }
        return (item, eid)
    }

    /// Sync path: apply peer evaluation as a history row (idempotent by evaluationId).
    @discardableResult
    func applyUserContextLocked(
        id: UUID,
        note: String?,
        rating: Double?,
        evaluationId: UUID?,
        source: String
    ) throws -> ClipboardItem {
        try submitEvaluationLocked(
            id: id,
            rating: rating,
            note: note,
            evaluationId: evaluationId,
            source: source
        ).item
    }

    private func fetchItemByIdLocked(_ idStr: String) -> ClipboardItem? {
        guard let db = db else { return nil }
        var f: OpaquePointer?
        let fetchSQL = """
        SELECT id, timestamp, type, content_hash, text_content, file_urls, url, html_content, source_app, ocr_text,
               COALESCE(copy_count, 1), deleted_at, first_seen_at, user_note, user_stage, user_rating, user_context_updated_at
        FROM clipboard_items WHERE id = ? LIMIT 1;
        """
        var out: ClipboardItem?
        if sqlite3_prepare_v2(db, fetchSQL, -1, &f, nil) == SQLITE_OK {
            bindText(f, 1, idStr)
            if sqlite3_step(f) == SQLITE_ROW {
                out = rowToItem(stmt: f)
            }
        }
        sqlite3_finalize(f)
        return out
    }

    func fetchEvaluations(itemId: UUID, limit: Int = 50, completion: @escaping ([[String: Any]]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let lim = max(1, min(limit, 200))
            let sql = """
            SELECT id, item_id, content_hash, ts, rating, note, source
            FROM user_evaluations WHERE item_id = ?
            ORDER BY ts DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            var rows: [[String: Any]] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                self.bindText(stmt, 1, itemId.uuidString)
                sqlite3_bind_int(stmt, 2, Int32(lim))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var row: [String: Any] = [:]
                    row["id"] = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    row["itemId"] = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    row["contentHash"] = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let ets = sqlite3_column_double(stmt, 3)
                    row["ts"] = ets
                    row["timeLocal"] = ClipTimeFormat.displayWall(unix: ets)
                    if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                        row["rating"] = sqlite3_column_double(stmt, 4)
                    }
                    if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                        row["note"] = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    }
                    row["source"] = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                    rows.append(row)
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    // MARK: - Soft delete / recycle bin (TTL 30d)

    func deleteItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        deleteItem(id: item.id, completion: completion)
    }

    /// Soft-delete: set deleted_at; keep row + CAS until TTL purge.
    func deleteItem(id: UUID, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let idStr = id.uuidString
            var hash: String?
            var hStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT content_hash FROM clipboard_items WHERE id = ?;", -1, &hStmt, nil) == SQLITE_OK {
                self.bindText(hStmt, 1, idStr)
                if sqlite3_step(hStmt) == SQLITE_ROW {
                    hash = sqlite3_column_text(hStmt, 0).map { String(cString: $0) }
                }
            }
            sqlite3_finalize(hStmt)

            let sql = "UPDATE clipboard_items SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(stmt, 1, now)
            self.bindText(stmt, 2, idStr)
            let stepRes = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            let changed = sqlite3_changes(db) > 0
            if stepRes == SQLITE_DONE && changed {
                // Hide from main FTS; trash uses LIKE only.
                self.deleteFTS(id: idStr)
                self.appendOperationLogSync(
                    action: "soft_delete",
                    itemId: idStr,
                    contentHash: hash,
                    detail: "ttl_days=30",
                    source: "web"
                )
            }
            DispatchQueue.main.async { completion?(stepRes == SQLITE_DONE && changed) }
        }
    }

    /// Restore from recycle bin.
    func restoreItem(id: UUID, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let idStr = id.uuidString
            // Load fields for FTS reindex
            var text: String?
            var ocr: String?
            var source: String?
            var html: String?
            var hash: String?
            var q: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT text_content, ocr_text, source_app, html_content, content_hash FROM clipboard_items WHERE id = ? AND deleted_at IS NOT NULL;",
                -1, &q, nil
            ) == SQLITE_OK {
                self.bindText(q, 1, idStr)
                if sqlite3_step(q) == SQLITE_ROW {
                    text = sqlite3_column_text(q, 0).map { String(cString: $0) }
                    ocr = sqlite3_column_text(q, 1).map { String(cString: $0) }
                    source = sqlite3_column_text(q, 2).map { String(cString: $0) }
                    html = sqlite3_column_text(q, 3).map { String(cString: $0) }
                    hash = sqlite3_column_text(q, 4).map { String(cString: $0) }
                } else {
                    sqlite3_finalize(q)
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
            } else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            sqlite3_finalize(q)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE clipboard_items SET deleted_at = NULL WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            self.bindText(stmt, 1, idStr)
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard rc == SQLITE_DONE else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            self.upsertFTS(id: idStr, text: text, ocr: ocr, source: source, html: html)
            self.appendOperationLogSync(
                action: "restore",
                itemId: idStr,
                contentHash: hash,
                detail: nil,
                source: "web"
            )
            DispatchQueue.main.async { completion?(true) }
        }
    }

    /// Hard-delete rows past trash TTL (batched).
    @discardableResult
    private func purgeExpiredTrash(limit: Int) -> Int {
        guard let db = db else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - Self.trashTTLSeconds
        // Collect ids + hashes first
        var victims: [(String, String)] = []
        var sel: OpaquePointer?
        let sql = "SELECT id, content_hash FROM clipboard_items WHERE deleted_at IS NOT NULL AND deleted_at < ? ORDER BY deleted_at ASC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &sel, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_double(sel, 1, cutoff)
        sqlite3_bind_int(sel, 2, Int32(limit))
        while sqlite3_step(sel) == SQLITE_ROW {
            if let id = sqlite3_column_text(sel, 0).map({ String(cString: $0) }),
               let hash = sqlite3_column_text(sel, 1).map({ String(cString: $0) }) {
                victims.append((id, hash))
            }
        }
        sqlite3_finalize(sel)
        guard !victims.isEmpty else { return 0 }

        var purged = 0
        for (id, hash) in victims {
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM clipboard_items WHERE id = ?;", -1, &del, nil) == SQLITE_OK {
                bindText(del, 1, id)
                if sqlite3_step(del) == SQLITE_DONE {
                    purged += 1
                    deleteFTS(id: id)
                    gcBlobIfUnreferenced(hash: hash)
                    // Keep events for frequency? Drop item-scoped events on hard purge.
                    execQuiet("DELETE FROM clipboard_events WHERE item_id = '\(id.replacingOccurrences(of: "'", with: "''"))';")
                    appendOperationLogSync(
                        action: "purge_trash",
                        itemId: id,
                        contentHash: hash,
                        detail: "ttl_expired",
                        source: "maintenance"
                    )
                }
            }
            sqlite3_finalize(del)
        }
        return purged
    }

    private func gcBlobIfUnreferenced(hash: String) {
        let safe = hash.replacingOccurrences(of: "'", with: "''")
        let n = scalarInt64("SELECT COUNT(*) FROM clipboard_items WHERE content_hash = '\(safe)';") ?? 0
        guard n == 0 else { return }
        try? fm.removeItem(at: blobFileURL(hash: hash))
        try? fm.removeItem(at: blobFileURL(hash: hash + ".rtf"))
        try? fm.removeItem(at: blobFileURL(hash: hash + ".pdf"))
    }

    func searchItems(query: String, limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        fetchPage(limit: limit, cursor: nil, query: query) { page in
            completion(page.items)
        }
    }

    func fetchImageData(id: UUID, completion: @escaping (Data?) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion(nil); return }
            let sql = "SELECT content_hash, image_data FROM clipboard_items WHERE id = ?;"
            var stmt: OpaquePointer?
            var data: Data?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                self.bindText(stmt, 1, id.uuidString)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let hash = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                    if let hash = hash, let fileData = self.readBlobFile(hash: hash) {
                        data = fileData
                    } else if let blobPtr = sqlite3_column_blob(stmt, 1) {
                        let size = Int(sqlite3_column_bytes(stmt, 1))
                        if size > 0 {
                            let inline = Data(bytes: blobPtr, count: size)
                            data = inline
                            if let hash = hash {
                                _ = self.writeBlobFile(hash: hash, data: inline)
                                let clear = "UPDATE clipboard_items SET image_data=NULL WHERE id=?;"
                                var u: OpaquePointer?
                                if sqlite3_prepare_v2(db, clear, -1, &u, nil) == SQLITE_OK {
                                    self.bindText(u, 1, id.uuidString)
                                    _ = sqlite3_step(u)
                                }
                                sqlite3_finalize(u)
                            }
                        }
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// Soft-delete all alive rows (into trash); does not hard-wipe.
    func clearAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let now = Date().timeIntervalSince1970
            var ok = true
            var guardLoops = 0
            while ok && guardLoops < 1_000_000 {
                guardLoops += 1
                let batchSQL = """
                UPDATE clipboard_items SET deleted_at = \(now)
                WHERE id IN (
                    SELECT id FROM clipboard_items WHERE deleted_at IS NULL LIMIT \(Self.deleteBatchSize)
                );
                """
                if !self.execQuiet(batchSQL) {
                    ok = false
                    break
                }
                if sqlite3_changes(db) == 0 { break }
            }
            // Drop FTS for trashed items (full rebuild is simpler for clearAll)
            _ = self.execQuiet("DELETE FROM clipboard_fts;")
            self.appendOperationLogSync(
                action: "clear_all_to_trash",
                itemId: nil,
                contentHash: nil,
                detail: "soft_delete_all_alive",
                source: "app"
            )
            self.execQuiet("PRAGMA wal_checkpoint(PASSIVE);")
            DispatchQueue.main.async { completion?(ok) }
        }
    }


    // MARK: - Undo substr fold (feature removed)

    /// Soft-deleted by substr_fold / historical absorb — restore once and reindex FTS.
    @discardableResult
    private func restoreSubstrFoldVictims(limit: Int) -> Int {
        guard let db = db else { return 0 }
        // Prefer ids recorded in operation_logs; also match detail prefixes.
        let sql = """
        SELECT DISTINCT item_id FROM operation_logs
        WHERE source = 'substr_fold' AND action = 'soft_delete' AND item_id IS NOT NULL
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        var ids: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(max(1, min(limit, 10000))))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) {
                    ids.append(id)
                }
            }
        }
        sqlite3_finalize(stmt)

        // Fallback: detail markers if source missing on older rows
        if ids.isEmpty {
            let sql2 = """
            SELECT DISTINCT item_id FROM operation_logs
            WHERE action = 'soft_delete'
              AND (detail LIKE 'historical_absorbed_by=%' OR detail LIKE 'absorbed_by=%')
              AND item_id IS NOT NULL
            LIMIT ?;
            """
            if sqlite3_prepare_v2(db, sql2, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(max(1, min(limit, 10000))))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) {
                        ids.append(id)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }

        var restored = 0
        for id in ids {
            var u: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "UPDATE clipboard_items SET deleted_at = NULL WHERE id = ? AND deleted_at IS NOT NULL;",
                -1, &u, nil
            ) == SQLITE_OK {
                bindText(u, 1, id)
                _ = sqlite3_step(u)
            }
            sqlite3_finalize(u)
            if sqlite3_changes(db) > 0 {
                // Reindex FTS
                var t: String?; var o: String?; var s: String?; var h: String?
                var q: OpaquePointer?
                if sqlite3_prepare_v2(
                    db,
                    "SELECT text_content, ocr_text, source_app, html_content FROM clipboard_items WHERE id = ?;",
                    -1, &q, nil
                ) == SQLITE_OK {
                    bindText(q, 1, id)
                    if sqlite3_step(q) == SQLITE_ROW {
                        t = sqlite3_column_text(q, 0).map { String(cString: $0) }
                        o = sqlite3_column_text(q, 1).map { String(cString: $0) }
                        s = sqlite3_column_text(q, 2).map { String(cString: $0) }
                        h = sqlite3_column_text(q, 3).map { String(cString: $0) }
                    }
                }
                sqlite3_finalize(q)
                upsertFTS(id: id, text: t, ocr: o, source: s, html: h)
                restored += 1
            }
        }
        if restored > 0 {
            appendOperationLogSync(
                action: "substr_fold_rollback",
                itemId: nil,
                contentHash: nil,
                detail: "restored=\(restored)",
                source: "maintenance"
            )
        }
        return restored
    }

    // MARK: - Clipboard events + frequency

    @discardableResult
    private func recordClipboardEvent(
        itemId: String,
        contentHash: String,
        eventTs: Date,
        type: String,
        sourceApp: String?,
        kind: String,
        detail: String? = nil
    ) -> Bool {
        guard let db = db else { return false }
        let sql = """
        INSERT INTO clipboard_events (id, item_id, content_hash, event_ts, type, source_app, kind, detail)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        let eid = UUID().uuidString
        bindText(stmt, 1, eid)
        bindText(stmt, 2, itemId)
        bindText(stmt, 3, contentHash)
        sqlite3_bind_double(stmt, 4, eventTs.timeIntervalSince1970)
        bindText(stmt, 5, type)
        bindText(stmt, 6, sourceApp)
        bindText(stmt, 7, kind)
        bindText(stmt, 8, detail)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE
    }

    func fetchItemEvents(itemId: UUID, limit: Int = 50, completion: @escaping ([[String: Any]]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let lim = max(1, min(limit, 500))
            let sql = """
            SELECT id, item_id, content_hash, event_ts, type, source_app, kind, detail
            FROM clipboard_events WHERE item_id = ?
            ORDER BY event_ts DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            var rows: [[String: Any]] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                self.bindText(stmt, 1, itemId.uuidString)
                sqlite3_bind_int(stmt, 2, Int32(lim))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var row: [String: Any] = [:]
                    row["id"] = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    row["itemId"] = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    row["contentHash"] = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let ets = sqlite3_column_double(stmt, 3)
                    row["eventTs"] = ets
                    row["timeLocal"] = ClipTimeFormat.displayWall(unix: ets)
                    row["type"] = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    row["sourceApp"] = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    row["kind"] = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                    row["detail"] = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                    rows.append(row)
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    func contentFrequency(contentHash: String, completion: @escaping ([String: Any]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            var eventCount: Int64 = 0
            var firstTs: Double?
            var lastTs: Double?
            var stmt: OpaquePointer?
            let sql = """
            SELECT COUNT(*), MIN(event_ts), MAX(event_ts)
            FROM clipboard_events WHERE content_hash = ?;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                self.bindText(stmt, 1, contentHash)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    eventCount = sqlite3_column_int64(stmt, 0)
                    if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                        firstTs = sqlite3_column_double(stmt, 1)
                    }
                    if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                        lastTs = sqlite3_column_double(stmt, 2)
                    }
                }
            }
            sqlite3_finalize(stmt)

            var copyCount = 1
            var itemId: String?
            var cStmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT id, COALESCE(copy_count,1) FROM clipboard_items WHERE content_hash = ? ORDER BY timestamp DESC LIMIT 1;",
                -1, &cStmt, nil
            ) == SQLITE_OK {
                self.bindText(cStmt, 1, contentHash)
                if sqlite3_step(cStmt) == SQLITE_ROW {
                    itemId = sqlite3_column_text(cStmt, 0).map { String(cString: $0) }
                    copyCount = Int(sqlite3_column_int(cStmt, 1))
                }
            }
            sqlite3_finalize(cStmt)

            var out: [String: Any] = [
                "contentHash": contentHash,
                "eventCount": eventCount,
                "copyCount": copyCount
            ]
            if let itemId { out["itemId"] = itemId }
            if let firstTs { out["firstEventTs"] = firstTs }
            if let lastTs { out["lastEventTs"] = lastTs }
            DispatchQueue.main.async { completion(out) }
        }
    }

    // MARK: - Operation logs (audit)

    /// Public async append (UI / backup / web).
    func appendOperationLog(
        action: String,
        itemId: String?,
        contentHash: String?,
        detail: String?,
        source: String = "system",
        completion: (() -> Void)? = nil
    ) {
        dbQueue.async { [weak self] in
            self?.appendOperationLogSync(
                action: action,
                itemId: itemId,
                contentHash: contentHash,
                detail: detail,
                source: source
            )
            DispatchQueue.main.async { completion?() }
        }
    }

    @discardableResult
    private func appendOperationLogSync(
        action: String,
        itemId: String?,
        contentHash: String?,
        detail: String?,
        source: String
    ) -> Bool {
        guard let db = db else { return false }
        let sql = """
        INSERT INTO operation_logs (id, ts, action, item_id, content_hash, detail, source)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, 1, UUID().uuidString)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        bindText(stmt, 3, action)
        bindText(stmt, 4, itemId)
        bindText(stmt, 5, contentHash)
        bindText(stmt, 6, detail)
        bindText(stmt, 7, source)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE
    }

    func fetchOperationLogs(limit: Int = 100, completion: @escaping ([[String: Any]]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let lim = max(1, min(limit, 500))
            let sql = """
            SELECT id, ts, action, item_id, content_hash, detail, source
            FROM operation_logs ORDER BY ts DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            var rows: [[String: Any]] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(lim))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var row: [String: Any] = [:]
                    row["id"] = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let ots = sqlite3_column_double(stmt, 1)
                    row["ts"] = ots
                    row["timeLocal"] = ClipTimeFormat.displayWall(unix: ots)
                    row["action"] = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    row["itemId"] = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? NSNull()
                    row["contentHash"] = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? NSNull()
                    row["detail"] = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? NSNull()
                    row["source"] = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                    rows.append(row)
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(rows) }
        }
    }

    @discardableResult
    private func pruneOperationLogs(maxAgeDays: Int, limit: Int) -> Int {
        guard let db = db else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - Double(maxAgeDays) * 86400
        let sql = "DELETE FROM operation_logs WHERE id IN (SELECT id FROM operation_logs WHERE ts < ? ORDER BY ts ASC LIMIT ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return Int(sqlite3_changes(db))
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
            self.appendOperationLogSync(
                action: "backup",
                itemId: nil,
                contentHash: nil,
                detail: "dest=\(destURL.lastPathComponent)",
                source: "backup"
            )
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
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clipboard_items WHERE deleted_at IS NULL;", -1, &stmt, nil) == SQLITE_OK {
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
            self.migrateInlineBlobsToFiles(maxBatches: 200)
            self.maybeVacuumAfterBlobMigration()
            self.runAnalyze()
            self.appendOperationLogSync(
                action: "restore_db",
                itemId: nil,
                contentHash: nil,
                detail: "from=\(sourceURL.lastPathComponent)",
                source: "backup"
            )
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
