import Foundation

/// Operation-log analytics.
///
/// The ops drawer used to render one card per `operation_logs` row. That is a
/// census, not a reading: 10831 `compose_edit` cards look exactly like 11
/// `reader.comment` cards, so nothing is visible until you scroll.
///
/// This turns the same rows into the four channels that *do* show a problem:
///
/// ```text
///   rows (ts, action, source, item_id, dur_ms)
///     |
///     +-- type      -> per-action count / distinct targets / share
///     +-- frequency -> peak bucket, median + longest idle gap
///     +-- duration  -> p50 / p95 / max per action (only where instrumented)
///     +-- series    -> civil-hour / civil-day buckets, split by source
///     |
///     +-- signals   -> budgeted readings (firehose, repeat, burst, silent, slow)
/// ```
///
/// Pure value math: no SQLite, no HTTP, no DOM. `tests/oplog_analytics_main.swift`
/// pins it against an independent oracle, and `OperationPanel` only paints the
/// result. Budgets live in `Budget` so a signal can never be "just a picture"
/// (AGENTS.md · Metrics: a name without a budget is not a metric).
enum OpsAnalytics {

    // MARK: - Input

    /// Minimal projection of one `operation_logs` row.
    struct Row {
        let ts: Double
        let action: String
        let source: String
        let itemId: String?
        let durMs: Double?

        init(ts: Double, action: String, source: String, itemId: String? = nil, durMs: Double? = nil) {
            self.ts = ts
            self.action = action
            self.source = source
            self.itemId = itemId
            self.durMs = durMs
        }
    }

    /// Buckets are civil, not fixed-width: a day bucket must start at the civil
    /// midnight of the display zone (DST included), or the labels drift from the
    /// `timeLocal` strings the drill-down shows.
    enum BucketKind: String {
        case hour
        case day

        var seconds: Double { self == .hour ? 3600 : 86400 }
    }

    // MARK: - Output

    struct Bucket {
        let start: Double
        let label: String
        var n: Int
        var bySource: [String: Int]
        var lastTs: Double
    }

    struct ActionStat {
        let action: String
        var n: Int
        var items: Int
        var share: Double
        var firstTs: Double
        var lastTs: Double
        var durN: Int
        var durP50: Double?
        var durP95: Double?
        var durMax: Double?
        var durAvg: Double?
    }

    struct SourceStat {
        let source: String
        var n: Int
        var actions: Int
        var share: Double
    }

    /// One budgeted reading. `now` / `target` / `unit` are the machine-checkable
    /// half; `text` and `action` are the human half. Never a signal without both.
    struct Signal {
        let id: String
        let severity: String        // high | med | note | good
        let text: String
        let action: String
        let now: Double
        let target: Double
        let unit: String            // count | ratio | ms | s
    }

    struct Report {
        let since: Double
        let now: Double
        let kind: BucketKind
        let bucketSeconds: Double
        let total: Int
        let buckets: [Bucket]
        let actions: [ActionStat]
        let sources: [SourceStat]
        let signals: [Signal]
        let peakBucket: Bucket?
        let medianGap: Double?
        let longestGap: Double?
        let silentDays: [String]
        let durN: Int
        let firstTs: Double?
        let zoneId: String
    }

    // MARK: - Budgets

    /// What "a problem" means, in one place. A signal with no budget here does not
    /// exist: thresholds exist so the drawer can say "now -> target" instead of
    /// eyeballing a bar chart.
    enum Budget {
        /// One action dominating the log is usually a firehose, not a workload.
        static let firehoseShare = 0.40
        static let firehoseMinN = 100
        /// Saves per distinct target (e.g. autosave writing the same note).
        static let repeatPerItem = 20.0
        static let repeatMinItems = 3
        /// A bucket this many times the baseline bucket is a spike.
        static let burstRatio = 6.0
        static let burstMinN = 20
        /// Retention bound for materialising an `all` window whose oldest row is unknown.
        static let maxObservedDays = 100
        /// Hard cap on materialised buckets (a series nobody can read is not a chart).
        static let maxBuckets = 400
        /// p95 wall time of one operation.
        static let slowP95Ms: [String: Double] = [
            "backup": 2_000,
            "restore_db": 5_000,
            "web_archive": 3_000,
            "purge_trash": 2_000,
            "capture_insert": 500,
        ]
        static let slowDefaultP95Ms = 3_000.0
        static let slowMinSamples = 5
        /// Idle time inside the window that is worth knowing about.
        static let gapSeconds = 24 * 3600.0
        /// Below this window a "silent day" is meaningless (a quiet afternoon is not a day off).
        static let silentDayMinWindow = 7 * 86400.0
    }

