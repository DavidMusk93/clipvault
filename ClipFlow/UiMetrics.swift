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
          ok INTEGER,
          payload TEXT,
          session TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS ui_events_ts ON ui_events(ts);")
        exec("CREATE INDEX IF NOT EXISTS ui_events_name_ts ON ui_events(name, ts);")
    }

    /// Server-side emit (sync cycles). Same sanitizer as HTTP ingest. Never synced.
    func emit(_ name: String, durMs: Double? = nil, ok: Bool? = nil, payload: [String: Any]? = nil) {
        var ev: [String: Any] = [
            "name": name,
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if let durMs { ev["dur_ms"] = durMs }
        if let ok { ev["ok"] = ok }
        if let payload { ev["payload"] = payload }
        _ = ingest(events: [ev], defaultSession: "sync")
    }

    /// Returns accepted count and drop reason if the whole request is rejected.
    func ingest(events: [[String: Any]], defaultSession: String) -> (ok: Bool, accepted: Int, message: String?) {
        if events.count > Self.maxEventsPerRequest {
            return (false, 0, "too many events")
        }
        var rows: [(Int64, String, Double?, Int?, String?, String)] = []
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
            let dur = Self.finiteDouble(raw["dur_ms"])
            let ok: Int?
            if let b = raw["ok"] as? Bool { ok = b ? 1 : 0 }
            else if let n = raw["ok"] as? Int { ok = n == 0 ? 0 : 1 }
            else { ok = nil }
            var session = (raw["session"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if session.isEmpty { session = defaultSession }
            if session.count > 80 { session = String(session.prefix(80)) }
            let payload = sanitizePayload(raw["payload"])
            if payload == nil, raw["payload"] != nil, !(raw["payload"] is NSNull) {
                continue
            }
            rows.append((ts, name, dur, ok, payload, session))
        }
        guard !rows.isEmpty else { return (true, 0, nil) }
        queue.sync {
            exec("BEGIN IMMEDIATE;")
            let sql = "INSERT INTO ui_events(ts, name, dur_ms, ok, payload, session) VALUES (?,?,?,?,?,?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                for row in rows {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, row.0)
                    sqlite3_bind_text(stmt, 2, (row.1 as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let d = row.2 { sqlite3_bind_double(stmt, 3, d) } else { sqlite3_bind_null(stmt, 3) }
                    if let o = row.3 { sqlite3_bind_int(stmt, 4, Int32(o)) } else { sqlite3_bind_null(stmt, 4) }
                    if let p = row.4 { sqlite3_bind_text(stmt, 5, (p as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
                    sqlite3_bind_text(stmt, 6, (row.5 as NSString).utf8String, -1, SQLITE_TRANSIENT)
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
        queue.sync {
            let sql = """
            SELECT name, COUNT(*) AS n,
                   AVG(dur_ms) AS avg_ms,
                   MIN(dur_ms) AS min_ms,
                   MAX(dur_ms) AS max_ms
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
                    if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                        row["avg_ms"] = sqlite3_column_double(stmt, 2)
                    }
                    if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                        row["min_ms"] = sqlite3_column_double(stmt, 3)
                    }
                    if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                        row["max_ms"] = sqlite3_column_double(stmt, 4)
                    }
                    names.append(row)
                }
                sqlite3_finalize(stmt)
            }
        }
        return [
            "ok": true,
            "from": Int(from),
            "to": Int(to),
            "total": Int(total),
            "names": names,
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

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
