import Foundation

/// Compile: swiftc -parse-as-library -O tests/day_index_main.swift Sources/ClipVault/Store/DayIndex.swift
///
/// The wall header is an aggregate over **every** matching row of a capture day,
/// not a census of the cards that happen to be painted. This gate pins the two
/// things that can silently lie: the civil-day/minute math (which must agree with
/// the cards' `timeLocal`, DST included) and the exact facts (span / night / gap)
/// that the 5-minute bins only illustrate.
@main
enum DayIndexTests {
    static func main() {
        var fails = 0
        func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name) \(detail)\n".utf8))
                fails += 1
            }
        }

        let sh = TimeZone(identifier: "Asia/Shanghai")!
        let ny = TimeZone(identifier: "America/New_York")!

        func ts(_ zone: TimeZone, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Double {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            var comps = DateComponents()
            comps.year = y; comps.month = mo; comps.day = d
            comps.hour = h; comps.minute = mi; comps.second = s
            return Double(cal.date(from: comps)!.timeIntervalSince1970)
        }

        // ---- civil day key (pure integer math) ---------------------------------
        ok("fix-day-epoch", DayIndexBuilder.civilDayKey(epochDay: 0) == "1970-01-01")
        ok("fix-day-before", DayIndexBuilder.civilDayKey(epochDay: -1) == "1969-12-31")
        ok("fix-day-leap", DayIndexBuilder.civilDayKey(epochDay: 11016) == "2000-02-29")
        ok("fix-day-2026", DayIndexBuilder.civilDayKey(epochDay: 20787) == "2026-11-30")

        // ---- capture day + minute of day --------------------------------------
        let midnight = DayIndexBuilder.captureDay(timestamp: ts(sh, 2026, 10, 10, 0, 0), zone: sh)
        ok("sh-midnight-day", midnight?.day == "2026-10-10", "\(String(describing: midnight))")
        ok("sh-midnight-minute", midnight?.minute == 0)
        let lastMinute = DayIndexBuilder.captureDay(timestamp: ts(sh, 2026, 10, 10, 23, 59, 59), zone: sh)
        ok("sh-last-minute", lastMinute?.minute == 1439 && lastMinute?.day == "2026-10-10")
        let nextDay = DayIndexBuilder.captureDay(timestamp: ts(sh, 2026, 10, 11, 0, 0), zone: sh)
        ok("sh-rolls-over", nextDay?.day == "2026-10-11" && nextDay?.minute == 0)
        ok("unparsable-nan", DayIndexBuilder.captureDay(timestamp: Double.nan, zone: sh) == nil)
        ok("unparsable-huge", DayIndexBuilder.captureDay(timestamp: 9e12, zone: sh) == nil)

        // DST: the spring-forward day keeps one civil day even though the zone
        // offset changes mid-day (2026-03-08 in New York, 02:00 → 03:00).
        let beforeJump = DayIndexBuilder.captureDay(timestamp: ts(ny, 2026, 3, 8, 1, 30), zone: ny)
        let afterJump = DayIndexBuilder.captureDay(timestamp: ts(ny, 2026, 3, 8, 3, 30), zone: ny)
        ok("dst-same-day", beforeJump?.day == "2026-03-08" && afterJump?.day == "2026-03-08")
        ok("dst-minutes", beforeJump?.minute == 90 && afterJump?.minute == 210)

        // The offset is resolved per row: the same instant is a different civil
        // day in a different display zone (the header must follow the zone the
        // cards print, never the host's).
        let instant = ts(sh, 2026, 10, 10, 0, 30)
        ok("zone-relative-day", DayIndexBuilder.captureDay(timestamp: instant, zone: ny)?.day == "2026-10-09")

        // ---- build: bins, exact facts, buckets ---------------------------------
        let rows: [(timestamp: Double, type: String)] = [
            (ts(sh, 2026, 10, 10, 9, 12), "text"),
            (ts(sh, 2026, 10, 10, 9, 14), "text"),
            (ts(sh, 2026, 10, 10, 9, 15), "image"),
            (ts(sh, 2026, 10, 10, 14, 2), "html"),
            (ts(sh, 2026, 10, 10, 14, 7), "rtf"),
            (ts(sh, 2026, 10, 10, 14, 29), "image"),
            (ts(sh, 2026, 10, 10, 23, 10), "url"),
            (ts(sh, 2026, 10, 10, 5, 59), "note"),
            (ts(sh, 2026, 10, 9, 22, 0), "text"),
            (Double.nan, "text"),
        ]
        let days = DayIndexBuilder.build(rows: rows, zone: sh)
        ok("build-day-count", days.count == 3, "\(days.map(\.day))")
        ok("build-order", days.map(\.day) == ["2026-10-10", "2026-10-09", DayIndexBuilder.unknownDay])

        let d10 = days[0]
        ok("build-bins-len", d10.bins.count == DayIndexBuilder.binCount && DayIndexBuilder.binCount == 288)
        ok("build-total", d10.total == 8)
        ok("build-timed", d10.timed == 8)
        ok("build-bin-sum", d10.bins.reduce(0, +) == d10.timed)
        // 09:12 and 09:14 share the 09:10–09:15 mark, 09:15 opens the next one.
        ok("build-bin-5min", d10.bins[110] == 2 && d10.bins[111] == 1, "\(d10.bins[110])/\(d10.bins[111])")
        ok("build-bin-14", d10.bins[(14 * 60) / 5] == 1 && d10.bins[(14 * 60 + 7) / 5] == 1 && d10.bins[(14 * 60 + 29) / 5] == 1)
        ok("build-bin-night", d10.bins[(23 * 60 + 10) / 5] == 1 && d10.bins[71] == 1)
        ok("build-types-raw", d10.byType["html"] == 1 && d10.byType["rtf"] == 1 && d10.byType["image"] == 2 && d10.byType["text"] == 2)
        ok("build-bytype-sum", d10.byType.values.reduce(0, +) == d10.total)
        ok("build-span-exact", d10.firstMin == 5 * 60 + 59 && d10.lastMin == 23 * 60 + 10)
        // night = 22:00–05:59 → 05:59 and 23:10 (09:12/14:xx are day).
        ok("build-night-exact", d10.night == 2)
        // 14:29 → 23:10 is the longest silence of that day (521 min).
        ok("build-gap-exact", d10.maxGapMin == 521, "\(String(describing: d10.maxGapMin))")
        ok("build-gap-bounds", d10.gapFromMin == 14 * 60 + 29 && d10.gapToMin == 23 * 60 + 10)

        let d9 = days[1]
        ok("build-single-gap-nil", d9.maxGapMin == nil && d9.gapFromMin == nil)
        ok("build-single-night", d9.night == 1 && d9.firstMin == 22 * 60)

        let unknown = days[2]
        ok("build-unknown-counted", unknown.total == 1 && unknown.timed == 0 && unknown.firstMin == nil)
        ok("build-empty-unknown", unknown.bins.allSatisfy { $0 == 0 })

        let empty = DayIndexBuilder.build(rows: [], zone: sh)
        ok("build-empty", empty.isEmpty)

        if fails > 0 {
            FileHandle.standardError.write(Data("\(fails) day-index test(s) failed\n".utf8))
            exit(1)
        }
        print("day-index OK")
    }
}
