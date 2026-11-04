import Foundation
import CryptoKit
import SQLite3

/// Off-site copy of a completed per-host backup. Credentials stay on the server.
final class OstoreBackup {
    static let shared = OstoreBackup()

    /// One finished run. Persisted so the panel still shows numbers after a restart.
    struct Run: Codable {
        var phase = "ok"            // ok | error
        var host: String? = nil
        var total = 0
        var uploaded = 0
        var skipped = 0
        var failed = 0
        var uploadedBytes = 0
        var skippedBytes = 0
        var remoteObjects = 0
        var remoteBytes = 0
        var startedUnix: Double? = nil
        var finishedUnix: Double? = nil
        var durationSeconds: Double? = nil
        var error: String? = nil
    }

    struct Status: Codable {
        var configured = false
        /// Mirror step on/off (`enabled` in ostore-backup.json, default true).
        var enabled = true
        var baseURL: String? = nil
        var inProgress = false
        /// Another root is waiting behind the running one (click while uploading).
        var queued = false
        var phase = "not_configured"
        var host: String? = nil
        var lastSuccessUnix: Double? = nil
        var lastError: String? = nil
        /// Objects this run intends to publish: blobs + database copies + latest files.
        var total = 0
        var uploaded = 0
        var skipped = 0
        var failed = 0
        /// Not published yet. 0 after a clean run, > 0 only after an abort.
        var pending = 0
        var uploadedBytes = 0
        var skippedBytes = 0
        /// Local manifest totals (what a restore expects).
        var manifestObjects = 0
        var manifestBytes = 0
        /// Remote listing totals under the host prefix, re-read at the end of a run.
        var remoteObjects = 0
        var remoteBytes = 0
        var startedUnix: Double? = nil
        var durationSeconds: Double? = nil
        /// Last finished run (ok or error). Persisted across restarts.
        var lastRun: Run? = nil
    }

    private struct Config: Decodable { let baseURL: String; let token: String; let enabled: Bool? }
    /// `sha256` on list/stat is not trustworthy: cc ostore (2026-11-03) writes MD5 into that field.
    /// PUT still returns a real SHA-256 plus a real `md5`. Identity for skip/verify is MD5 only.
    private struct Entry: Decodable { let path: String; let type: String; let sha256: String?; let md5: String?; let size: Int? }
    private struct Listing: Decodable { let entries: [Entry] }
    private struct Persisted: Codable {
        var lastSuccessUnix: Double?
        var lastRun: Run?
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.clipvault.backup.ostore", qos: .utility)
    private var state = Status()
    private var pending: URL?
    /// Progress pings are coalesced: an upload run must not flood the SSE/status plane.
    private var lastPing: Double = 0
    private let pingInterval: Double = 2
    private var configURL: URL { DatabaseManager.resolveDataRoot().appendingPathComponent("config/ostore-backup.json") }
    private var stateURL: URL { DatabaseManager.resolveDataRoot().appendingPathComponent("config/ostore-backup.state.json") }

    private init() {
        // Restore the last finished run so the panel keeps its numbers across restarts.
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        state.lastSuccessUnix = saved.lastSuccessUnix
        state.lastRun = saved.lastRun
        if let run = state.lastRun {
            state.phase = run.phase
            state.host = run.host
            state.remoteObjects = run.remoteObjects
            state.remoteBytes = run.remoteBytes
            state.manifestObjects = 0
        }
    }

    func status() -> Status {
        lock.lock(); defer { lock.unlock() }
        var result = state
        let config = try? loadConfig()
        result.configured = config != nil
        result.enabled = config?.enabled ?? true
        result.baseURL = config?.baseURL
        result.queued = pending != nil
        result.pending = max(0, result.total - result.uploaded - result.skipped - result.failed)
        return result
    }

    func enqueue(root: URL) -> Bool {
        guard let config = try? loadConfig(), config.enabled != false else { return false }
        lock.lock()
        if state.inProgress { pending = root; lock.unlock(); return true }
        state.inProgress = true; state.phase = "queued"; state.lastError = nil
        lock.unlock()
        post()
        worker.async { self.run(root: root) }
        return true
    }