    // MARK: - Window parsing

    /// `1h` / `6h` / `24h` / `3d` / `7d` / `30d` / `90d` / `all`.
    static func windowSeconds(_ key: String?) -> Double? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty else {
            return 7 * 86400
        }
        if key == "all" { return nil }
        let unit = key.hasSuffix("h") ? 3600.0 : key.hasSuffix("d") ? 86400.0 : 0
        guard unit > 0, let n = Double(key.dropLast()) else { return nil }
        return max(300, n * unit)
    }

    static func kind(forWindow seconds: Double) -> BucketKind {
        seconds <= 48 * 3600 ? .hour : .day
    }

    // MARK: - Build

    /// Aggregate raw rows into a report. `zone` is the display zone (a browser
    /// stuck in UTC must still see the same civil days as the drill-down).
    static func build(
        rows: [Row],
        since: Double,
        now: Double,
        kind: BucketKind,
        zone: TimeZone
    ) -> Report {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone

        let inWindow = rows.filter { $0.ts >= since && $0.ts <= now }
        let firstTs = inWindow.map(\.ts).min()

        // The series must be continuous: a bucket with zero operations is a fact
        // (silence), not something to skip, and it is the denominator that makes a
        // spike visisble. An `all` window has no known start, so it is clamped to
        // retention rather than to 1970.
        let spanStart = max(since, now - Double(Budget.maxObservedDays) * 86400)
        let starts = bucketStarts(since: spanStart, now: now, kind: kind, cal: cal)
        var bucketIndex: [Double: Int] = [:]
        var buckets: [Bucket] = []
        buckets.reserveCapacity(starts.count)
        for (i, start) in starts.enumerated() {
            bucketIndex[start] = i
            buckets.append(Bucket(
                start: start,
                label: bucketLabel(start, kind: kind, zone: zone),
                n: 0,
                bySource: [:],
                lastTs: start
            ))
        }

        var actionIndex: [String: Int] = [:]
        var actions: [ActionStat] = []
        var actionItems: [String: Set<String>] = [:]
        var actionTs: [String: (Double, Double)] = [:]
        var actionDur: [String: [Double]] = [:]
        var sourceN: [String: Int] = [:]
        var sourceActions: [String: Set<String>] = [:]

        for row in inWindow {
            let start = bucketStart(row.ts, kind: kind, cal: cal)
            if let i = bucketIndex[start] {
                buckets[i].n += 1
                buckets[i].bySource[row.source, default: 0] += 1
                buckets[i].lastTs = max(buckets[i].lastTs, row.ts)
            }

            if let i = actionIndex[row.action] {
                actions[i].n += 1
                actions[i].firstTs = min(actions[i].firstTs, row.ts)
                actions[i].lastTs = max(actions[i].lastTs, row.ts)
            } else {
                actionIndex[row.action] = actions.count
                actions.append(ActionStat(
                    action: row.action,
                    n: 1,
                    items: 0,
                    share: 0,
                    firstTs: row.ts,
                    lastTs: row.ts,
                    durN: 0,
                    durP50: nil,
                    durP95: nil,
                    durMax: nil,
                    durAvg: nil
                ))
            }
            if let item = row.itemId, !item.isEmpty {
                actionItems[row.action, default: []].insert(item)
            }
            let prev = actionTs[row.action]
            actionTs[row.action] = (min(prev?.0 ?? row.ts, row.ts), max(prev?.1 ?? row.ts, row.ts))
            if let d = row.durMs, d.isFinite, d >= 0 {
                actionDur[row.action, default: []].append(d)
            }

            sourceN[row.source, default: 0] += 1
            sourceActions[row.source, default: []].insert(row.action)
        }

        let total = inWindow.count
        for i in actions.indices {
            let key = actions[i].action
            actions[i].items = actionItems[key]?.count ?? 0
            actions[i].share = total > 0 ? Double(actions[i].n) / Double(total) : 0
            if let bounds = actionTs[key] {
                actions[i].firstTs = bounds.0
                actions[i].lastTs = bounds.1
            }
            if let durs = actionDur[key], !durs.isEmpty {
                let sorted = durs.sorted()
                actions[i].durN = sorted.count
                actions[i].durP50 = percentile(sorted, 0.5)
                actions[i].durP95 = percentile(sorted, 0.95)
                actions[i].durMax = sorted.last
                actions[i].durAvg = sorted.reduce(0, +) / Double(sorted.count)
            }
        }
        actions.sort { $0.n == $1.n ? $0.action < $1.action : $0.n > $1.n }

        var sources = sourceN.map { key, n in
            SourceStat(source: key, n: n, actions: sourceActions[key]?.count ?? 0, share: 0)
        }
        for i in sources.indices {
            sources[i].share = total > 0 ? Double(sources[i].n) / Double(total) : 0
        }
        sources.sort { $0.n == $1.n ? $0.source < $1.source : $0.n > $1.n }

        buckets.sort { $0.start < $1.start }
        // Gaps: between consecutive operations *inside* the window. Leading and
        // trailing dead time belongs to `silentDays`, not to "longest idle gap" —
        // an idle app is not a long operation.
        let sortedTs = inWindow.map(\.ts).sorted()
        var gaps: [Double] = []
        if sortedTs.count > 1 {
            for i in 1..<sortedTs.count { gaps.append(sortedTs[i] - sortedTs[i - 1]) }
        }
        let peakBucket = buckets.max { a, b in a.n == b.n ? a.start > b.start : a.n < b.n }
        // Silence is only meaningful against the observed window, not against 1970.
        let silentDays = self.silentDays(
            since: max(spanStart, firstTs ?? spanStart),
            now: now,
            kind: kind,
            present: Set(buckets.filter { $0.n > 0 }.map(\.start)),
            cal: cal,
            zone: zone
        )

        let durN = actions.reduce(0) { $0 + $1.durN }
        let report = Report(
            since: since,
            now: now,
            kind: kind,
            bucketSeconds: kind.seconds,
            total: total,
            buckets: buckets,
            actions: actions,
            sources: sources,
            signals: [],
            peakBucket: peakBucket,
            medianGap: percentile(gaps.sorted(), 0.5),
            longestGap: gaps.max(),
            silentDays: silentDays,
            durN: durN,
            firstTs: firstTs,
            zoneId: zone.identifier
        )
        let signals = self.signals(
            report: report,
            windowSeconds: now - since
        )
        return Report(
            since: report.since,
            now: report.now,
            kind: report.kind,
            bucketSeconds: report.bucketSeconds,
            total: report.total,
            buckets: report.buckets,
            actions: report.actions,
            sources: report.sources,
            signals: signals,
            peakBucket: report.peakBucket,
            medianGap: report.medianGap,
            longestGap: report.longestGap,
            silentDays: report.silentDays,
            durN: report.durN,
            firstTs: report.firstTs,
            zoneId: report.zoneId
        )
    }

    // MARK: - Signals

    private static func signals(report: Report, windowSeconds: Double) -> [Signal] {
        var out: [Signal] = []

        // 1. Firehose: one action eats the log. The log then cannot be read as a history.
        if let top = report.actions.first,
           top.share >= Budget.firehoseShare,
           top.n >= Budget.firehoseMinN {
            out.append(Signal(
                id: "oplog_firehose",
                severity: "med",
                text: "\(top.action) 占全部操作 \(pct(top.share))（\(top.n)/\(report.total)）",
                action: "先看这一类是否可以降频或合并成一次操作，再谈别的类型",
                now: top.share,
                target: Budget.firehoseShare,
                unit: "ratio"
            ))
        }

        // 2. Repeat: many operations against the same few targets = a loop.
        if let worst = report.actions
            .filter({ $0.items >= Budget.repeatMinItems })
            .map({ ($0, Double($0.n) / Double($0.items)) })
            .filter({ $0.1 >= Budget.repeatPerItem })
            .max(by: { $0.1 < $1.1 }) {
            let per = worst.1
            out.append(Signal(
                id: "oplog_repeat",
                severity: "med",
                text: "\(worst.0.action) 在 \(worst.0.items) 个目标上写了 \(worst.0.n) 次（平均 \(fmt(per, 1)) 次/目标）",
                action: "这通常是自动保存/重试；按目标去重或合并成一次，看 note 级次数是否降下来",
                now: per,
                target: Budget.repeatPerItem,
                unit: "count"
            ))
        }

        // 3. Burst: one bucket far above the baseline bucket. The baseline is the
        // median materialised bucket (robust to the spike itself); when more than
        // half the buckets are empty the median *is* zero, and the mean is the only
        // readable baseline left.
        if let peak = report.peakBucket,
           peak.n >= Budget.burstMinN,
           report.buckets.count > 1,
           let base = burstBaseline(report.buckets),
           base > 0,
           Double(peak.n) >= Budget.burstRatio * base {
            let ratio = Double(peak.n) / base
            out.append(Signal(
                id: "oplog_burst",
                severity: "med",
                text: "\(peak.label) 一个\(report.kind == .hour ? "小时" : "天")内有 \(peak.n) 次操作（窗口基线的 \(fmt(ratio, 1)) 倍）",
                action: "看这段时段是不是批量导入/回放；确认不是重复写入",
                now: ratio,
                target: Budget.burstRatio,
                unit: "ratio"
            ))
        }

        // 4. Slow: only from actions that actually carry a duration sample.
        if let slowest = report.actions
            .filter({ $0.durN >= Budget.slowMinSamples })
            .compactMap({ a -> (ActionStat, Double, Double)? in
                guard let p95 = a.durP95 else { return nil }
                let budget = Budget.slowP95Ms[a.action] ?? Budget.slowDefaultP95Ms
                return (a, p95, budget)
            })
            .filter({ $0.1 >= $0.2 })
            .max(by: { ($0.1 / $0.2) < ($1.1 / $1.2) }) {
            out.append(Signal(
                id: "oplog_slow",
                severity: "med",
                text: "\(slowest.0.action) p95 \(fmtMs(slowest.1))，超过预算 \(fmtMs(slowest.2))（n=\(slowest.0.durN)，max \(fmtMs(slowest.0.durMax ?? 0))）",
                action: "按同一 name 对照优化前后的 p95，不要用单次 max 下结论",
                now: slowest.1,
                target: slowest.2,
                unit: "ms"
            ))
        }

        // 5. Silent days: real gaps in the record, inside observed history.
        if windowSeconds >= Budget.silentDayMinWindow, !report.silentDays.isEmpty {
            let preview = report.silentDays.prefix(3).joined(separator: "、")
            out.append(Signal(
                id: "oplog_silent_day",
                severity: "note",
                text: "窗口内 \(report.silentDays.count) 天没有任何操作记录（\(preview)\(report.silentDays.count > 3 ? "…" : "")）",
                action: "确认那几天是没在用，还是服务没起来（错 home / 进程挂）",
                now: Double(report.silentDays.count),
                target: 0,
                unit: "count"
            ))
        }

        // 6. Longest idle gap inside the window.
        if let gap = report.longestGap, gap >= Budget.gapSeconds {
            out.append(Signal(
                id: "oplog_gap",
                severity: "note",
                text: "最长空档 \(fmtGap(gap))（窗口内相邻两次操作之间）",
                action: "对照空档前后是不是同一条日志被截断（同步/回填漏写）",
                now: gap,
                target: Budget.gapSeconds,
                unit: "s"
            ))
        }

        // 7. Honest boundary: no duration sample at all in this window.
        if report.durN == 0 && report.total > 0 {
            out.append(Signal(
                id: "oplog_no_duration",
                severity: "note",
                text: "本窗口没有任何耗时采样（只有被计时过的操作才有 dur_ms）",
                action: "要读耗时，先给该操作补计时（backup / web_archive / capture_insert 已有）",
                now: 0,
                target: 1,
                unit: "count"
            ))
        }

        // Good news is a signal too: nothing above fired.
        let fired = Set(out.map(\.id))
        if fired.isDisjoint(with: ["oplog_firehose", "oplog_repeat", "oplog_burst", "oplog_slow"]) {
            out.append(Signal(
                id: "oplog_ok",
                severity: "good",
                text: "无支配型动作、无重复写入、无尖峰、无超预算耗时",
                action: "保持；换窗口复查",
                now: 0,
                target: 0,
                unit: "count"
            ))
        }

        return out
    }

    // MARK: - Helpers

    private static func bucketStart(_ ts: Double, kind: BucketKind, cal: Calendar) -> Double {
        let date = Date(timeIntervalSince1970: ts)
        switch kind {
        case .hour:
            var comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
            comps.minute = 0
            comps.second = 0
            return (cal.date(from: comps) ?? date).timeIntervalSince1970
        case .day:
            return cal.startOfDay(for: date).timeIntervalSince1970
        }
    }

    static func bucketLabel(_ start: Double, kind: BucketKind, zone: TimeZone) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = zone
        df.dateFormat = kind == .hour ? "MM-dd HH:00" : "MM-dd"
        return df.string(from: Date(timeIntervalSince1970: start))
    }

    private static func silentDays(
        since: Double,
        now: Double,
        kind: BucketKind,
        present: Set<Double>,
        cal: Calendar,
        zone: TimeZone
    ) -> [String] {
        guard kind == .day else { return [] }
        var day = cal.startOfDay(for: Date(timeIntervalSince1970: since))
        let end = cal.startOfDay(for: Date(timeIntervalSince1970: now))
        var missing: [String] = []
        // A partial first/last civil day is only counted when it is the only thing
        // in the window; otherwise a "today" with one operation would look silent.
        while day < end {
            if !present.contains(day.timeIntervalSince1970) {
                missing.append(bucketLabel(day.timeIntervalSince1970, kind: .day, zone: zone))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return missing
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int(ceil(p * Double(sorted.count)))
        let idx = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[idx]
    }

    private static func medianBucketCount(_ buckets: [Bucket]) -> Double? {
        guard !buckets.isEmpty else { return nil }
        return percentile(buckets.map { Double($0.n) }.sorted(), 0.5)
    }

    /// Median bucket count, falling back to the mean when the median is 0.
    static func burstBaseline(_ buckets: [Bucket]) -> Double? {
        guard !buckets.isEmpty else { return nil }
        if let med = medianBucketCount(buckets), med > 0 { return med }
        let total = buckets.reduce(0) { $0 + $1.n }
        return Double(total) / Double(buckets.count)
    }

    /// Every bucket start covering `[since, now)`, civil-aligned and DST-correct:
    /// stepping must go through `Calendar`, because a spring-forward day has 23
    /// hours and a fall-back day has 25. The bucket that `now` falls on is only
    /// included while it is still `now`'s bucket (a window ending exactly on a
    /// boundary must not grow an empty bucket after it).
    static func bucketStarts(since: Double, now: Double, kind: BucketKind, cal: Calendar) -> [Double] {
        guard now >= since else { return [] }
        var out: [Double] = []
        var cur = bucketStart(since, kind: kind, cal: cal)
        let unit: Calendar.Component = kind == .hour ? .hour : .day
        while (cur < now || out.isEmpty) && out.count < Budget.maxBuckets {
            out.append(cur)
            guard let next = cal.date(byAdding: unit, value: 1, to: Date(timeIntervalSince1970: cur)) else { break }
            cur = next.timeIntervalSince1970
        }
        return out
    }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func fmt(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v)
    }
    static func fmtMs(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.2fs", v / 1000) : String(format: "%.0fms", v)
    }
    static func fmtGap(_ seconds: Double) -> String {
        if seconds >= 86400 { return String(format: "%.1f 天", seconds / 86400) }
        if seconds >= 3600 { return String(format: "%.1f 小时", seconds / 3600) }
        return String(format: "%.0f 分", seconds / 60)
    }

    // MARK: - Wire

    /// JSON for `GET /api/oplogs/stats`. Durations are already milliseconds.
    static func json(_ report: Report) -> [String: Any] {
        func pivot(_ d: Double?) -> Any { d.map { $0 as Any } ?? NSNull() }

        let buckets: [[String: Any]] = report.buckets.map { b in
            [
                "t": b.start,
                "label": b.label,
                "n": b.n,
                "bySource": b.bySource,
            ]
        }
        let actions: [[String: Any]] = report.actions.map { a in
            [
                "action": a.action,
                "n": a.n,
                "items": a.items,
                "share": a.share,
                "firstTs": a.firstTs,
                "lastTs": a.lastTs,
                "firstLocal": ClipTimeFormat.displayWall(unix: a.firstTs),
                "lastLocal": ClipTimeFormat.displayWall(unix: a.lastTs),
                "durN": a.durN,
                "p50": pivot(a.durP50),
                "p95": pivot(a.durP95),
                "max": pivot(a.durMax),
                "avg": pivot(a.durAvg),
            ]
        }
        let sources: [[String: Any]] = report.sources.map { s in
            ["source": s.source, "n": s.n, "actions": s.actions, "share": s.share]
        }
        let signals: [[String: Any]] = report.signals.map { s in
            [
                "id": s.id,
                "severity": s.severity,
                "text": s.text,
                "action": s.action,
                "now": s.now,
                "target": s.target,
                "unit": s.unit,
            ]
        }
        let peak: Any = report.peakBucket.map {
            ["t": $0.start, "label": $0.label, "n": $0.n] as [String: Any]
        } ?? NSNull()

        return [
            "window": [
                "since": report.since,
                "now": report.now,
                "zone": report.zoneId,
                "bucket": report.kind.rawValue,
                "bucketSeconds": report.bucketSeconds,
            ],
            "total": report.total,
            "durN": report.durN,
            "firstTs": pivot(report.firstTs),
            "peakBucket": peak,
            "medianGap": pivot(report.medianGap),
            "longestGap": pivot(report.longestGap),
            "silentDays": report.silentDays,
            "buckets": buckets,
            "actions": actions,
            "sources": sources,
            "signals": signals,
        ]
    }
}
