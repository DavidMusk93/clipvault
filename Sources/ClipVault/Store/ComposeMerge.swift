import CryptoKit
import Foundation

/// Line-level git-style 3-way merge for Compose markdown snapshots.
/// Conflict hunks are ordered by text so `threeWay(base, a, b) == threeWay(base, b, a)`.
///
/// Nested `<<<<<<<` wrapping (sync `both()` of an already-conflicted body) is a
/// product-loss bug: one note becomes hundreds of copies of itself. Flatten to
/// unique leaves before emitting a hunk. Same-title linear history keeps the
/// longest leaf. Never concatenate two whole documents.
enum ComposeMerge {
    struct Result: Equatable {
        var body: String
        var conflict: Bool
    }

    static func threeWay(base: String, a: String, b: String) -> Result {
        let a2 = peelExploded(a)
        let b2 = peelExploded(b)
        let base2 = peelExploded(base)
        if a2 == b2 { return Result(body: a2, conflict: hasConflictMarkers(a2)) }
        if a2 == base2 { return Result(body: b2, conflict: hasConflictMarkers(b2)) }
        if b2 == base2 { return Result(body: a2, conflict: hasConflictMarkers(a2)) }
        let bl = lines(base2)
        let al = lines(a2)
        let cl = lines(b2)
        if bl.count > 8000 || al.count > 8000 || cl.count > 8000 {
            return flattenLeaves(uniqueLeaves(a2) + uniqueLeaves(b2))
        }
        let merged = mergeLines(base: bl, a: al, b: cl)
        let raw = joined(merged.lines)
        if isExploded(raw) { return flatten(raw) }
        return Result(body: raw, conflict: merged.conflict)
    }

    static func both(_ a: String, _ b: String) -> Result {
        flattenLeaves(uniqueLeaves(a) + uniqueLeaves(b))
    }

    static func flatten(_ text: String) -> Result {
        flattenLeaves(uniqueLeaves(text))
    }

    static func hasConflictMarkers(_ text: String) -> Bool {
        text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ")
    }

    /// Three or more start markers means the body was wrapped, not a normal 1–2 hunk merge.
    static func isExploded(_ text: String) -> Bool {
        markerStartCount(text) >= 3
    }

    static func uniqueLeaves(_ text: String) -> [String] {
        var queue = [text]
        var seen = Set<String>()
        var leaves: [String] = []
        while let cur = queue.popLast() {
            if !hasConflictMarkers(cur) {
                if !cur.isEmpty, seen.insert(cur).inserted { leaves.append(cur) }
                continue
            }
            let chunks = splitTopLevel(cur)
            if chunks.isEmpty {
                if seen.insert(cur).inserted { leaves.append(cur) }
                continue
            }
            var progressed = false
            for chunk in chunks {
                switch chunk {
                case .plain(let s):
                    if s.isEmpty { continue }
                    if hasConflictMarkers(s) {
                        queue.append(s)
                        progressed = true
                    } else if seen.insert(s).inserted {
                        leaves.append(s)
                    }
                case .sides(let lo, let hi):
                    progressed = true
                    if !lo.isEmpty { queue.append(lo) }
                    if !hi.isEmpty { queue.append(hi) }
                }
            }
            if !progressed, seen.insert(cur).inserted {
                leaves.append(cur)
            }
        }
        return leaves.sorted()
    }

    private enum Chunk {
        case plain(String)
        case sides(String, String)
    }

    private static func peelExploded(_ text: String) -> String {
        isExploded(text) ? flatten(text).body : text
    }

    private static func flattenLeaves(_ leaves: [String]) -> Result {
        var seen = Set<String>()
        var uniq: [String] = []
        for s in leaves where !s.isEmpty {
            if seen.insert(s).inserted { uniq.append(s) }
        }
        uniq.sort()
        if uniq.isEmpty { return Result(body: "", conflict: false) }
        if uniq.count == 1 { return Result(body: uniq[0], conflict: false) }
        if uniq.count == 2 {
            return Result(body: joined(emitHunkLines(uniq[0], uniq[1])), conflict: true)
        }
        if sameFamily(uniq) {
            let longest = uniq.max(by: { $0.count < $1.count }) ?? uniq[0]
            return Result(body: longest, conflict: false)
        }
        let top = uniq.sorted { $0.count > $1.count }
        return Result(body: joined(emitHunkLines(top[0], top[1])), conflict: true)
    }

    private static func sameFamily(_ leaves: [String]) -> Bool {
        let keys = Set(leaves.map(familyKey).filter { !$0.isEmpty })
        return keys.count <= 1
    }

    private static func familyKey(_ s: String) -> String {
        for ln in lines(s) {
            let t = ln.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            return t
        }
        return ""
    }

    private static func markerStartCount(_ text: String) -> Int {
        var n = 0
        if text.hasPrefix("<<<<<<< ") { n += 1 }
        var search = text.startIndex
        while let r = text.range(of: "\n<<<<<<< ", range: search..<text.endIndex) {
            n += 1
            search = r.upperBound
        }
        return n
    }

