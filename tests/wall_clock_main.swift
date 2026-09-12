import Foundation

/// Compile: swiftc -parse-as-library tests/wall_clock_main.swift Sources/ClipVault/Store/WallClockPolicy.swift
/// Incident 2026-09-11: 440 OCR upserts with wall_ts=Date() + MAX(timestamp) hid capture order.
@main
enum WallClockTests {
    static func main() {
        var fails = 0
        func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name) \(detail)\n".utf8))
                fails += 1
            }
        }

        ok("touch-bumps", WallClockPolicy.bumpTimestamp(forKind: "touch"))
        ok("upsert-no-bump", !WallClockPolicy.bumpTimestamp(forKind: "upsert"))
        ok("ocr-note-no-bump", !WallClockPolicy.bumpTimestamp(forKind: "ocr"))
        ok("ocr-reuses-capture", WallClockPolicy.wallTsForDerivedOp(captureTs: 1_788_943_742.421) == 1_788_943_742.421)
        ok("ocr-nil-does-not-use-now", WallClockPolicy.wallTsForDerivedOp(captureTs: nil) == nil)

        let capture: Double = 1_788_943_742.421
        let drain: Double = 1_789_138_633.813
        ok(
            "restore-copy1-ocr-clump",
            WallClockPolicy.shouldRestoreToFirstSeen(timestamp: drain, firstSeenAt: capture, copyCount: 1)
        )
        ok(
            "keep-real-recopy",
            !WallClockPolicy.shouldRestoreToFirstSeen(timestamp: drain, firstSeenAt: capture, copyCount: 2)
        )
        ok(
            "keep-aligned",
            !WallClockPolicy.shouldRestoreToFirstSeen(timestamp: capture, firstSeenAt: capture, copyCount: 1)
        )

        struct Row { var id: String; var ts: Double; var type: String }
        var rows: [Row] = []
        for i in 0..<20 { rows.append(Row(id: String(format: "T1-%03d", i), ts: 3000 - Double(i) * 0.01, type: "text")) }
        // 440 images in ~206ms — peer OCR/sync clock clump, unique ts
        let clump: Double = 2000
        for i in 0..<440 {
            rows.append(Row(id: String(format: "IMG-%03d", i), ts: clump + Double(i) * 0.00047, type: "image"))
        }
        for i in 0..<50 { rows.append(Row(id: String(format: "T0-%03d", i), ts: 500 - Double(i), type: "text")) }

        func page(cursor: (Double, String)?, limit: Int) -> [Row] {
            let sorted = rows.sorted { a, b in
                if a.ts != b.ts { return a.ts > b.ts }
                return a.id > b.id
            }
            let rest = sorted.filter { r in
                guard let c = cursor else { return true }
                return WallClockPolicy.isOlderThanCursor(ts: r.ts, id: r.id, cursorTs: c.0, cursorId: c.1)
            }
            return Array(rest.prefix(limit))
        }

        var cursor: (Double, String)? = nil
        var seenText0 = 0
        var seenImg = 0
        var pages = 0
        var empty = 0
        while pages < 80 {
            let batch = page(cursor: cursor, limit: 30)
            pages += 1
            if batch.isEmpty { empty += 1; break }
            seenImg += batch.filter { $0.type == "image" }.count
            seenText0 += batch.filter { $0.id.hasPrefix("T0-") }.count
            let last = batch.last!
            cursor = (last.ts, last.id)
        }
        ok("keyset-walks-clump", seenImg == 440, "img=\(seenImg)")
        ok("keyset-reaches-older-text", seenText0 == 50, "t0=\(seenText0) pages=\(pages)")
        ok("keyset-no-empty-midway", empty <= 1)

        // Tail-cap of 300 after newest-first append: older texts never stay. Forbidden.
        var window: [Row] = []
        cursor = nil
        var cappedText0 = 0
        for _ in 0..<80 {
            let batch = page(cursor: cursor, limit: 30)
            if batch.isEmpty { break }
            window.append(contentsOf: batch)
            if window.count > 300 { window = Array(window.prefix(300)) }
            cappedText0 = window.filter { $0.id.hasPrefix("T0-") }.count
            let last = batch.last!
            cursor = (last.ts, last.id)
        }
        ok("tail-cap-hides-history", cappedText0 == 0, "proves CLIENT_CAP=300 ate T0")

        // Type chip must walk the same keyset, not clientFilter(page1).
        func pageType(_ want: String, cursor: (Double, String)?, limit: Int) -> [Row] {
            let sorted = rows.sorted { a, b in
                if a.ts != b.ts { return a.ts > b.ts }
                return a.id > b.id
            }
            let rest = sorted.filter { r in
                let match = want == "html" ? (r.type == "html" || r.type == "rtf") : r.type == want
                guard match else { return false }
                guard let c = cursor else { return true }
                return WallClockPolicy.isOlderThanCursor(ts: r.ts, id: r.id, cursorTs: c.0, cursorId: c.1)
            }
            return Array(rest.prefix(limit))
        }
        for i in 0..<5 { rows.append(Row(id: "RTF-\(i)", ts: 2900 - Double(i), type: "rtf")) }

        cursor = nil
        var textT0 = 0
        var textT1 = 0
        var textImg = 0
        for _ in 0..<80 {
            let batch = pageType("text", cursor: cursor, limit: 30)
            if batch.isEmpty { break }
            textT0 += batch.filter { $0.id.hasPrefix("T0-") }.count
            textT1 += batch.filter { $0.id.hasPrefix("T1-") }.count
            textImg += batch.filter { $0.type == "image" }.count
            let last = batch.last!
            cursor = (last.ts, last.id)
        }
        ok("type-chip-keyset-all-t1", textT1 == 20, "t1=\(textT1)")
        ok("type-chip-keyset-all-t0", textT0 == 50, "t0=\(textT0)")
        ok("type-chip-skips-images", textImg == 0)

        let page1 = page(cursor: nil, limit: 30)
        let clientOnlyT0 = page1.filter { $0.type == "text" && $0.id.hasPrefix("T0-") }.count
        ok("client-filter-page1-hides-t0", clientOnlyT0 == 0, "chip-on-30-rows loses history")

        let imageCount = rows.filter { $0.type == "image" }.count
        ok("clump-is-440-cards", imageCount == 440)
        let seconds = Set(rows.filter { $0.type == "image" }.map { Int($0.ts) })
        ok("clump-shares-a-second-stays-440", seconds.count == 1 && imageCount == 440)

        cursor = nil
        var htmlRtf = 0
        for _ in 0..<80 {
            let batch = pageType("html", cursor: cursor, limit: 30)
            if batch.isEmpty { break }
            htmlRtf += batch.filter { $0.type == "rtf" }.count
            let last = batch.last!
            cursor = (last.ts, last.id)
        }
        ok("html-chip-includes-rtf", htmlRtf == 5, "rtf=\(htmlRtf)")

        if fails > 0 { exit(1) }
        print("wall-clock: all passed")
    }
}
