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
///
/// Stitch rule: **geometry first, string second**. The same ink is often
/// recognized twice in the page overlap — once clipped (garbled) at a
/// tile edge, once complete in the interior. Overlapping boxes keep the
/// better observation; sequential boxes concatenate; leftover suffix
/// fragments on the next line are absorbed.
enum StripOCR {
    /// One recognized fragment in **pixels from the top-left of the full image**.
    struct Run {
        var text: String
        var x0: CGFloat
        var x1: CGFloat
        var yMid: CGFloat
        var yH: CGFloat
        /// Distance from this box to the nearer tile edge. Interior hits beat
        /// clipped edge hits when the same ink is seen twice.
        var edgeDist: CGFloat
        var confidence: Float

        init(
            text: String,
            x0: CGFloat,
            x1: CGFloat,
            yMid: CGFloat,
            yH: CGFloat,
            edgeDist: CGFloat = 80,
            confidence: Float = 1
        ) {
            self.text = text
            self.x0 = x0
            self.x1 = x1
            self.yMid = yMid
            self.yH = yH
            self.edgeDist = edgeDist
            self.confidence = confidence
        }
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

    /// Page-sized windows. Overlap is ~1/6 page so a split line is seen twice
    /// (once complete) and can be deduped; stride still walks the whole height.
    static func pageWindows(width: Int, height: Int) -> [CGRect] {
        let w = max(1, width)
        let h = max(1, height)
        let pageH = min(1600, max(1000, w))
        let aspect = CGFloat(h) / CGFloat(max(w, 1))
        if h <= pageH + 240, aspect < 2.2 {
            return [CGRect(x: 0, y: 0, width: w, height: h)]
        }
        let overlap = min(240, max(120, pageH / 6))
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
            guard let picked = pickCandidate(obs) else { continue }
            let b = obs.boundingBox
            // Vision origin is bottom-left of the *tile*.
            let yTop = originY + (1 - CGFloat(b.maxY)) * tileH
            let yBot = originY + (1 - CGFloat(b.minY)) * tileH
            let yMid = (yTop + yBot) / 2
            let yH = max(yBot - yTop, 1)
            let x0 = originX + CGFloat(b.minX) * tileW
            let x1 = originX + CGFloat(b.maxX) * tileW
            let edgeDist = min(max(yTop - originY, 0), max(originY + tileH - yBot, 0))
            runs.append(Run(
                text: picked.text,
                x0: x0, x1: x1, yMid: yMid, yH: yH,
                edgeDist: edgeDist,
                confidence: picked.conf
            ))
        }
        return runs
    }

