import Foundation
import SQLite3

/// Local-only UI metrics. Separate file from clipflow.db so it never rides
/// CloudDocs trx / backup hosts. No note body, title, or search strings.
final class UiMetrics {
    static let shared = UiMetrics()
    static let fileName = "ui-metrics.db"
    static let maxEventsPerRequest = 100
    static let maxPayloadBytes = 2048
    /// Rollup window (aggregates survive this long). Raw detail is shorter.
    static let retentionMs: Int64 = 30 * 24 * 3600 * 1000
    static let detailRetentionMs: Int64 = 7 * 24 * 3600 * 1000

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
        exec("PRAGMA auto_vacuum=INCREMENTAL;")
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
        exec("""
        CREATE TABLE IF NOT EXISTS ui_rollup (
          hour INTEGER NOT NULL,
          name TEXT NOT NULL,
          n INTEGER NOT NULL,
          ok_n INTEGER NOT NULL,
          ok_yes INTEGER NOT NULL,
          over_n INTEGER NOT NULL,
          sum_dur REAL, min_dur REAL, max_dur REAL, dur_n INTEGER NOT NULL DEFAULT 0,
          sum_value REAL, min_value REAL, max_value REAL, value_n INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (hour, name)
        );
        """)
        exec("CREATE TABLE IF NOT EXISTS ui_meta (k TEXT PRIMARY KEY, v INTEGER NOT NULL);")
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

    private struct Agg {
        var n = 0
        var okN = 0
        var okYes = 0
        var overN = 0
        var sumDur = 0.0
        var minDur: Double?
        var maxDur: Double?
        var durN = 0
        var sumValue = 0.0
        var minValue: Double?
        var maxValue: Double?
        var valueN = 0
    }