    private static func isStart(_ ln: String) -> Bool { ln.hasPrefix("<<<<<<< ") }
    private static func isMid(_ ln: String) -> Bool { ln == "=======" }
    private static func isEnd(_ ln: String) -> Bool { ln.hasPrefix(">>>>>>> ") }

    private static func splitTopLevel(_ text: String) -> [Chunk] {
        let ls = lines(text)
        var i = 0
        var buf: [String] = []
        var out: [Chunk] = []
        func flush() {
            if !buf.isEmpty {
                out.append(.plain(joined(buf)))
                buf.removeAll(keepingCapacity: true)
            }
        }
        while i < ls.count {
            if isStart(ls[i]) {
                flush()
                let (lo, hi, next) = parseHunk(ls, at: i)
                out.append(.sides(lo, hi))
                i = next
            } else {
                buf.append(ls[i])
                i += 1
            }
        }
        flush()
        return out
    }

    private static func parseHunk(_ ls: [String], at start: Int) -> (String, String, Int) {
        var i = start + 1
        var lo: [String] = []
        var hi: [String] = []
        var phase = 0
        var depth = 1
        while i < ls.count {
            let ln = ls[i]
            if isStart(ln) {
                depth += 1
                if phase == 0 { lo.append(ln) } else { hi.append(ln) }
                i += 1
                continue
            }
            if isMid(ln), depth == 1 {
                phase = 1
                i += 1
                continue
            }
            if isEnd(ln) {
                depth -= 1
                if depth == 0 {
                    return (joined(lo), joined(hi), i + 1)
                }
                if phase == 0 { lo.append(ln) } else { hi.append(ln) }
                i += 1
                continue
            }
            if phase == 0 { lo.append(ln) } else { hi.append(ln) }
            i += 1
        }
        return (joined(lo), joined(hi), ls.count)
    }

    private static func emitHunkLines(_ a: String, _ b: String) -> [String] {
        let (lo, hi): (String, String) = a < b ? (a, b) : (b, a)
        var out = ["<<<<<<< \(stamp(lo))"]
        out.append(contentsOf: lines(lo))
        out.append("=======")
        out.append(contentsOf: lines(hi))
        out.append(">>>>>>> \(stamp(hi))")
        return out
    }

    private static func lines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func joined(_ xs: [String]) -> String {
        xs.joined(separator: "\n")
    }

    private static func mergeLines(base: [String], a: [String], b: [String]) -> (lines: [String], conflict: Bool) {
        let aAt = indexMap(lcsPairs(base, a))
        let bAt = indexMap(lcsPairs(base, b))
        var stable = [-1]
        for i in 0..<base.count {
            if aAt[i] != nil && bAt[i] != nil { stable.append(i) }
        }
        stable.append(base.count)
        var out: [String] = []
        var conflict = false
        for s in 0..<(stable.count - 1) {
            let s0 = stable[s]
            let s1 = stable[s + 1]
            let a0 = s0 == -1 ? -1 : (aAt[s0] ?? -1)
            let a1 = s1 == base.count ? a.count : (aAt[s1] ?? a.count)
            let b0 = s0 == -1 ? -1 : (bAt[s0] ?? -1)
            let b1 = s1 == base.count ? b.count : (bAt[s1] ?? b.count)
            let baseSlice = slice(base, s0 + 1, s1)
            let aSlice = slice(a, a0 + 1, a1)
            let bSlice = slice(b, b0 + 1, b1)
            if aSlice == bSlice {
                out.append(contentsOf: aSlice)
            } else if aSlice == baseSlice {
                out.append(contentsOf: bSlice)
            } else if bSlice == baseSlice {
                out.append(contentsOf: aSlice)
            } else {
                out.append(contentsOf: conflictHunk(aSlice, bSlice))
                conflict = true
            }
            if s1 < base.count {
                out.append(base[s1])
            }
        }
        return (out, conflict)
    }

    private static func slice(_ xs: [String], _ from: Int, _ to: Int) -> [String] {
        let lo = max(0, from)
        let hi = min(xs.count, max(lo, to))
        if lo >= hi { return [] }
        return Array(xs[lo..<hi])
    }

    private static func indexMap(_ pairs: [(Int, Int)]) -> [Int: Int] {
        var m: [Int: Int] = [:]
        for (i, j) in pairs { m[i] = j }
        return m
    }

    private static func lcsPairs(_ x: [String], _ y: [String]) -> [(Int, Int)] {
        let n = x.count
        let m = y.count
        if n == 0 || m == 0 { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if x[i - 1] == y[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            if x[i - 1] == y[j - 1] {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Sides may themselves contain markers; never wrap them raw.
    private static func conflictHunk(_ x: [String], _ y: [String]) -> [String] {
        let r = flattenLeaves(uniqueLeaves(joined(x)) + uniqueLeaves(joined(y)))
        return lines(r.body)
    }

    private static func stamp(_ s: String) -> String {
        let d = SHA256.hash(data: Data(s.utf8))
        return d.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
