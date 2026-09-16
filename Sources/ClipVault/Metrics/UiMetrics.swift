import Foundation
import SQLite3

/// Local-only UI metrics. Separate file from clipflow.db so it never rides
/// CloudDocs trx / backup hosts. No note body, title, or search strings.
final class UiMetrics {
    static let shared = UiMetrics()
    static let fileName = "ui-metrics.db"
    static let maxEventsPerRequest = 100
    static let maxPayloadBytes = 2048
    static let retentionMs: Int64 = 30 * 24 * 3600 * 1000

    private static let nameRe = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{1,63}$")
    private static let forbiddenPayload = Set([
        "body", "title", "markdown", "text", "content", "html",
        "query", "q", "search", "note", "src", "md", "excerpt", "url",
    ])
    private static let allowedPayload = Set([
        "mode", "ratio", "chars", "bytes", "n", "value", "interaction", "q_len",
        "kind", "phase", "reason", "lag", "host",
        "w", "h", "nodes", "dy",
        "fds", "rss", "unix", "sse", "rlim",
        "route", "proto", "status",
        "compiled", "reused",
        "trace", "cols", "vp", "vis",
    ])

    private let queue = DispatchQueue(label: "clipvault.ui-metrics")
    private var db: OpaquePointer?
    private var ingestCount = 0

    private init() {
        let root = DatabaseManager.resolveDataRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(Self.fileName)
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let handle else {
            fputs("[UiMetrics] open failed \(path.path)\n", stderr)
            return
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=5000;")
        exec("PRAGMA temp_store=MEMORY;")
        exec("""
        CREATE TABLE IF NOT EXISTS ui_events (
          id INTEGER PRIMARY KEY,
          ts INTEGER NOT NULL,
          name TEXT NOT NULL,
          dur_ms REAL,
          value REAL,
          ok INTEGER,
          over INTEGER,
          payload TEXT,
          session TEXT NOT NULL,
          trace TEXT
        );
        """)
        // Additive migration for pre-v2 databases.
        ensureColumn("ui_events", "value", "REAL")
        ensureColumn("ui_events", "over", "INTEGER")
        ensureColumn("ui_events", "trace", "TEXT")
        exec("CREATE INDEX IF NOT EXISTS ui_events_ts ON ui_events(ts);")
        exec("CREATE INDEX IF NOT EXISTS ui_events_name_ts ON ui_events(name, ts);")
        exec("CREATE INDEX IF NOT EXISTS ui_events_trace ON ui_events(trace);")
    }

    /// Drain clipvault-http JSONL spool into ui_events. Never blocks the hop.
    func drainHttpFront() {
        let root = DatabaseManager.resolveDataRoot()
        let live = root.appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("http-metrics.jsonl")
        let drain = live.deletingLastPathComponent().appendingPathComponent("http-metrics.jsonl.drain")
        let fm = FileManager.default
        guard fm.fileExists(atPath: live.path) else { return }
        try? fm.removeItem(at: drain)
        do {
            try fm.moveItem(at: live, to: drain)
        } catch {
            return
        }
        guard let raw = try? String(contentsOf: drain, encoding: .utf8) else {
            try? fm.removeItem(at: drain)
            return
        }
        try? fm.removeItem(at: drain)
        var events: [[String: Any]] = []
        events.reserveCapacity(64)
        for line in raw.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            events.append(obj)
            if events.count >= Self.maxEventsPerRequest {
                _ = ingest(events: events, defaultSession: "http")
                events.removeAll(keepingCapacity: true)
            }
        }
        if !events.isEmpty {
            _ = ingest(events: events, defaultSession: "http")
        }
    }

