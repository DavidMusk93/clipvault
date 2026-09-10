import CryptoKit
import Foundation

/// Line-level git-style 3-way merge for Compose markdown snapshots.
/// Conflict hunks are ordered by text so `threeWay(base, a, b) == threeWay(base, b, a)`.
enum ComposeMerge {
    struct Result: Equatable {
        var body: String
        var conflict: Bool
    }

    static func threeWay(base: String, a: String, b: String) -> Result {
        if a == b { return Result(body: a, conflict: false) }
        if a == base { return Result(body: b, conflict: false) }
        if b == base { return Result(body: a, conflict: false) }
        let bl = lines(base)
        let al = lines(a)
        let cl = lines(b)
        if bl.count > 8000 || al.count > 8000 || cl.count > 8000 {
            return both(al, cl)
        }
        let merged = mergeLines(base: bl, a: al, b: cl)
        return Result(body: joined(merged.lines), conflict: merged.conflict)
    }

    static func both(_ a: String, _ b: String) -> Result {
        both(lines(a), lines(b))
    }

    private static func both(_ a: [String], _ b: [String]) -> Result {
        if a == b { return Result(body: joined(a), conflict: false) }
        return Result(body: joined(conflictHunk(a, b)), conflict: true)
    }

    static func hasConflictMarkers(_ text: String) -> Bool {
        text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ")
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
            if s1 < base.count {
                // matched stable line is emitted after the gap
            }
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

    private static func conflictHunk(_ x: [String], _ y: [String]) -> [String] {
        let sx = joined(x)
        let sy = joined(y)
        let (lo, hi): ([String], [String])
        if sx < sy { lo = x; hi = y }
        else if sy < sx { lo = y; hi = x }
        else { lo = x; hi = y }
        let idLo = stamp(joined(lo))
        let idHi = stamp(joined(hi))
        var out = ["<<<<<<< \(idLo)"]
        out.append(contentsOf: lo)
        out.append("=======")
        out.append(contentsOf: hi)
        out.append(">>>>>>> \(idHi)")
        return out
    }

    private static func stamp(_ s: String) -> String {
        let d = SHA256.hash(data: Data(s.utf8))
        return d.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
