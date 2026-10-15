import Foundation

/// Wall header aggregate for **one capture day**.
///
/// The wall paints lazily (a keyset page at a time), so a day header must never
/// count the cards that happen to be painted. `total` / `byType` / `bins` are
/// computed over *every* matching row of that capture day, and the client only
/// renders them (AGENTS.md · 墙: the header is an aggregate, not a DOM census).
///
/// Types stay raw here (`html` and `rtf` apart): collapsing them into the
/// header's `rich` bucket is presentation and belongs to `DayGroups` in the web
/// client, where it is mirrored by `tests/day-groups.test.mjs`.
struct DayIndexDay {
    let day: String                     // `YYYY-MM-DD` on the capture clock
    var total: Int = 0                  // every matching row of the day
    var byType: [String: Int] = [:]     // raw clipboard types
    var bins: [Int]                     // 288 five-minute marks on the capture clock
    var timed: Int = 0                  // rows that carry a usable capture time
    var firstMin: Int?                  // exact minute of day of the first capture
    var lastMin: Int?                   // exact minute of day of the last capture
    var night: Int = 0                  // captures inside 22:00–06:00
    var maxGapMin: Int?                 // longest silence between two captures
    var gapFromMin: Int?
    var gapToMin: Int?
}

/// Turns `(capture timestamp, type)` rows into per-day aggregates.
///
/// Five minutes per mark is the contract the strip reads, so the bin count and
/// the civil-day math live here and are mirrored by `tests/day_index_main.swift`.
/// The capture clock is the display zone (`ClipTimeFormat.displayTimeZone`), the
/// same zone that renders every card's `timeLocal`, so a header can never
/// disagree with the cards it labels.
enum DayIndexBuilder {
    static let binMinutes = 5
    static let binCount = (24 * 60) / binMinutes      // 288
    static let nightStart = 22 * 60
    static let nightEnd = 6 * 60
    static let unknownDay = "unknown"

    /// `YYYY-MM-DD` + minute of day for one capture timestamp in `zone`.
    ///
    /// Pure integer civil-date math with a `TimeZone` offset lookup: one
    /// `DateFormatter` per row would cost seconds on a whole-table aggregate.
    /// Rows outside a sane epoch range (or with a non-finite timestamp) return
    /// nil and are counted as `unknown` instead of being dropped.
    static func captureDay(timestamp: Double, zone: TimeZone) -> (day: String, minute: Int)? {
        guard timestamp.isFinite,
              timestamp >= -62_135_596_800, timestamp < 253_402_300_800 else { return nil }
        let local = timestamp + Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: timestamp)))
        guard local.isFinite else { return nil }
        let epochDay = Int(floor(local / 86_400))
        let secondOfDay = Int(floor(local - Double(epochDay) * 86_400))
        guard secondOfDay >= 0, secondOfDay < 86_400 else { return nil }
        return (civilDayKey(epochDay: epochDay), secondOfDay / 60)
    }

    /// `YYYY-MM-DD` for days since 1970-01-01 (Howard Hinnant's civil_from_days).
    static func civilDayKey(epochDay: Int) -> String {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097                                       // [0, 146096]
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365 // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)                  // [0, 365]
        let mp = (5 * doy + 2) / 153                                      // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                              // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9                                 // [1, 12]
        let year = m <= 2 ? y + 1 : y
        let pad = { (v: Int) in v < 10 ? "0\(v)" : "\(v)" }
        return "\(year)-\(pad(m))-\(pad(d))"
    }

    /// Bucket rows into capture days, **newest day first** (`unknown` last).
    /// Within a day the bins, the exact span and the exact longest gap agree.
    static func build(rows: [(timestamp: Double, type: String)], zone: TimeZone) -> [DayIndexDay] {
        var order: [String] = []
        var byDay: [String: DayIndexDay] = [:]
        var minutes: [String: [Int]] = [:]

        for row in rows {
            let parsed = captureDay(timestamp: row.timestamp, zone: zone)
            let day = parsed?.day ?? unknownDay
            if byDay[day] == nil {
                byDay[day] = DayIndexDay(day: day, bins: Array(repeating: 0, count: binCount))
                order.append(day)
            }
            var entry = byDay[day] ?? DayIndexDay(day: day, bins: Array(repeating: 0, count: binCount))
            entry.total += 1
            entry.byType[row.type.lowercased(), default: 0] += 1
            if let minute = parsed?.minute {
                entry.bins[min(binCount - 1, max(0, minute / binMinutes))] += 1
                entry.timed += 1
                if let first = entry.firstMin {
                    if minute < first { entry.firstMin = minute }
                } else {
                    entry.firstMin = minute
                }
                if let last = entry.lastMin {
                    if minute > last { entry.lastMin = minute }
                } else {
                    entry.lastMin = minute
                }
                minutes[day, default: []].append(minute)
            }
            byDay[day] = entry
        }

        for day in order {
            guard var entry = byDay[day], let list = minutes[day] else { continue }
            let sorted = list.sorted()
            entry.night = sorted.reduce(0) { $0 + (($1 >= nightStart || $1 < nightEnd) ? 1 : 0) }
            if sorted.count > 1 {
                var best = 0
                var from: Int? = nil
                var to: Int? = nil
                for i in 1..<sorted.count {
                    let gap = sorted[i] - sorted[i - 1]
                    if gap > best { best = gap; from = sorted[i - 1]; to = sorted[i] }
                }
                entry.maxGapMin = best
                entry.gapFromMin = from
                entry.gapToMin = to
            }
            byDay[day] = entry
        }

        return order.compactMap { byDay[$0] }.sorted { a, b in
            if a.day == unknownDay { return false }
            if b.day == unknownDay { return true }
            return a.day > b.day
        }
    }
}