    /// Server-side emit (sync cycles). Same sanitizer as HTTP ingest. Never synced.
    func emit(_ name: String, durMs: Double? = nil, value: Double? = nil, ok: Bool? = nil, payload: [String: Any]? = nil) {
        var ev: [String: Any] = [
            "name": name,
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if let durMs { ev["dur_ms"] = durMs }
        if let value { ev["value"] = value }
        if let ok { ev["ok"] = ok }
        if let payload { ev["payload"] = payload }
        _ = ingest(events: [ev], defaultSession: "sync")
    }

    private struct Row {
        let ts: Int64
        let name: String
        let dur: Double?
        let value: Double?
        let ok: Int?
        let over: Int?
        let payload: String?
        let session: String
        let trace: String?
    }

    /// Returns accepted count and drop reason if the whole request is rejected.
    func ingest(events: [[String: Any]], defaultSession: String) -> (ok: Bool, accepted: Int, message: String?) {
        if events.count > Self.maxEventsPerRequest {
            return (false, 0, "too many events")
        }
        var rows: [Row] = []
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for raw in events {
            guard let name = raw["name"] as? String,
                  Self.nameRe.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil else {
                continue
            }
            let ts: Int64
            if let n = raw["ts"] as? Int64 {
                ts = n
            } else if let n = raw["ts"] as? Int {
                ts = Int64(n)
            } else if let n = raw["ts"] as? Double {
                ts = Int64(n)
            } else {
                ts = now
            }
            var session = (raw["session"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if session.isEmpty { session = defaultSession }
            if session.count > 80 { session = String(session.prefix(80)) }
            let payload = sanitizePayload(raw["payload"])
            if payload == nil, raw["payload"] != nil, !(raw["payload"] is NSNull) {
                continue
            }
            rows.append(Row(
                ts: ts,
                name: name,
                dur: Self.finiteDouble(raw["dur_ms"]),
                value: Self.finiteDouble(raw["value"]),
                ok: Self.boolInt(raw["ok"]),
                over: Self.boolInt(raw["over"]),
                payload: payload,
                session: session,
                trace: sanitizeTrace(raw["trace"])
            ))
        }
        guard !rows.isEmpty else { return (true, 0, nil) }
        queue.sync {
            exec("BEGIN IMMEDIATE;")
            let sql = "INSERT INTO ui_events(ts, name, dur_ms, value, ok, over, payload, session, trace) VALUES (?,?,?,?,?,?,?,?,?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                for row in rows {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, row.ts)
                    sqlite3_bind_text(stmt, 2, (row.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let d = row.dur { sqlite3_bind_double(stmt, 3, d) } else { sqlite3_bind_null(stmt, 3) }
                    if let v = row.value { sqlite3_bind_double(stmt, 4, v) } else { sqlite3_bind_null(stmt, 4) }
                    if let o = row.ok { sqlite3_bind_int(stmt, 5, Int32(o)) } else { sqlite3_bind_null(stmt, 5) }
                    if let o = row.over { sqlite3_bind_int(stmt, 6, Int32(o)) } else { sqlite3_bind_null(stmt, 6) }
                    if let p = row.payload { sqlite3_bind_text(stmt, 7, (p as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
                    sqlite3_bind_text(stmt, 8, (row.session as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let t = row.trace { sqlite3_bind_text(stmt, 9, (t as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            exec("COMMIT;")
            ingestCount += 1
            if ingestCount % 40 == 1 {
                pruneLocked()
            }
        }
        return (true, rows.count, nil)
    }

    func summary(fromMs: Int64?, toMs: Int64?) -> [String: Any] {
        let to = toMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let from = fromMs ?? (to - 24 * 3600 * 1000)
        var names: [[String: Any]] = []
        var total: Int64 = 0
        var durPct: [String: (Double, Double, Double)] = [:]
        var valPct: [String: (Double, Double, Double)] = [:]
        var routes: [[String: Any]] = []
        queue.sync {
            let sql = """
            SELECT name, COUNT(*) AS n,
                   SUM(CASE WHEN ok IS NULL THEN 0 ELSE 1 END) AS ok_n,
                   SUM(CASE WHEN ok = 1 THEN 1 ELSE 0 END) AS ok_yes,
                   AVG(dur_ms) AS avg_ms, MIN(dur_ms) AS min_ms, MAX(dur_ms) AS max_ms,
                   AVG(value) AS avg_v, MIN(value) AS min_v, MAX(value) AS max_v
            FROM ui_events
            WHERE ts >= ? AND ts <= ?
            GROUP BY name
            ORDER BY n DESC;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                sqlite3_bind_int64(stmt, 1, from)
                sqlite3_bind_int64(stmt, 2, to)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                    let name = String(cString: cstr)
                    let n = sqlite3_column_int64(stmt, 1)
                    total += n
                    var row: [String: Any] = ["name": name, "n": Int(n)]
                    let okN = sqlite3_column_int64(stmt, 2)
                    let okYes = sqlite3_column_int64(stmt, 3)
                    if okN > 0 {
                        row["ok_n"] = Int(okN)
                        row["ok_rate"] = Double(okYes) / Double(okN)
                    }
                    if let v = Self.columnDouble(stmt, 4) { row["avg_ms"] = v }
                    if let v = Self.columnDouble(stmt, 5) { row["min_ms"] = v }
                    if let v = Self.columnDouble(stmt, 6) { row["max_ms"] = v }
                    if let v = Self.columnDouble(stmt, 7) { row["avg_value"] = v }
                    if let v = Self.columnDouble(stmt, 8) { row["min_value"] = v }
                    if let v = Self.columnDouble(stmt, 9) { row["max_value"] = v }
                    names.append(row)
                }
                sqlite3_finalize(stmt)
            }
            durPct = percentileLocked(column: "dur_ms", from: from, to: to)
            valPct = percentileLocked(column: "value", from: from, to: to)
            routes = httpRoutesLocked(from: from, to: to)
        }
        for i in names.indices {
            let name = names[i]["name"] as? String ?? ""
            if let p = durPct[name] {
                names[i]["p50_ms"] = p.0
                names[i]["p95_ms"] = p.1
                names[i]["p99_ms"] = p.2
            }
            if let p = valPct[name] {
                names[i]["value_p50"] = p.0
                names[i]["value_p95"] = p.1
                names[i]["value_p99"] = p.2
            }
        }
        return [
            "ok": true,
            "from": Int(from),
            "to": Int(to),
            "total": Int(total),
            "names": names,
            "routes": routes,
        ]
    }

    /// Exact p50/p95/p99 for one numeric column, per name, via window functions.
    private func percentileLocked(column: String, from: Int64, to: Int64) -> [String: (Double, Double, Double)] {
        var out: [String: (Double, Double, Double)] = [:]
        let sql = """
        WITH o AS (
          SELECT name, \(column) AS v,
                 ROW_NUMBER() OVER (PARTITION BY name ORDER BY \(column)) AS rn,
                 COUNT(*) OVER (PARTITION BY name) AS cnt
          FROM ui_events
          WHERE ts >= ? AND ts <= ? AND \(column) IS NOT NULL
        )
        SELECT name,
               MAX(CASE WHEN rn = MAX(1, CAST(cnt * 0.50 AS INTEGER)) THEN v END),
               MAX(CASE WHEN rn = MAX(1, CAST(cnt * 0.95 AS INTEGER)) THEN v END),
               MAX(CASE WHEN rn = MAX(1, CAST(cnt * 0.99 AS INTEGER)) THEN v END)
        FROM o GROUP BY name;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_int64(stmt, 1, from)
            sqlite3_bind_int64(stmt, 2, to)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                let name = String(cString: cstr)
                let p50 = sqlite3_column_double(stmt, 1)
                let p95 = sqlite3_column_double(stmt, 2)
                let p99 = sqlite3_column_double(stmt, 3)
                out[name] = (p50, p95, p99)
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    /// http_req split by route + status so a slow/erroring endpoint is visible.
    private func httpRoutesLocked(from: Int64, to: Int64) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let sql = """
        SELECT json_extract(payload, '$.route') AS route,
               json_extract(payload, '$.n') AS status,
               COUNT(*) AS n,
               AVG(dur_ms) AS avg_ms,
               MAX(dur_ms) AS max_ms,
               SUM(CASE WHEN ok = 0 THEN 1 ELSE 0 END) AS errs
        FROM ui_events
        WHERE name = 'http_req' AND ts >= ? AND ts <= ? AND payload IS NOT NULL
        GROUP BY route, status
        ORDER BY n DESC LIMIT 80;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_int64(stmt, 1, from)
            sqlite3_bind_int64(stmt, 2, to)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [
                    "route": sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "—",
                    "n": Int(sqlite3_column_int64(stmt, 2)),
                ]
                if let s = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) { row["status"] = s }
                if let v = Self.columnDouble(stmt, 3) { row["avg_ms"] = v }
                if let v = Self.columnDouble(stmt, 4) { row["max_ms"] = v }
                if let v = Self.columnDouble(stmt, 5) { row["errs"] = v }
                out.append(row)
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    /// Last N rows for local debugging. No note body. name must match the ingest regex.
    func recent(name: String?, limit: Int, fromMs: Int64?, toMs: Int64?) -> [String: Any] {
        let cap = min(max(limit, 1), 200)
        let to = toMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let from = fromMs ?? (to - 24 * 3600 * 1000)
        var want: String? = nil
        if let name, !name.isEmpty {
            let range = NSRange(location: 0, length: name.utf16.count)
            if Self.nameRe.firstMatch(in: name, range: range) != nil {
                want = name
            } else {
                return ["ok": false, "message": "bad name"]
            }
        }
        var events: [[String: Any]] = []
        queue.sync {
            var sql = """
            SELECT ts, name, dur_ms, value, ok, over, payload, session, trace
            FROM ui_events
            WHERE ts >= ? AND ts <= ?
            """
            if want != nil { sql += " AND name = ?" }
            sql += " ORDER BY ts DESC LIMIT ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                var i: Int32 = 1
                sqlite3_bind_int64(stmt, i, from); i += 1
                sqlite3_bind_int64(stmt, i, to); i += 1
                if let want {
                    sqlite3_bind_text(stmt, i, (want as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    i += 1
                }
                sqlite3_bind_int(stmt, i, Int32(cap))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var row: [String: Any] = [
                        "ts": Int(sqlite3_column_int64(stmt, 0)),
                        "name": sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                        "session": sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "",
                    ]
                    if let v = Self.columnDouble(stmt, 2) { row["dur_ms"] = v }
                    if let v = Self.columnDouble(stmt, 3) { row["value"] = v }
                    if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                        row["ok"] = sqlite3_column_int(stmt, 4) != 0
                    }
                    if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                        row["over"] = sqlite3_column_int(stmt, 5) != 0
                    }
                    if sqlite3_column_type(stmt, 6) != SQLITE_NULL,
                       let p = sqlite3_column_text(stmt, 6) {
                        let raw = String(cString: p)
                        if let data = raw.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) {
                            row["payload"] = obj
                        }
                    }
                    if let t = sqlite3_column_text(stmt, 8).map({ String(cString: $0) }), !t.isEmpty {
                        row["trace"] = t
                    }
                    events.append(row)
                }
                sqlite3_finalize(stmt)
            }
        }
        return [
            "ok": true,
            "from": Int(from),
            "to": Int(to),
            "n": events.count,
            "events": events,
        ]
    }

    private func pruneLocked() {
        let cut = Int64(Date().timeIntervalSince1970 * 1000) - Self.retentionMs
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM ui_events WHERE ts < ? LIMIT 500;", -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_int64(stmt, 1, cut)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func sanitizePayload(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let dict = raw as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in dict {
            let key = k.lowercased()
            if Self.forbiddenPayload.contains(key) { return nil }
            guard Self.allowedPayload.contains(key) else { continue }
            if let s = v as? String {
                if s.count > 32 { return nil }
                out[key] = s
            } else if let n = v as? NSNumber {
                out[key] = n
            } else if v is Bool {
                out[key] = v
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: []),
              data.count <= Self.maxPayloadBytes,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    private static func finiteDouble(_ raw: Any?) -> Double? {
        if let n = raw as? Double, n.isFinite { return n }
        if let n = raw as? Int { return Double(n) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Bool or 0/1 → 0/1, else nil (SQLite has no bool).
    private static func boolInt(_ raw: Any?) -> Int? {
        if let b = raw as? Bool { return b ? 1 : 0 }
        if let n = raw as? Int { return n == 0 ? 0 : 1 }
        if let n = raw as? NSNumber { return n.intValue == 0 ? 0 : 1 }
        return nil
    }

    /// Read a possibly-NULL REAL column.
    private static func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard let stmt, sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    /// Trace ids are opaque tokens; keep them short and attribute-free.
    private func sanitizeTrace(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return String(s.prefix(64))
    }

    /// Additive column migration (older ui-metrics.db files).
    private func ensureColumn(_ table: String, _ name: String, _ type: String) {
        guard let db else { return }
        var has = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK, let stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) == name {
                    has = true
                    break
                }
            }
            sqlite3_finalize(stmt)
        }
        if !has {
            exec("ALTER TABLE \(table) ADD COLUMN \(name) \(type);")
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
