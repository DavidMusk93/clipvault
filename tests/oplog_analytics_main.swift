import Foundation

/// Compile: swiftc -parse-as-library -O tests/oplog_analytics_main.swift \
///   Sources/ClipVault/Store/OpsAnalytics.swift Sources/ClipVault/Identity/ClipTimeFormat.swift
///
/// The ops drawer reads four channels (type / frequency / duration / time series)
/// and a list of budgeted signals. Everything it shows is computed here, so this
/// gate pins the two ways the drawer could silently lie:
///
///   1. civil bucket math (a "day" must be the display zone's day, DST included —
///      otherwise the chart disagrees with the `timeLocal` strings next to it);
///   2. signal thresholds (a reading with no budget is not a reading — AGENTS.md
///      · Metrics).
///
/// The oracle for the buckets is a property, not a copy of the algorithm: across
/// a DST spring-forward the civil day is 23h and the 02:00 hour does not exist;
/// across fall-back it is 25h and 01:00 happens twice.
@main
enum OpsAnalyticsTests {
    static func main() {
        var fails = 0
        func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name) \(detail)\n".utf8))
                fails += 1
            }
        }
        func approx(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) < eps }

        let sh = TimeZone(identifier: "Asia/Shanghai")!
        let ny = TimeZone(identifier: "America/New_York")!

        func ts(_ zone: TimeZone, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Double {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            var c = DateComponents()
            c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
            return Double(cal.date(from: c)!.timeIntervalSince1970)
        }

        // ---- window parsing ---------------------------------------------------
        ok("win-default", OpsAnalytics.windowSeconds(nil) == 7 * 86400)
        ok("win-hour", OpsAnalytics.windowSeconds("24h") == 86400)
        ok("win-day", OpsAnalytics.windowSeconds("30d") == 30 * 86400)
        ok("win-all", OpsAnalytics.windowSeconds("all") == nil)
        ok("win-floors", OpsAnalytics.windowSeconds("1m") == nil, "unknown unit must not silently pass")
        ok("kind-hour", OpsAnalytics.kind(forWindow: 48 * 3600) == .hour)
        ok("kind-day", OpsAnalytics.kind(forWindow: 7 * 86400) == .day)

        // ---- bucket label + civil alignment ----------------------------------
        let d1 = ts(sh, 2026, 3, 8, 13, 47)
        let dayStart = ts(sh, 2026, 3, 8, 0, 0)
        let rows1 = [OpsAnalytics.Row(ts: d1, action: "capture_insert", source: "clipboard")]
        let r1 = OpsAnalytics.build(rows: rows1, since: dayStart, now: dayStart + 86400, kind: .day, zone: sh)
        ok("bucket-count", r1.buckets.count == 1)
        ok("bucket-label-day", r1.buckets.first?.label == "03-08", "\(r1.buckets.first?.label ?? "-")")
        ok("bucket-start-day", approx(r1.buckets.first?.start ?? 0, dayStart))

        let r1h = OpsAnalytics.build(rows: rows1, since: dayStart, now: dayStart + 86400, kind: .hour, zone: sh)
        // The series is materialised, so a quiet hour is a zero and not a hole.
        ok("bucket-hours-materialised", r1h.buckets.count == 24, "\(r1h.buckets.count)")
        let r1hHit = r1h.buckets.filter { $0.n > 0 }
        ok("bucket-label-hour", r1hHit.first?.label == "03-08 13:00", "\(r1hHit.first?.label ?? "-")")
        ok("bucket-start-hour", approx(r1hHit.first?.start ?? 0, ts(sh, 2026, 3, 8, 13, 0)))

        // DST spring forward (US 2026-03-08): civil day is 23h, 02:00 does not exist.
        let sprD1 = ts(ny, 2026, 3, 8, 0, 0)
        let sprD2 = ts(ny, 2026, 3, 9, 0, 0)
        ok("dst-day-23h", approx(sprD2 - sprD1, 23 * 3600), "\(sprD2 - sprD1)")
        let springRows = [
            OpsAnalytics.Row(ts: ts(ny, 2026, 3, 8, 1, 30), action: "a", source: "web"),
            OpsAnalytics.Row(ts: ts(ny, 2026, 3, 8, 3, 30), action: "a", source: "web"),
            OpsAnalytics.Row(ts: ts(ny, 2026, 3, 8, 23, 30), action: "a", source: "web"),
        ]
        let spring = OpsAnalytics.build(rows: springRows, since: sprD1, now: sprD2, kind: .day, zone: ny)
        ok("dst-shared-day-bucket", spring.buckets.count == 1 && spring.buckets[0].n == 3, "\(spring.buckets.map(\.n))")
        let springHours = OpsAnalytics.build(rows: springRows, since: sprD1, now: sprD2, kind: .hour, zone: ny)
        // 23 civil hours, and the 02:00 hour does not exist.
        ok("dst-hour-buckets", springHours.buckets.count == 23, "\(springHours.buckets.count)")
        ok("dst-nonempty-hours", springHours.buckets.filter { $0.n > 0 }.count == 3,
           "\(springHours.buckets.filter { $0.n > 0 }.map(\.label))")
        ok("dst-hour-n-sum", springHours.buckets.reduce(0) { $0 + $1.n } == 3)
        ok("dst-no-0200", !springHours.buckets.contains { $0.label.hasSuffix("02:00") },
           "\(springHours.buckets.map(\.label))")
        ok("dst-hour-starts-increasing", zip(springHours.buckets, springHours.buckets.dropFirst()).allSatisfy { $0.start < $1.start })

        // DST fall back (US 2026-11-01): civil day is 25h, 01:00 happens twice.
        let fbD1 = ts(ny, 2026, 11, 1, 0, 0)
        let fbD2 = ts(ny, 2026, 11, 2, 0, 0)
        ok("dst-day-25h", approx(fbD2 - fbD1, 25 * 3600), "\(fbD2 - fbD1)")
        let fallRows = [
            OpsAnalytics.Row(ts: ts(ny, 2026, 11, 1, 0, 30), action: "a", source: "web"),
            OpsAnalytics.Row(ts: ts(ny, 2026, 11, 1, 23, 30), action: "a", source: "web"),
        ]
        let fall = OpsAnalytics.build(rows: fallRows, since: fbD1, now: fbD2, kind: .day, zone: ny)
        ok("dst-fall-one-day", fall.buckets.count == 1 && fall.buckets[0].n == 2, "\(fall.buckets.map(\.label))")
        ok("dst-fall-label", fall.buckets.first?.label == "11-01")

        // ---- type / frequency / duration ------------------------------------
        let base = ts(sh, 2026, 10, 15, 10, 0)
        var rows: [OpsAnalytics.Row] = []
        // compose_edit: 120 ops on 3 notes (an autosave firehose), durations 1..20ms
        for i in 0..<120 {
            rows.append(OpsAnalytics.Row(
                ts: base + Double(i) * 10,
                action: "compose_edit",
                source: "web",
                itemId: "note-\(i % 3)",
                durMs: Double(i % 20 + 1)
            ))
        }
        // backup: 10 ops, 2 of them slow (needed for the p95 signal)
        for i in 0..<10 {
            rows.append(OpsAnalytics.Row(
                ts: base + Double(i) * 60,
                action: "backup",
                source: "backup",
                durMs: i >= 8 ? 5000 : 120
            ))
        }
        // one orphan action with no duration at all
        rows.append(OpsAnalytics.Row(ts: base + 5, action: "reader.comment", source: "web", itemId: "n1"))

        let rep = OpsAnalytics.build(rows: rows, since: base - 60, now: base + 3600, kind: .hour, zone: sh)
        ok("total", rep.total == 131, "\(rep.total)")
        ok("actions-sorted", rep.actions.first?.action == "compose_edit", "\(rep.actions.map(\.action))")
        ok("action-share", approx(rep.actions[0].share, 120.0 / 131.0, 1e-9))
        ok("action-items", rep.actions[0].items == 3, "\(rep.actions[0].items)")
        ok("dur-n", rep.actions.first(where: { $0.action == "compose_edit" })?.durN == 120)
        // nearest-rank p95 of 6 copies of 1..20 (120 values) = the 114th = 19
        ok("p95-nearest-rank", rep.actions[0].durP95 == 19, "\(String(describing: rep.actions[0].durP95))")
        ok("p50-nearest-rank", rep.actions[0].durP50 == 10, "\(String(describing: rep.actions[0].durP50))")
        let bk = rep.actions.first(where: { $0.action == "backup" })!
        ok("dur-max", bk.durMax == 5000)
        ok("no-dur-row", rep.actions.first(where: { $0.action == "reader.comment" })?.durN == 0)
        ok("sources-sorted", rep.sources.first?.source == "web", "\(rep.sources.map(\.source))")
        ok("source-actions", rep.sources.first?.actions == 2, "\(String(describing: rep.sources.first?.actions))")

        // ---- independent gap oracle -----------------------------------------
        let oracleTs = rows.map(\.ts).sorted()
        let oracleGaps = (1..<oracleTs.count).map { oracleTs[$0] - oracleTs[$0 - 1] }
        let oracleMedian = oracleGaps.sorted()[Int(ceil(0.5 * Double(oracleGaps.count))) - 1]
        ok("median-gap-oracle", approx(rep.medianGap ?? -1, oracleMedian), "\(String(describing: rep.medianGap)) vs \(oracleMedian)")
        ok("longest-gap-oracle", approx(rep.longestGap ?? -1, oracleGaps.max() ?? -1))

        // ---- independent silent-day oracle ----------------------------------
        let dayA = ts(sh, 2026, 10, 10, 9, 0)
        let gapRows = [
            OpsAnalytics.Row(ts: dayA, action: "a", source: "web"),
            OpsAnalytics.Row(ts: ts(sh, 2026, 10, 14, 9, 0), action: "a", source: "web"),
        ]
        let gapRep = OpsAnalytics.build(
            rows: gapRows,
            since: ts(sh, 2026, 10, 10, 0, 0),
            now: ts(sh, 2026, 10, 15, 0, 0),
            kind: .day,
            zone: sh
        )
        // 10-11, 10-12, 10-13 are silent; 10-14 has ops; "today" (10-15) is partial.
        ok("silent-days-oracle", gapRep.silentDays == ["10-11", "10-12", "10-13"], "\(gapRep.silentDays)")
        // A 1-day window must never claim a silent day (a quiet afternoon is not a day off).
        let shortRep = OpsAnalytics.build(rows: gapRows, since: dayA, now: dayA + 86400, kind: .hour, zone: sh)
        ok("no-silent-short-window", shortRep.silentDays.isEmpty)
        // No duration sample at all must be reported as a boundary, not as "0ms".
        let noDur = OpsAnalytics.build(
            rows: [OpsAnalytics.Row(ts: dayA, action: "reader.comment", source: "web", itemId: "x")],
            since: dayA - 60, now: dayA + 60, kind: .hour, zone: sh
        )
        ok("no-duration-boundary", noDur.durN == 0 && noDur.signals.contains { $0.id == "oplog_no_duration" },
           "\(noDur.signals.map(\.id))")

        // ---- signal budgets --------------------------------------------------
        let ids = Set(rep.signals.map(\.id))
        ok("sig-firehose", ids.contains("oplog_firehose"), "\(ids)")
        ok("sig-repeat", ids.contains("oplog_repeat"), "\(ids)")
        ok("sig-slow", ids.contains("oplog_slow"), "\(ids)")
        ok("sig-ok-absent-when-problems", !ids.contains("oplog_ok"), "\(ids)")
        ok("sig-no-duration-absent", !ids.contains("oplog_no_duration"), "\(ids)")
        let slow = rep.signals.first(where: { $0.id == "oplog_slow" })!
        ok("slow-uses-action-budget", slow.unit == "ms" && slow.now == 5000 && slow.target == 2000,
           "now=\(slow.now) target=\(slow.target)")
        // Each signal must carry a comparable reading: now/target/unit never empty.
        ok("signals-carry-metric", rep.signals.allSatisfy { !$0.unit.isEmpty && $0.now.isFinite && $0.target.isFinite })
        // A calm window reports good news instead of nothing.
        let calm = OpsAnalytics.build(
            rows: (0..<4).map { OpsAnalytics.Row(ts: base + Double($0) * 600, action: "pin", source: "web", itemId: "p\($0)", durMs: 5) },
            since: base - 60, now: base + 3600, kind: .hour, zone: sh
        )
        ok("sig-good-when-calm", calm.signals.map(\.id) == ["oplog_ok"], "\(calm.signals.map(\.id))")
        // Burst: 200 ops inside one hour of a 24h window is 6x+ the baseline hour.
        var burstRows: [OpsAnalytics.Row] = []
        for i in 0..<200 {
            burstRows.append(OpsAnalytics.Row(
                ts: base + 3600 * 10 + Double(i),
                action: "capture_insert",
                source: "clipboard",
                itemId: "c\(i)",
                durMs: 30
            ))
        }
        let burst = OpsAnalytics.build(rows: burstRows, since: base, now: base + 86400, kind: .hour, zone: sh)
        ok("sig-burst", burst.signals.contains { $0.id == "oplog_burst" }, "\(burst.signals.map(\.id))")
        let burstSignal = burst.signals.first { $0.id == "oplog_burst" }!
        ok("burst-ratio-readable", burstSignal.now > 6 && burstSignal.unit == "ratio", "now=\(burstSignal.now)")
        ok("burst-baseline-oracle", approx(OpsAnalytics.burstBaseline(burst.buckets) ?? 0, 200.0 / 24.0), "\(String(describing: OpsAnalytics.burstBaseline(burst.buckets)))")
        // A steady window must not be called bursty just because it has few buckets.
        let steady = OpsAnalytics.build(
            rows: (0..<24).flatMap { h in (0..<5).map { i in
                OpsAnalytics.Row(ts: base + 3600 * Double(h) + Double(i), action: "pin", source: "web", itemId: "s\(h)-\(i)", durMs: 5)
            } },
            since: base, now: base + 86400, kind: .hour, zone: sh
        )
        ok("no-burst-when-steady", !steady.signals.contains { $0.id == "oplog_burst" }, "\(steady.signals.map(\.id))")

        // ---- wire shape ------------------------------------------------------
        let wire = OpsAnalytics.json(rep)
        for key in ["window", "total", "buckets", "actions", "sources", "signals", "peakBucket", "medianGap", "longestGap", "silentDays", "durN"] {
            ok("json-key-\(key)", wire[key] != nil)
        }
        let w = wire["window"] as? [String: Any]
        ok("json-window-bucket", (w?["bucket"] as? String) == "hour")
        ok("json-buckets-labeled", (wire["buckets"] as? [[String: Any]])?.allSatisfy { ($0["label"] as? String)?.isEmpty == false } == true)
        ok("json-no-null-durations", (wire["actions"] as? [[String: Any]])?.allSatisfy { $0["durN"] != nil } == true)
        ok("json-serializable", (try? JSONSerialization.data(withJSONObject: wire)) != nil)

        if fails > 0 {
            FileHandle.standardError.write(Data("\(fails) FAILURES\n".utf8))
            exit(1)
        }
        print("oplog analytics: all checks passed")
    }
}