    /// Toggle the mirror step from the panel switch. Writes `enabled` back into the
    /// same 0600 config file and keeps baseURL / token (and any unknown keys) intact.
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        obj["enabled"] = on
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        guard (try? out.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if !on {
            lock.lock(); pending = nil; lock.unlock()
        }
        post()
        return true
    }

    private func loadConfig() throws -> Config {
        let c = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        guard let u = URL(string: c.baseURL), u.scheme == "https", u.host != nil, !c.token.isEmpty else {
            throw failure("无效的 ostore 配置（必须使用 HTTPS）")
        }
        return c
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "ClipVault.OstoreBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Mutate the live counters and ping the UI at most once per `pingInterval`.
    private func bump(_ f: (inout Status) -> Void) {
        lock.lock()
        f(&state)
        let now = Date().timeIntervalSince1970
        let ping = now - lastPing >= pingInterval
        if ping { lastPing = now }
        lock.unlock()
        if ping { post() }
    }

    /// Mutate without pinging (phase transitions post explicitly).
    private func update(_ f: (inout Status) -> Void) {
        lock.lock(); f(&state); lock.unlock()
    }

    private func post() {
        NotificationCenter.default.post(name: CloudDocsBackupService.statusChangedNotification, object: nil)
    }

    /// Local manifest identity. CloudDocs still names the snapshot with SHA-256; do not use this on the ostore wire.
    private func sha256(_ url: URL) throws -> String {
        try digest(url) { SHA256() }
    }
    /// ostore object identity. Matches Google Drive md5Checksum and the value cc now stores.
    private func md5(_ url: URL) throws -> String {
        try digest(url) { Insecure.MD5() }
    }
    private func digest<H: HashFunction>(_ url: URL, _ make: () -> H) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var s = make()
        while true { let d = h.readData(ofLength: 1024 * 1024); if d.isEmpty { break }; s.update(data: d) }
        return s.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// 32 hex chars. Accepts the real `md5` field, or a 32-char value stuffed into `sha256`.
    private func md5Hex(_ raw: String?) -> String? {
        guard let s = raw?.lowercased(), s.count == 32, s.allSatisfy(\.isHexDigit) else { return nil }
        return s
    }

    /// Logical cursor. Row identity, not sqlite page layout. VACUUM may rewrite the file.
    private struct LogicalCursor: Codable {
        var baseSha256: String
        var itemHashes: [String: String]
        var smallHashes: [String: String]
        /// IEEE bit pattern of the max timestamp already shipped, per append-only table.
        var untilBits: [String: String]
        var boundary: [String: [String]]
    }

    private struct DeltaPlan {
        var counts: [String: Int]
        var cursor: LogicalCursor
        var file: URL?
    }

    private var logicalURL: URL {
        DatabaseManager.resolveDataRoot().appendingPathComponent("config/ostore-logical.json")
    }
    private let appendTables = [
        ("compose_ops", "ts"),
        ("clipboard_events", "event_ts"),
        ("operation_logs", "ts"),
        ("reader_ops", "ts"),
        ("user_evaluations", "ts"),
        ("clip_link_ops", "ts"),
    ]
    private let smallTables = ["keepsake_meta", "clip_links", "share_links"]

    private func loadCursor() -> LogicalCursor? {
        guard let data = try? Data(contentsOf: logicalURL) else { return nil }
        return try? JSONDecoder().decode(LogicalCursor.self, from: data)
    }
    private func saveCursor(_ cursor: LogicalCursor) throws {
        let data = try JSONEncoder().encode(cursor)
        let url = logicalURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
    private func md5Text(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Byte-copy off the backup volume. Do not sqlite-open that path: File Provider and the
    /// publisher can still hold it, and VACUUM may be rewriting it.
    private func materialize(_ source: URL, to dest: URL) throws {
        var last = "无法复制备份数据库"
        for _ in 0..<6 {
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: source, to: dest)
                return
            } catch {
                last = error.localizedDescription
                sqlite3_sleep(300)
            }
        }
        throw failure(last)
    }
    private func immutableURI(_ url: URL) -> String {
        "file:" + url.path.replacingOccurrences(of: " ", with: "%20") + "?immutable=1"
    }
    private func openRead(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(immutableURI(url), &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw failure("无法读取备份数据库")
        }
        sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil)
        return db
    }
    private func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    private func canon(_ stmt: OpaquePointer, from start: Int32, count: Int32) -> String {
        var parts: [String] = []
        for i in start..<count {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL:
                parts.append("n")
            case SQLITE_INTEGER:
                parts.append("i:\(sqlite3_column_int64(stmt, i))")
            case SQLITE_FLOAT:
                parts.append("f:\(sqlite3_column_double(stmt, i).bitPattern)")
            case SQLITE_BLOB:
                let n = Int(sqlite3_column_bytes(stmt, i))
                if n == 0 || sqlite3_column_blob(stmt, i) == nil {
                    parts.append("b:")
                } else {
                    let data = Data(bytes: sqlite3_column_blob(stmt, i), count: n)
                    parts.append("b:" + md5Text(data.base64EncodedString()))
                }
            default:
                let text = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                parts.append("t:\(text)")
            }
        }
        return parts.joined(separator: "\u{1}")
    }
    /// id -> md5 of the whole row. Clipboard rows are updated in place, so a timestamp cursor is not enough.
    private func itemHashes(_ db: OpaquePointer) -> [String: String] {
        guard tableExists(db, "clipboard_items") else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM clipboard_items", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            guard !id.isEmpty else { continue }
            out[id] = md5Text(canon(stmt, from: 0, count: n))
        }
        return out
    }
    private func smallHash(_ db: OpaquePointer, _ table: String) -> String {
        guard tableExists(db, table) else { return "" }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(table) ORDER BY rowid", -1, &stmt, nil) == SQLITE_OK, let stmt else { return "" }
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        var all = ""
        while sqlite3_step(stmt) == SQLITE_ROW {
            all += canon(stmt, from: 0, count: n)
            all += "\n"
        }
        return md5Text(all)
    }
    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite \(rc)"
            sqlite3_free(err)
            throw failure("\(msg) :: \(sql.prefix(180))")
        }
    }
    /// Changed rows since `previous`. A missing cursor means "this file is the base"; no historical delta.
    private func makeDelta(artifact: URL, previous: LogicalCursor?, work: URL) throws -> DeltaPlan {
        let src = try openRead(artifact)
        var srcClosed = false
        defer { if !srcClosed { sqlite3_close(src) } }
        let items = itemHashes(src)
        var small: [String: String] = [:]
        for table in smallTables { small[table] = smallHash(src, table) }
        var untilBits: [String: String] = [:]
        var boundary: [String: [String]] = [:]
        for (table, ts) in appendTables where tableExists(src, table) {
            var stmt: OpaquePointer?
            let q = "SELECT max(\(ts)) FROM \(table)"
            guard sqlite3_prepare_v2(src, q, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { continue }
            let bits = sqlite3_column_double(stmt, 0).bitPattern
            untilBits[table] = String(bits)
            var ids: [String] = []
            var idStmt: OpaquePointer?
            let iq = "SELECT id FROM \(table) WHERE \(ts) = ?1"
            if sqlite3_prepare_v2(src, iq, -1, &idStmt, nil) == SQLITE_OK, let idStmt {
                sqlite3_bind_double(idStmt, 1, Double(bitPattern: bits))
                while sqlite3_step(idStmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(idStmt, 0) { ids.append(String(cString: c)) }
                }
                sqlite3_finalize(idStmt)
            }
            boundary[table] = ids
        }
        guard let previous else {
            return DeltaPlan(counts: [:], cursor: LogicalCursor(baseSha256: "", itemHashes: items, smallHashes: small, untilBits: untilBits, boundary: boundary), file: nil)
        }
        let presentAppend = appendTables.filter { tableExists(src, $0.0) }
        let presentSmall = smallTables.filter { tableExists(src, $0) }
        // Drop the read connection before attaching the same file. Two connections on a
        // file-provider copy return "database table is locked".
        sqlite3_close(src)
        srcClosed = true
        let deltaURL = work.appendingPathComponent("delta.db")
        var delta: OpaquePointer?
        guard sqlite3_open(deltaURL.path, &delta) == SQLITE_OK, let delta else { throw failure("无法创建增量库") }
        defer { sqlite3_close(delta) }
        try exec(delta, "ATTACH \(sqlQuote(immutableURI(artifact))) AS src")
        var counts: [String: Int] = [:]
        let changedItems = items.compactMap { id, hash -> String? in previous.itemHashes[id] == hash ? nil : id }
        let removed = previous.itemHashes.keys.filter { items[$0] == nil }
        if !changedItems.isEmpty {
            let list = changedItems.map(sqlQuote).joined(separator: ",")
            try exec(delta, "CREATE TABLE clipboard_items AS SELECT * FROM src.clipboard_items WHERE id IN (\(list))")
            counts["clipboard_items"] = changedItems.count
        }
        if !removed.isEmpty {
            try exec(delta, "CREATE TABLE IF NOT EXISTS clipboard_items_removed (id TEXT PRIMARY KEY)")
            try exec(delta, "INSERT INTO clipboard_items_removed (id) VALUES \(removed.map { "(\(sqlQuote($0)))" }.joined(separator: ","))")
            counts["clipboard_items_removed"] = removed.count
        }
        for (table, ts) in presentAppend {
            let bits = UInt64(previous.untilBits[table] ?? "") ?? 0
            let bound = previous.boundary[table] ?? []
            let sameTs = bound.isEmpty ? "0" : "(\(ts) = ?1 AND id NOT IN (\(bound.map(sqlQuote).joined(separator: ","))))"
            try exec(delta, "CREATE TABLE \(table) AS SELECT * FROM src.\(table) WHERE 0")
            let insert = "INSERT INTO \(table) SELECT * FROM src.\(table) WHERE \(ts) > ?1 OR \(sameTs)"
            var ins: OpaquePointer?
            guard sqlite3_prepare_v2(delta, insert, -1, &ins, nil) == SQLITE_OK, let ins else {
                throw failure("增量语句失败 \(table)")
            }
            sqlite3_bind_double(ins, 1, Double(bitPattern: bits))
            guard sqlite3_step(ins) == SQLITE_DONE else {
                sqlite3_finalize(ins)
                throw failure("增量复制失败 \(table)")
            }
            sqlite3_finalize(ins)
            var n = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(delta, "SELECT COUNT(*) FROM \(table)", -1, &countStmt, nil) == SQLITE_OK, let countStmt {
                if sqlite3_step(countStmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(countStmt, 0)) }
                sqlite3_finalize(countStmt)
            }
            if n == 0 { try exec(delta, "DROP TABLE \(table)") }
            else { counts[table] = n }
        }
        for table in presentSmall where small[table] != previous.smallHashes[table] {
            try exec(delta, "CREATE TABLE \(table) AS SELECT * FROM src.\(table)")
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(delta, "SELECT COUNT(*) FROM \(table)", -1, &countStmt, nil) == SQLITE_OK, let countStmt {
                if sqlite3_step(countStmt) == SQLITE_ROW { counts[table] = Int(sqlite3_column_int64(countStmt, 0)) }
                sqlite3_finalize(countStmt)
            }
        }
        let cursor = LogicalCursor(baseSha256: previous.baseSha256, itemHashes: items, smallHashes: small, untilBits: untilBits, boundary: boundary)
        if counts.isEmpty {
            try? FileManager.default.removeItem(at: deltaURL)
            return DeltaPlan(counts: counts, cursor: cursor, file: nil)
        }
        return DeltaPlan(counts: counts, cursor: cursor, file: deltaURL)
    }
    private func request(_ config: Config, path: String, method: String = "GET", file: URL? = nil) throws -> (Int, Data) {
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw failure("无效 URL") }
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = method; req.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        var response: URLResponse?; var body: Data?; var error: Error?
        let done: (Data?, URLResponse?, Error?) -> Void = { d, r, e in body = d; response = r; error = e; sem.signal() }
        let task = file.map { URLSession.shared.uploadTask(with: req, fromFile: $0, completionHandler: done) }
            ?? URLSession.shared.dataTask(with: req, completionHandler: done)
        task.resume(); sem.wait()
        if let error = error { throw error }
        guard let http = response as? HTTPURLResponse else { throw failure("ostore 无响应") }
        return (http.statusCode, body ?? Data())
    }
    private func escaped(_ s: String) -> String {
        s.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? ""
        }.joined(separator: "/")
    }
    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Freeze the live counters into `lastRun` and persist them.
    private func finish(ok: Bool, started: Double, error: String?, remote: (objects: Int, bytes: Int)?) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        state.phase = ok ? "ok" : "error"
        state.lastError = error
        state.durationSeconds = now - started
        if ok { state.lastSuccessUnix = now }
        if let remote = remote { state.remoteObjects = remote.objects; state.remoteBytes = remote.bytes }
        var run = Run()
        run.phase = state.phase
        run.host = state.host
        run.total = state.total
        run.uploaded = state.uploaded
        run.skipped = state.skipped
        run.failed = state.failed
        run.uploadedBytes = state.uploadedBytes
        run.skippedBytes = state.skippedBytes
        run.remoteObjects = state.remoteObjects
        run.remoteBytes = state.remoteBytes
        run.startedUnix = started
        run.finishedUnix = now
        run.durationSeconds = now - started
        run.error = error
        state.lastRun = run
        let saved = Persisted(lastSuccessUnix: state.lastSuccessUnix, lastRun: run)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(saved) {
            let url = stateURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        UiMetrics.shared.emit("backup_ostore_run", durMs: (now - started) * 1000, ok: ok,
                              payload: ["n": run.total, "bytes": run.uploadedBytes,
                                        "applied": run.uploaded, "reused": run.skipped,
                                        "miss": run.failed])
        post()
    }

    private func run(root: URL) {
        let fm = FileManager.default
        let work = DatabaseManager.resolveDataRoot().appendingPathComponent(".backup_work/ostore-" + UUID().uuidString)
        let started = Date().timeIntervalSince1970
        defer {
            try? fm.removeItem(at: work)
            lock.lock()
            let next = pending; pending = nil
            if next == nil { state.inProgress = false }
            lock.unlock()
            post()
            if let next = next { worker.async { self.run(root: next) } }
        }
        do {
            let host = ClipHostIdentity.id
            update {
                $0.phase = "prepare"; $0.host = host; $0.lastError = nil
                $0.total = 0; $0.uploaded = 0; $0.skipped = 0; $0.failed = 0; $0.pending = 0
                $0.uploadedBytes = 0; $0.skippedBytes = 0
                $0.manifestObjects = 0; $0.manifestBytes = 0
                $0.remoteObjects = 0; $0.remoteBytes = 0
                $0.startedUnix = started; $0.durationSeconds = nil
            }
            lock.lock(); lastPing = 0; lock.unlock()  // first counter change pings immediately
            post()
            let config = try loadConfig()
            guard !host.isEmpty, host != ".", host != "..", !host.contains("/") else { throw failure("无效 hostId") }
            let source = root.appendingPathComponent("hosts/" + host)
            let manifestURL = source.appendingPathComponent("latest/MANIFEST.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(CloudDocsBackupService.Manifest.self, from: manifestData)
            guard manifest.host == host, manifest.blobsVerified == true, let names = manifest.blobFiles, manifest.blobCount == names.count else { throw failure("本地备份清单不完整") }
            guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw failure("备份清单包含无效文件名") }
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            // Vacuumed cloud copy. Its page layout is not the increment. Row diffs are.
            let db = source.appendingPathComponent("latest/clipflow.db")
            guard try sha256(db) == manifest.sha256 else { throw failure("备份数据库与清单不一致，请重试") }
            // The published file can still be locked by the backup writer or a file provider.
            // Query a private consistent copy. VACUUM of the original does not matter.
            let artifact = work.appendingPathComponent("artifact.db")
            try materialize(db, to: artifact)
            let previous = loadCursor()
            var plan = try makeDelta(artifact: artifact, previous: previous, work: work)
            let needBase = previous == nil || previous?.baseSha256.isEmpty == true
            if needBase { plan.cursor.baseSha256 = manifest.sha256 }
            let m = work.appendingPathComponent("MANIFEST.json"); try manifestData.write(to: m)
            let checkpointURL = work.appendingPathComponent("DB-CHECKPOINT.json")
            let prefix = "clipvault/backup/hosts/" + host
            let (code, data) = try request(config, path: "/api/list?path=" + escaped(prefix) + "&recursive=1&checksums=1")
            var remote: [String: String] = [:]
            if code == 200 {
                for entry in try JSONDecoder().decode(Listing.self, from: data).entries where entry.type == "file" {
                    if let sum = md5Hex(entry.md5) ?? md5Hex(entry.sha256) { remote[entry.path] = sum }
                }
            } else if code != 404 { throw failure("ostore 列表失败 HTTP \(code)") }
            var extra = 2 // checkpoint + blob manifest
            if needBase { extra += 1 }
            if plan.file != nil { extra += 1 }
            bump {
                $0.manifestObjects = names.count
                $0.manifestBytes = manifest.blobBytes ?? 0
                $0.total = names.count + extra
                $0.phase = "upload"
            }
            func upload(_ local: URL, _ key: String) throws {
                let size = fileSize(local)
                let digest = try md5(local)
                if remote[key] == digest {
                    bump { $0.skipped += 1; $0.skippedBytes += size }
                    return
                }
                let (status, data) = try request(config, path: "/api/files/" + escaped(key), method: "PUT", file: local)
                guard (200..<300).contains(status) else { throw failure("ostore 上传失败 HTTP \(status)") }
                struct Reply: Decodable { let md5: String?; let sha256: String? }
                let reply = try? JSONDecoder().decode(Reply.self, from: data)
                // PUT `sha256` is still the real SHA-256. Only `md5`, or a 32-hex value in that field, counts.
                guard md5Hex(reply?.md5) == digest || md5Hex(reply?.sha256) == digest else { throw failure("ostore 上传校验失败") }
                bump { $0.uploaded += 1; $0.uploadedBytes += size }
            }
            let uploads = OperationQueue()
            uploads.maxConcurrentOperationCount = 8
            let errorLock = NSLock()
            var firstError: Error?
            for name in names {
                uploads.addOperation {
                    errorLock.lock(); let failed = firstError != nil; errorLock.unlock()
                    if failed { return }
                    do { try upload(source.appendingPathComponent("blobs/" + name), prefix + "/blobs/" + name) }
                    catch {
                        errorLock.lock()
                        if firstError == nil { firstError = error }
                        errorLock.unlock()
                        self.bump { $0.failed += 1 }
                    }
                }
            }
            uploads.waitUntilAllOperationsAreFinished()
            if let error = firstError { throw error }
            if needBase {
                try upload(db, prefix + "/databases/" + manifest.sha256 + ".db")
            } else if let delta = plan.file {
                let sum = try md5(delta)
                try upload(delta, prefix + "/deltas/" + sum)
                plan.cursor.baseSha256 = previous?.baseSha256 ?? manifest.sha256
            }
            let countObject: [String: Any] = plan.counts.reduce(into: [:]) { $0[$1.key] = $1.value }
            var checkpoint: [String: Any] = [
                "version": 2,
                "baseSha256": plan.cursor.baseSha256,
                "counts": countObject,
            ]
            if let delta = plan.file {
                checkpoint["deltaMd5"] = try md5(delta)
                checkpoint["deltaBytes"] = fileSize(delta)
            }
            let checkpointData = try JSONSerialization.data(withJSONObject: checkpoint, options: [.prettyPrinted, .sortedKeys])
            try checkpointData.write(to: checkpointURL)
            try upload(checkpointURL, prefix + "/latest/DB-CHECKPOINT.json")
            try upload(m, prefix + "/latest/MANIFEST.json")
            try saveCursor(plan.cursor)
            // One extra listing so the panel can show what actually sits off-site
            // instead of only what this run moved. Never fails the run.
            var remoteTotals: (objects: Int, bytes: Int)?
            if let (rcode, rdata) = try? request(config, path: "/api/list?path=" + escaped(prefix) + "&recursive=1"), rcode == 200,
               let entries = try? JSONDecoder().decode(Listing.self, from: rdata).entries {
                let files = entries.filter { $0.type == "file" }
                remoteTotals = (files.count, files.reduce(0) { $0 + ($1.size ?? 0) })
            }
            finish(ok: true, started: started, error: nil, remote: remoteTotals)
        } catch {
            finish(ok: false, started: started, error: error.localizedDescription, remote: nil)
            print("[OstoreBackup] \(error.localizedDescription)")
        }
    }
}
