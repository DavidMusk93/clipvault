import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Long-screenshot OCR: page windows in pixel space, Vision per page,
/// then a global line reconstruction with overlap dedup.
///
/// One Vision pass on a 17k-px strip only keeps the biggest glyphs
/// (`minimumTextHeight` is a *fraction of the whole image*). Naive
/// tile-string concat also duplicates the overlap. This module treats
/// the strip as a stack of pages and merges runs in full-image coordinates.
enum StripOCR {
    /// One recognized fragment in **pixels from the top-left of the full image**.
    struct Run {
        var text: String
        var x0: CGFloat
        var x1: CGFloat
        var yMid: CGFloat
        var yH: CGFloat
    }

    static func recognize(data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let image = CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCache: true] as CFDictionary
        ) else {
            return nil
        }
        return recognize(image)
    }

    static func recognize(_ image: CGImage) -> String? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let pages = pageWindows(width: w, height: h)
        var runs: [Run] = []
        runs.reserveCapacity(256)
        for page in pages {
            guard let tile = ImageStoragePolicy.crop(image, pixelRect: page) else { continue }
            runs.append(contentsOf: recognizePage(tile, originY: page.minY, originX: page.minX))
        }
        return reconstruct(runs)
    }

    /// Page-sized windows. Overlap is ~1/8 page so a split line is seen twice
    /// and can be deduped; stride still walks the whole height.
    static func pageWindows(width: Int, height: Int) -> [CGRect] {
        let w = max(1, width)
        let h = max(1, height)
        let pageH = min(1600, max(1000, w))
        let aspect = CGFloat(h) / CGFloat(max(w, 1))
        if h <= pageH + 240, aspect < 2.2 {
            return [CGRect(x: 0, y: 0, width: w, height: h)]
        }
        let overlap = min(180, max(80, pageH / 8))
        var y = 0
        var out: [CGRect] = []
        while y < h {
            let th = min(pageH, h - y)
            out.append(CGRect(x: 0, y: y, width: w, height: th))
            if y + th >= h { break }
            y += max(1, th - overlap)
        }
        return out
    }

    private static func recognizePage(_ tile: CGImage, originY: CGFloat, originX: CGFloat) -> [Run] {
        let tileW = CGFloat(max(tile.width, 1))
        let tileH = CGFloat(max(tile.height, 1))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        // Absolute ~7px floor: a fraction of a 17k image would skip body type.
        request.minimumTextHeight = Float(min(0.02, max(0.0035, 7.0 / tileH)))
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: tile, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[OCR] page failed: \(error)")
            return []
        }
        guard let observations = request.results, !observations.isEmpty else { return [] }

        var runs: [Run] = []
        for obs in observations {
            let raw = obs.topCandidates(3)
                .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard let text = raw else { continue }
            let b = obs.boundingBox
            // Vision origin is bottom-left of the *tile*.
            let yMid = originY + (1 - CGFloat(b.midY)) * tileH
            let yH = max(CGFloat(b.height) * tileH, 1)
            let x0 = originX + CGFloat(b.minX) * tileW
            let x1 = originX + CGFloat(b.maxX) * tileW
            runs.append(Run(text: text, x0: x0, x1: x1, yMid: yMid, yH: yH))
        }
        return runs
    }

    static func reconstruct(_ runs: [Run]) -> String? {
        guard !runs.isEmpty else { return nil }
        let merged = dedup(runs)
        let avgH = merged.map(\.yH).reduce(0, +) / CGFloat(merged.count)
        let lineTol = max(avgH * 0.65, 4)

        let sorted = merged.sorted { a, b in
            if abs(a.yMid - b.yMid) < lineTol { return a.x0 < b.x0 }
            return a.yMid < b.yMid
        }

        var lines: [[Run]] = []
        for run in sorted {
            if let last = lines.indices.last {
                let mid = lines[last].map(\.yMid).reduce(0, +) / CGFloat(lines[last].count)
                if abs(mid - run.yMid) < lineTol {
                    lines[last].append(run)
                    continue
                }
            }
            lines.append([run])
        }

        var texts: [String] = []
        texts.reserveCapacity(lines.count)
        for line in lines {
            let ordered = line.sorted { $0.x0 < $1.x0 }
            var s = ""
            var prev: Run?
            for run in ordered {
                if let p = prev, similar(p.text, run.text) { continue }
                if s.isEmpty {
                    s = run.text
                } else if let p = prev, run.x0 - p.x1 > 8 {
                    s += " " + run.text
                } else if let p = prev, needsSpace(p.text, run.text) {
                    s += " " + run.text
                } else {
                    s += run.text
                }
                prev = run
            }
            if s.isEmpty { continue }
            if let last = texts.last, similar(last, s) { continue }
            texts.append(s)
        }
        let out = texts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Drop overlap copies: same band of Y and nearly the same string.
    static func dedup(_ runs: [Run]) -> [Run] {
        let sorted = runs.sorted { a, b in
            if abs(a.yMid - b.yMid) < 2 { return a.x0 < b.x0 }
            return a.yMid < b.yMid
        }
        var out: [Run] = []
        for run in sorted {
            if let i = out.indices.last, isOverlapCopy(out[i], run) {
                if run.text.count > out[i].text.count { out[i] = run }
                continue
            }
            out.append(run)
        }
        return out
    }

    private static func isOverlapCopy(_ a: Run, _ b: Run) -> Bool {
        let tol = max(min(a.yH, b.yH) * 0.7, 4)
        guard abs(a.yMid - b.yMid) < tol else { return false }
        guard similar(a.text, b.text) else { return false }
        let overlap = min(a.x1, b.x1) - max(a.x0, b.x0)
        let minW = min(max(a.x1 - a.x0, 1), max(b.x1 - b.x0, 1))
        return overlap > minW * 0.35 || a.text.count >= 8
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let na = a.filter { !$0.isWhitespace && !$0.isNewline }
        let nb = b.filter { !$0.isWhitespace && !$0.isNewline }
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }
        if na.count >= 10, nb.count >= 10 {
            if na.contains(nb) || nb.contains(na) { return true }
        }
        return false
    }

    private static func needsSpace(_ left: String, _ right: String) -> Bool {
        guard let l = left.last, let r = right.first else { return true }
        if isCJK(l) && isCJK(r) { return false }
        if l.isWhitespace || r.isWhitespace { return false }
        if l.isLetter || l.isNumber || r.isLetter || r.isNumber { return true }
        return false
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,
             0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}