    private static func pickCandidate(_ obs: VNRecognizedTextObservation) -> (text: String, conf: Float)? {
        let cands = obs.topCandidates(3).compactMap { c -> (String, Float)? in
            let t = trimGarbledTail(c.string.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !t.isEmpty else { return nil }
            return (t, c.confidence)
        }
        guard !cands.isEmpty else { return nil }
        return cands.max { a, b in
            let qa = quality(a.0) + Int(a.1 * 24)
            let qb = quality(b.0) + Int(b.1 * 24)
            if qa != qb { return qa < qb }
            return a.0.count < b.0.count
        }.map { ($0.0, $0.1) }
    }

    static func reconstruct(_ runs: [Run]) -> String? {
        guard !runs.isEmpty else { return nil }
        let cleaned = runs.map { run -> Run in
            var r = run
            r.text = trimGarbledTail(run.text)
            return r
        }.filter { !$0.text.isEmpty && !isSeamJunk($0.text) }

        let merged = dedup(cleaned)
        guard !merged.isEmpty else { return nil }
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
            guard let raw = joinLine(line) else { continue }
            let s = collapseTwin(trimTrailingSeam(raw))
            if s.isEmpty { continue }
            if let last = texts.last, let joined = joinWrap(last, s) {
                texts[texts.count - 1] = joined
                continue
            }
            if let last = texts.last, let kept = absorb(last, s) {
                texts[texts.count - 1] = kept
                continue
            }
            texts.append(s)
        }
        let out = texts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Drop overlap copies: same ink (X IoU / containment) or nearly the same string,
    /// looking back through a Y window — not only the previous run.
    static func dedup(_ runs: [Run]) -> [Run] {
        let sorted = runs.sorted { a, b in
            if abs(a.yMid - b.yMid) < 2 { return a.x0 < b.x0 }
            return a.yMid < b.yMid
        }
        var out: [Run] = []
        for run in sorted {
            var hit: Int?
            for i in stride(from: out.count - 1, through: 0, by: -1) {
                let prev = out[i]
                if run.yMid - prev.yMid > max(prev.yH, run.yH, 12) * 1.8 { break }
                if isOverlapCopy(prev, run) {
                    hit = i
                    break
                }
            }
            if let i = hit {
                out[i] = better(out[i], run)
                continue
            }
            out.append(run)
        }
        return out
    }

    private static func joinLine(_ line: [Run]) -> String? {
        let ordered = line.sorted { $0.x0 < $1.x0 }
        var s = ""
        var prev: Run?
        for run in ordered {
            if let p = prev, isOverlapCopy(p, run) {
                let win = better(p, run)
                if s.hasSuffix(p.text) {
                    s.removeLast(p.text.count)
                    if s.hasSuffix(" ") { s.removeLast() }
                }
                if s.isEmpty {
                    s = win.text
                } else if win.x0 - (s.isEmpty ? 0 : p.x1) > 8, needsSpace(s, win.text) {
                    s += " " + win.text
                } else if needsSpace(s, win.text) {
                    s += " " + win.text
                } else {
                    s += win.text
                }
                prev = win
                continue
            }
            if let p = prev, similar(p.text, run.text) {
                prev = better(p, run)
                if quality(run.text) > quality(p.text) {
                    if s.hasSuffix(p.text) {
                        s.removeLast(p.text.count)
                        if s.hasSuffix(" ") { s.removeLast() }
                    }
                    s = s.isEmpty ? run.text : s + (needsSpace(s, run.text) ? " " : "") + run.text
                }
                continue
            }
            if s.isEmpty {
                s = run.text
            } else if let p = prev, run.x0 - p.x1 > 8 {
                s += " " + run.text
            } else if needsSpace(s, run.text) {
                s += " " + run.text
            } else {
                s += run.text
            }
            prev = run
        }
        return s.isEmpty ? nil : s
    }

    private static func isOverlapCopy(_ a: Run, _ b: Run) -> Bool {
        let tol = max(min(a.yH, b.yH) * 0.7, 4)
        guard abs(a.yMid - b.yMid) < tol else { return false }
        if similar(a.text, b.text) { return true }
        let inter = min(a.x1, b.x1) - max(a.x0, b.x0)
        guard inter > 0 else { return false }
        let union = max(a.x1, b.x1) - min(a.x0, b.x0)
        let iou = inter / max(union, 1)
        if iou >= 0.45 { return true }
        // A short clipped fragment sitting inside a full-width box.
        let aw = max(a.x1 - a.x0, 1)
        let bw = max(b.x1 - b.x0, 1)
        let contained = (a.x0 >= b.x0 - 8 && a.x1 <= b.x1 + 8) || (b.x0 >= a.x0 - 8 && b.x1 <= a.x1 + 8)
        if contained, min(aw, bw) / max(aw, bw) < 0.55 {
            let short = a.text.count <= b.text.count ? a.text : b.text
            let long = a.text.count <= b.text.count ? b.text : a.text
            if isFragment(short, of: long) { return true }
            if quality(short) + 8 < quality(long) { return true }
        }
        return false
    }

    private static func better(_ a: Run, _ b: Run) -> Run {
        let qa = quality(a.text)
        let qb = quality(b.text)
        var win = a
        if qb != qa {
            win = qb > qa ? b : a
        } else if abs(a.confidence - b.confidence) > 0.08 {
            win = b.confidence > a.confidence ? b : a
        } else if abs(a.edgeDist - b.edgeDist) > 6 {
            win = b.edgeDist > a.edgeDist ? b : a
        } else if b.text.count != a.text.count {
            win = b.text.count > a.text.count ? b : a
        }
        win.x0 = min(a.x0, b.x0)
        win.x1 = max(a.x1, b.x1)
        win.yH = max(a.yH, b.yH)
        win.yMid = (a.yMid + b.yMid) / 2
        win.edgeDist = max(a.edgeDist, b.edgeDist)
        win.confidence = max(a.confidence, b.confidence)
        return win
    }

    /// If `b` is an overlap fragment of `a` (or vice versa), return the keeper.
    static func absorb(_ a: String, _ b: String) -> String? {
        if similar(a, b) {
            return quality(a) >= quality(b) ? a : b
        }
        if isFragment(b, of: a) { return a }
        if isFragment(a, of: b) { return b }
        return nil
    }

    /// Visual wrap: previous line was cut mid-phrase (`这盘棋就活` + `了。`).
    static func joinWrap(_ a: String, _ b: String) -> String? {
        guard let last = a.last, !"。！？；…".contains(last) else { return nil }
        let cb = compact(b)
        guard (2...4).contains(cb.count), cb.contains(where: isHan) else { return nil }
        if b.first?.isNumber == true { return nil }
        if needsSpace(a, b) { return a + " " + b }
        return a + b
    }

    private static func isFragment(_ short: String, of long: String) -> Bool {
        let s = compact(short)
        let l = compact(long)
        guard !s.isEmpty, s.count < l.count else { return false }
        let ratio = Double(s.count) / Double(l.count)
        guard s.count <= 12 || ratio <= 0.5 else { return false }
        // 2-char tails like `了。` match too many sentence endings.
        if s.count >= 4, l.hasSuffix(s) || l.hasPrefix(s) { return true }
        if s.count == 3, l.hasSuffix(s) || l.hasPrefix(s) { return true }
        if s.count >= 6, l.contains(s) { return true }
        return false
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let na = compact(a)
        let nb = compact(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }
        let short = na.count <= nb.count ? na : nb
        let long = na.count <= nb.count ? nb : na
        if short.count >= 4, long.contains(short) { return true }
        if short.count >= 3, long.hasPrefix(short) || long.hasSuffix(short), ratioOK(short, long) {
            return true
        }
        // Overlap copies are about the same length. Accounting lines that
        // merely share 枚/按/亿 must not collapse into each other.
        let lenRatio = Double(min(na.count, nb.count)) / Double(max(na.count, nb.count))
        guard lenRatio >= 0.72 else { return false }
        let ca = Array(cjkSkeleton(a))
        let cb = Array(cjkSkeleton(b))
        if ca.count >= 10, cb.count >= 10 {
            let n = lcs(ca, cb)
            let ceil = max(ca.count, cb.count)
            if n >= 8, Double(n) / Double(ceil) >= 0.78 { return true }
        }
        if short.count >= 16 {
            let n = lcs(Array(na), Array(nb))
            if n >= 12, Double(n) / Double(max(na.count, nb.count)) >= 0.85 { return true }
        }
        return false
    }

    private static func ratioOK(_ short: String, _ long: String) -> Bool {
        Double(short.count) / Double(max(long.count, 1)) <= 0.5
    }

    /// A+A' glued into one string at a page seam (末/未, half-garbled twin).
    /// Only split when the two halves are about the same length — otherwise
    /// "17.0亿美元。ETH…" looks like a false twin around 美元.
    static func collapseTwin(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count >= 20 else { return s }
        let n = chars.count
        let lo = max(8, (n * 2) / 5)
        let hi = min(n - 8, (n * 3) / 5)
        guard lo <= hi else { return s }
        var best: (balance: Int, keep: String)?
        for i in lo...hi {
            let left = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
            let right = String(chars[i...]).trimmingCharacters(in: .whitespaces)
            guard left.count >= 8, right.count >= 8 else { continue }
            let minLen = min(left.count, right.count)
            let maxLen = max(left.count, right.count)
            guard Double(minLen) / Double(maxLen) >= 0.65 else { continue }
            guard similar(left, right) else { continue }
            let keep = quality(left) >= quality(right) ? left : right
            let balance = -abs(left.count - right.count)
            if best == nil || balance > best!.balance {
                best = (balance, keep)
            }
        }
        return best?.keep ?? s
    }

    /// Drop a non-CJK junk tail (Arabic / kana / seam glyphs) after the last Han.
    /// ASCII like `USDT` after CJK is kept.
    static func trimGarbledTail(_ s: String) -> String {
        let chars = Array(s)
        guard chars.contains(where: isHan) else { return s }
        guard let iHan = chars.lastIndex(where: isHan) else { return s }
        var end = iHan + 1
        while end < chars.count, isCJKPunct(chars[end]) || chars[end].isWhitespace {
            end += 1
        }
        if end >= chars.count { return trimTrailingSeam(s) }
        let tail = chars[end...]
        let junk = tail.filter { isArabic($0) || isKana($0) }.count
        let cut = junk >= 1 ? String(chars[..<end]) : s
        return trimTrailingSeam(cut)
    }

    private static func isSeamJunk(_ s: String) -> Bool {
        let t = compact(s)
        return t.isEmpty || (t.count <= 2 && t.allSatisfy { "-－—·•|".contains($0) })
    }

    /// Isolated dash left by a clipped overlap (`事 -`).
    private static func trimTrailingSeam(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let last = t.last, "-－—·".contains(last) {
            let prev = t.dropLast().last
            if let prev, isHan(prev) || prev.isWhitespace {
                t.removeLast()
                t = t.trimmingCharacters(in: .whitespaces)
                continue
            }
            break
        }
        return t
    }

    static func quality(_ s: String) -> Int {
        var q = 0
        for ch in s {
            if isHan(ch) { q += 4 }
            else if isCJKPunct(ch) { q += 2 }
            else if ch.isLetter || ch.isNumber { q += 2 }
            else if isArabic(ch) || isKana(ch) { q -= 5 }
            else if ch == "_" || ch == "%" { q -= 2 }
        }
        if let last = s.last, "。！？".contains(last) { q += 3 }
        return q
    }

    private static func compact(_ s: String) -> String {
        s.filter { !$0.isWhitespace && !$0.isNewline }
    }

    private static func cjkSkeleton(_ s: String) -> String {
        s.filter { isHan($0) }
    }

    private static func lcs(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        if a.count > b.count { return lcs(b, a) }
        var prev = [Int](repeating: 0, count: a.count + 1)
        var cur = [Int](repeating: 0, count: a.count + 1)
        for ch in b {
            for j in 1...a.count {
                if ch == a[j - 1] {
                    cur[j] = prev[j - 1] + 1
                } else {
                    cur[j] = max(prev[j], cur[j - 1])
                }
            }
            swap(&prev, &cur)
        }
        return prev[a.count]
    }

    private static func needsSpace(_ left: String, _ right: String) -> Bool {
        guard let l = left.last, let r = right.first else { return true }
        if isCJK(l) && isCJK(r) { return false }
        // Screenshot body: "美元。ETH" / "1.5分。2025" — no Latin space after CJK punct.
        if isCJKPunct(l) { return false }
        if l.isWhitespace || r.isWhitespace { return false }
        if l.isLetter || l.isNumber || r.isLetter || r.isNumber { return true }
        return false
    }

    private static func isCJK(_ ch: Character) -> Bool {
        isHan(ch) || isCJKPunct(ch)
    }

    private static func isHan(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func isCJKPunct(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return "。，、；：？！「」『』（）【】《》".contains(ch)
        }
    }

    private static func isArabic(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
            || (0x08A0...0x08FF).contains(v) || (0xFB50...0xFDFF).contains(v)
    }

    private static func isKana(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
            || (0xFF66...0xFF9D).contains(v)
    }
}