    func summary(fromMs: Int64?, toMs: Int64?) -> [String: Any] {
        let to = toMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let from = fromMs ?? (to - 24 * 3600 * 1000)
        var agg: [String: Agg] = [:]
        var durPct: [String: (Double, Double, Double)] = [:]
        var valPct: [String: (Double, Double, Double)] = [:]
        var routes: [[String: Any]] = []
        queue.sync {
            // Recent detail (exact) …
            let detailSQL = """
            SELECT name, COUNT(*) AS n,
                   SUM(CASE WHEN ok IS NULL THEN 0 ELSE 1 END) AS ok_n,
                   SUM(CASE WHEN ok = 1 THEN 1 ELSE 0 END) AS ok_yes,
                   SUM(CASE WHEN over = 1 THEN 1 ELSE 0 END) AS over_n,
                   SUM(dur_ms), MIN(dur_ms), MAX(dur_ms),
                   SUM(CASE WHEN dur_ms IS NULL THEN 0 ELSE 1 END),
                   SUM(value), MIN(value), MAX(value),
                   SUM(CASE WHEN value IS NULL THEN 0 ELSE 1 END)
            FROM ui_events
            WHERE ts >= ? AND ts <= ?
            GROUP BY name;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, detailSQL, -1, &stmt, nil) == SQLITE_OK, let stmt {
                sqlite3_bind_int64(stmt, 1, from)
                sqlite3_bind_int64(stmt, 2, to)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                    var a = Agg()
                    a.n = Int(sqlite3_column_int64(stmt, 1))
                    a.okN = Int(sqlite3_column_int64(stmt, 2))
                    a.okYes = Int(sqlite3_column_int64(stmt, 3))
                    a.overN = Int(sqlite3_column_int64(stmt, 4))
                    a.sumDur = Self.columnDouble(stmt, 5) ?? 0
                    a.minDur = Self.columnDouble(stmt, 6)
                    a.maxDur = Self.columnDouble(stmt, 7)
                    a.durN = Int(sqlite3_column_int64(stmt, 8))
                    a.sumValue = Self.columnDouble(stmt, 9) ?? 0
                    a.minValue = Self.columnDouble(stmt, 10)
                    a.maxValue = Self.columnDouble(stmt, 11)
                    a.valueN = Int(sqlite3_column_int64(stmt, 12))
                    agg[String(cString: cstr)] = a
                }
                sqlite3_finalize(stmt)
            }
            // … plus older hourly rollups (aggregates; no exact percentiles).
            mergeRollupLocked(from: from, to: to, into: &agg)
            durPct = percentileLocked(column: "dur_ms", from: from, to: to)
            valPct = percentileLocked(column: "value", from: from, to: to)
            routes = httpRoutesLocked(from: from, to: to)
        }
        var names: [[String: Any]] = []
        var total = 0
        for (name, a) in agg {
            total += a.n
            var row: [String: Any] = ["name": name, "n": a.n]
            if a.okN > 0 {
                row["ok_n"] = a.okN
                row["ok_rate"] = Double(a.okYes) / Double(a.okN)
            }
            if a.overN > 0 { row["over_n"] = a.overN }
            if a.durN > 0 {
                row["avg_ms"] = a.sumDur / Double(a.durN)
                if let mn = a.minDur { row["min_ms"] = mn }
                if let mx = a.maxDur { row["max_ms"] = mx }
            }
            if a.valueN > 0 {
                row["avg_value"] = a.sumValue / Double(a.valueN)
                if let mn = a.minValue { row["min_value"] = mn }
                if let mx = a.maxValue { row["max_value"] = mx }
            }
            if let p = durPct[name] {
                row["p50_ms"] = p.0
                row["p95_ms"] = p.1
                row["p99_ms"] = p.2
            }
            if let p = valPct[name] {
                row["value_p50"] = p.0
                row["value_p95"] = p.1
                row["value_p99"] = p.2
            }
            names.append(row)
        }
        names.sort { ($0["n"] as? Int ?? 0) > ($1["n"] as? Int ?? 0) }
        return [
            "ok": true,
            "from": Int(from),
            "to": Int(to),
            "total": total,
            "names": names,
            "routes": routes,
        ]
    }

    private func mergeRollupLocked(from: Int64, to: Int64, into agg: inout [String: Agg]) {
        let fromHour = from / 3_600_000
        let toHour = to / 3_600_000
        let sql = """
        SELECT name, SUM(n), SUM(ok_n), SUM(ok_yes), SUM(over_n),
               SUM(sum_dur), MIN(min_dur), MAX(max_dur), SUM(dur_n),
               SUM(sum_value), MIN(min_value), MAX(max_value), SUM(value_n)
        FROM ui_rollup WHERE hour >= ? AND hour <= ?
        GROUP BY name;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_int64(stmt, 1, fromHour)
            sqlite3_bind_int64(stmt, 2, toHour)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                let name = String(cString: cstr)
                var a = agg[name] ?? Agg()
                a.n += Int(sqlite3_column_int64(stmt, 1))
                a.okN += Int(sqlite3_column_int64(stmt, 2))
                a.okYes += Int(sqlite3_column_int64(stmt, 3))
                a.overN += Int(sqlite3_column_int64(stmt, 4))
                a.sumDur += Self.columnDouble(stmt, 5) ?? 0
                if let mn = Self.columnDouble(stmt, 6) { a.minDur = a.minDur.map { Swift.min($0, mn) } ?? mn }
                if let mx = Self.columnDouble(stmt, 7) { a.maxDur = a.maxDur.map { Swift.max($0, mx) } ?? mx }
                a.durN += Int(sqlite3_column_int64(stmt, 8))
                a.sumValue += Self.columnDouble(stmt, 9) ?? 0
                if let mn = Self.columnDouble(stmt, 10) { a.minValue = a.minValue.map { Swift.min($0, mn) } ?? mn }
                if let mx = Self.columnDouble(stmt, 11) { a.maxValue = a.maxValue.map { Swift.max($0, mx) } ?? mx }
                a.valueN += Int(sqlite3_column_int64(stmt, 12))
                agg[name] = a
            }
            sqlite3_finalize(stmt)
        }
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
        rollupLocked()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        exec("DELETE FROM ui_events WHERE ts < \(now - Self.detailRetentionMs);")
        let rollupCutHour = (now - Self.retentionMs) / 3_600_000
        exec("DELETE FROM ui_rollup WHERE hour < \(rollupCutHour);")
        exec("PRAGMA incremental_vacuum(500);")
    }

    /// Fold complete hours outside the detail window into hourly rollups, then let
    /// prune drop the raw rows. Idempotent per hour (INSERT OR REPLACE + meta).
    private func rollupLocked() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let completeHour = (now - Self.detailRetentionMs) / 3_600_000
        let through = metaInt("rollup_through_hour") ?? (completeHour - 1)
        guard completeHour - 1 > through else { return }
        let from = (through + 1) * 3_600_000
        let to = completeHour * 3_600_000
        let sql = """
        INSERT OR REPLACE INTO ui_rollup
          (hour, name, n, ok_n, ok_yes, over_n, sum_dur, min_dur, max_dur, dur_n,
           sum_value, min_value, max_value, value_n)
        SELECT ts / 3600000 AS hour, name, COUNT(*),
               SUM(CASE WHEN ok IS NULL THEN 0 ELSE 1 END),
               SUM(CASE WHEN ok = 1 THEN 1 ELSE 0 END),
               SUM(CASE WHEN over = 1 THEN 1 ELSE 0 END),
               SUM(dur_ms), MIN(dur_ms), MAX(dur_ms),
               SUM(CASE WHEN dur_ms IS NULL THEN 0 ELSE 1 END),
               SUM(value), MIN(value), MAX(value),
               SUM(CASE WHEN value IS NULL THEN 0 ELSE 1 END)
        FROM ui_events
        WHERE ts >= ? AND ts < ?
        GROUP BY hour, name;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_int64(stmt, 1, from)
            sqlite3_bind_int64(stmt, 2, to)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        setMetaInt("rollup_through_hour", completeHour - 1)
    }

    private func metaInt(_ key: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM ui_meta WHERE k = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_int64(stmt, 0) }
        return nil
    }

    private func setMetaInt(_ key: String, _ value: Int64) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ui_meta(k, v) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, value)
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
