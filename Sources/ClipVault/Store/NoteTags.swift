import Foundation

/// 服务端笔记 tag 提取 —— 与 web 面板 `extractNoteTags()`（web/index.html）同语义：
/// 逐行扫描 markdown，跳过代码围栏；`#tag` 的 tag 字符是 `[\p{L}\p{N}_/-]{1,32}`；
/// 词界 = 前一个字符不是 ASCII `\w` 也不是 `#`（JS `[^\w#]` 是 ASCII 语义，
/// CJK 前缀合法）；大小写不敏感去重，保留首次出现的原形。
///
/// 本文件保持零依赖，供 `tests/note_tags_main.swift` 单独 swiftc 编译。
enum NoteTags {
    static let maxTags = 64
    static let regex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_#])#([\\p{L}\\p{N}_/-]{1,32})")

    static func extract(from markdown: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var fence = false
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if isFence(rawLine) { fence.toggle(); continue }
            if fence { continue }
            let ns = line as NSString
            let length = ns.length
            if length == 0 { continue }
            for m in regex.matches(in: line, range: NSRange(location: 0, length: length)) {
                let r = m.range(at: 1)
                guard r.location != NSNotFound, r.location + r.length <= length else { continue }
                let raw = ns.substring(with: r)
                let key = raw.lowercased()
                if seen.insert(key).inserted {
                    out.append(raw)
                    if out.count >= maxTags { return out }
                }
            }
        }
        return out
    }

    /// `^\s{0,3}``` ` —— JS 那边 `\s` 含 tab，这里同样数前导空白。
    private static func isFence(_ line: Substring) -> Bool {
        var i = line.startIndex
        var ws = 0
        while i < line.endIndex, ws < 3, line[i] == " " || line[i] == "\t" {
            i = line.index(after: i)
            ws += 1
        }
        return line[i...].hasPrefix("```")
    }
}
