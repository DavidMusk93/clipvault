import Foundation
import Network

/// X Articles (x.com/i/article) store headings / lists / fenced code as Draft.js
/// `header-two` / `unordered-list-item` / `MARKDOWN` entities. Many articles never
/// use header-two: section titles stay unstyled 「一、…」. WKWebView+Readability
/// only sees the tweet dump: a stream of `<p>`, lists and atomic code gone.
enum XArticleHTML {
    static func isXURL(_ raw: String) -> Bool {
        guard let host = URL(string: raw)?.host?.lowercased() else { return false }
        return host == "x.com" || host == "www.x.com"
            || host == "twitter.com" || host == "www.twitter.com"
            || host == "mobile.twitter.com"
    }

    static func statusID(from raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "status"), i + 1 < parts.count {
            let id = parts[i + 1].split(separator: "?").first.map(String.init) ?? parts[i + 1]
            if id.allSatisfy(\.isNumber), id.count >= 8 { return id }
        }
        return nil
    }

    /// Readability dump of an X Article: lots of `<p>`, no headings / code / lists.
    static func looksFlattened(_ html: String) -> Bool {
        !looksStructured(html)
    }

    /// Draft.js rebuilt HTML is usable even without `<pre>` / `<h2>`.
    /// Many X Articles are title + lists + unstyled 一、 sections, no code.
    static func looksStructured(_ html: String) -> Bool {
        let lower = html.lowercased()
        for needle in ["<pre", "<code", "<h1", "<h2", "<h3", "<ul", "<ol", "<blockquote", "<figure"] {
            if lower.contains(needle) { return true }
        }
        return false
    }

    /// Authors often type 「一、标题」 as unstyled instead of header-two.
    static func headingLike(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 48 else { return false }
        let ns = t as NSString
        let patterns = [
            "^[一二三四五六七八九十百零〇两]+[、.．]",
            "^第[一二三四五六七八九十百零〇两0-9]+[章节部分篇]",
            "^[0-9]{1,2}[\\.、．]\\s*\\S",
        ]
        for p in patterns {
            let r = ns.range(of: p, options: .regularExpression)
            if r.location == 0, r.length > 0 { return true }
        }
        return false
    }

    static func isUsableArticleHTML(_ html: String) -> Bool {
        html.utf8.count > 80 && html.contains("cv-x-article")
    }

    struct Coverage {
        var mediaExpected = 0
        var mediaRendered = 0
        var atomicExpected = 0
        var atomicRendered = 0
        var atomicDropped = 0
        var markdownExpected = 0
        var markdownRendered = 0
        var warnings: [String] = []

        var json: [String: Any] {
            [
                "mediaExpected": mediaExpected,
                "mediaRendered": mediaRendered,
                "atomicExpected": atomicExpected,
                "atomicRendered": atomicRendered,
                "atomicDropped": atomicDropped,
                "markdownExpected": markdownExpected,
                "markdownRendered": markdownRendered,
                "warnings": warnings,
            ]
        }

        mutating func finalize() {
            warnings = []
            if mediaRendered < mediaExpected {
                warnings.append("\(mediaExpected - mediaRendered) 张图未解析")
            }
            if atomicDropped > 0 {
                warnings.append("\(atomicDropped) 处介质未解析")
            }
            if markdownRendered < markdownExpected {
                warnings.append("代码块 \(markdownRendered)/\(markdownExpected)")
            }
        }
    }

    struct Rendered {
        var html: String
        var coverage: Coverage
    }

    static func enrich(url: String, html: String, title: String) -> (html: String, title: String, engine: String, coverage: Coverage)? {
        guard isXURL(url), looksFlattened(html) else { return nil }
        guard let fetched = fetchArticle(url: url) else { return nil }
        guard let rendered = renderDocument(article: fetched.article),
              isUsableArticleHTML(rendered.html) else { return nil }
        let t = fetched.title.isEmpty ? title : fetched.title
        return (rendered.html, t, "x-article+draftjs", rendered.coverage)
    }

    static func render(article: [String: Any]) -> String? {
        renderDocument(article: article)?.html
    }

    static func renderDocument(article: [String: Any]) -> Rendered? {
        let content = article["content"] as? [String: Any] ?? article
        let blocks = content["blocks"] as? [[String: Any]] ?? []
        guard !blocks.isEmpty else { return nil }
        let entityMap = content["entityMap"]
        let media = mediaIndex(article)
        var cov = Coverage()
        cov.mediaExpected = media.count
        cov.markdownExpected = markdownEntityCount(entityMap)
        var html = ""
        var headingShift = 0
        if let title = (article["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            html += "<h1>\(escape(title))</h1>\n"
            headingShift = 1
        }
        if let cover = coverImageURL(article) {
            html += "<figure><img src=\"\(escape(cover))\" alt=\"\"></figure>\n"
        }
        html += renderBlocks(
            blocks,
            entityMap: entityMap,
            media: media,
            coverage: &cov,
            headingShift: headingShift
        )
        let out = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        let wrapped = "<div class=\"cv-x-article\">\(out)</div>"
        cov.mediaRendered = wrapped.components(separatedBy: "<img ").count - 1
        cov.finalize()
        return Rendered(html: wrapped, coverage: cov)
    }

    static func renderBlocks(_ blocks: [[String: Any]], entityMap: Any?, media: [String: String] = [:]) -> String {
        var cov = Coverage()
        return renderBlocks(blocks, entityMap: entityMap, media: media, coverage: &cov)
    }

    static func renderBlocks(
        _ blocks: [[String: Any]],
        entityMap: Any?,
        media: [String: String] = [:],
        coverage: inout Coverage,
        headingShift: Int = 0
    ) -> String {
        var out = ""
        var listTag: String?
        func flushList() {
            if let tag = listTag {
                out += "</\(tag)>\n"
                listTag = nil
            }
        }
        for block in blocks {
            let type = (block["type"] as? String) ?? "unstyled"
            if type == "unordered-list-item" || type == "ordered-list-item" {
                let tag = type.hasPrefix("ordered") ? "ol" : "ul"
                if listTag != tag {
                    flushList()
                    out += "<\(tag)>\n"
                    listTag = tag
                }
                out += "<li>\(styledText(block, entityMap: entityMap))</li>\n"
                continue
            }
            flushList()
            switch type {
            case "header-one":
                let tag = headerTag(1, shift: headingShift)
                out += "<\(tag)>\(styledText(block, entityMap: entityMap))</\(tag)>\n"
            case "header-two":
                let tag = headerTag(2, shift: headingShift)
                out += "<\(tag)>\(styledText(block, entityMap: entityMap))</\(tag)>\n"
            case "header-three":
                let tag = headerTag(3, shift: headingShift)
                out += "<\(tag)>\(styledText(block, entityMap: entityMap))</\(tag)>\n"
            case "blockquote":
                out += "<blockquote>\(styledText(block, entityMap: entityMap))</blockquote>\n"
            case "code-block":
                out += "<pre><code>\(escape((block["text"] as? String) ?? ""))</code></pre>\n"
            case "atomic":
                coverage.atomicExpected += 1
                let piece = renderAtomic(block, entityMap: entityMap, media: media, coverage: &coverage)
                out += piece
                if !piece.hasSuffix("\n") { out += "\n" }
            default:
                let inner = styledText(block, entityMap: entityMap)
                let plain = ((block["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if headingLike(plain) {
                    out += "<h2>\(inner)</h2>\n"
                } else if !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out += "<p>\(inner)</p>\n"
                }
            }
        }
        flushList()
        return out
    }

    private static func headerTag(_ level: Int, shift: Int) -> String {
        "h\(min(6, max(1, level + shift)))"
    }

    // MARK: - fetch

    static func fetchArticle(url: String) -> (article: [String: Any], title: String)? {
        guard let id = statusID(from: url) else { return nil }
        let endpoints = [
            "https://api.fxtwitter.com/status/\(id)",
            "https://api.fxtwitter.com/i/status/\(id)",
        ]
        for ep in endpoints {
            guard let data = getJSON(ep),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let tweet = (obj["tweet"] as? [String: Any]) ?? obj
            if let article = tweet["article"] as? [String: Any],
               ((article["content"] as? [String: Any])?["blocks"] as? [[String: Any]])?.isEmpty == false {
                let title = (article["title"] as? String)
                    ?? (tweet["text"] as? String)
                    ?? ""
                return (article, title)
            }
        }
        return nil
    }

    // MARK: - private

    private static func coverImageURL(_ article: [String: Any]) -> String? {
        let cover = article["cover_media"] as? [String: Any]
        let info = cover?["media_info"] as? [String: Any]
        if let u = info?["original_img_url"] as? String, u.hasPrefix("http") { return u }
        return nil
    }

    /// fxtwitter: atomic MEDIA has mediaId only; bytes live on article.media_entities.
    static func mediaIndex(_ article: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ d: [String: Any]) {
            let id = stringVal(d["media_id"]) ?? stringVal(d["mediaId"])
            let info = d["media_info"] as? [String: Any]
            guard let url = (info?["original_img_url"] as? String) ?? (d["original_img_url"] as? String),
                  url.hasPrefix("http") else { return }
            if let id { out[id] = url }
        }
        if let arr = article["media_entities"] as? [[String: Any]] {
            arr.forEach(add)
        } else if let dict = article["media_entities"] as? [String: Any] {
            for (_, v) in dict {
                if let d = v as? [String: Any] { add(d) }
            }
        }
        if let cover = article["cover_media"] as? [String: Any] { add(cover) }
        return out
    }

    private struct TextMark {
        var start: Int
        var end: Int
        var kind: Int
        var open: String
        var close: String
    }

    private static func styledText(_ block: [String: Any], entityMap: Any? = nil) -> String {
        let raw = (block["text"] as? String) ?? ""
        let ns = raw as NSString
        let n = ns.length
        var marks: [TextMark] = []

        if let styles = block["inlineStyleRanges"] as? [[String: Any]] {
            for s in styles {
                let off = intVal(s["offset"])
                let len = intVal(s["length"])
                let style = (s["style"] as? String ?? "").lowercased()
                let pair: (Int, String)?
                if style.contains("bold") { pair = (1, "strong") }
                else if style.contains("italic") { pair = (2, "em") }
                else if style.contains("underline") { pair = (3, "u") }
                else if style.contains("strikethrough") || style == "line-through" { pair = (4, "s") }
                else if style == "code" || style.contains("inlinecode") || style.contains("inline-code") {
                    pair = (5, "code")
                } else { pair = nil }
                if let pair, len > 0, off >= 0, off + len <= n {
                    marks.append(TextMark(
                        start: off, end: off + len, kind: pair.0,
                        open: "<\(pair.1)>", close: "</\(pair.1)>"
                    ))
                }
            }
        }

        if let ranges = block["entityRanges"] as? [[String: Any]] {
            for r in ranges {
                let off = intVal(r["offset"])
                let len = intVal(r["length"])
                let end = off + len
                guard len > 0, off >= 0, end <= n else { continue }
                let key = intVal(r["key"])
                guard let ent = lookupEntity(entityMap, key: key) else { continue }
                let type = (ent["type"] as? String ?? "").uppercased()
                if type == "LINK" || type == "MENTION" {
                    if let href = linkHREF(from: ent["data"], fallbackText: ns.substring(with: NSRange(location: off, length: len))) {
                        appendLink(&marks, start: off, end: end, href: href)
                    }
                }
            }
        }

        if let data = block["data"] as? [String: Any] {
            if let urls = data["urls"] as? [[String: Any]] {
                for u in urls {
                    let start = intVal(u["fromIndex"] ?? u["offset"])
                    var end = intVal(u["toIndex"])
                    if end <= start { end = start + intVal(u["length"]) }
                    guard end > start, start >= 0, end <= n else { continue }
                    let slice = ns.substring(with: NSRange(location: start, length: end - start))
                    if let href = linkHREF(from: u, fallbackText: slice) ?? safeHTTPURL(slice) {
                        appendLink(&marks, start: start, end: end, href: href)
                    }
                }
            }
            if let mentions = data["mentions"] as? [[String: Any]] {
                for m in mentions {
                    let start = intVal(m["fromIndex"] ?? m["offset"])
                    var end = intVal(m["toIndex"])
                    if end <= start { end = start + intVal(m["length"]) }
                    guard end > start, start >= 0, end <= n else { continue }
                    let slice = ns.substring(with: NSRange(location: start, length: end - start))
                    let handle = slice.hasPrefix("@") ? String(slice.dropFirst()) : slice
                    if let href = safeHTTPURL("https://x.com/\(handle)") {
                        appendLink(&marks, start: start, end: end, href: href)
                    }
                }
            }
        }

        if marks.isEmpty { return escape(raw) }
        return applyMarks(ns, marks)
    }

    private static func appendLink(_ marks: inout [TextMark], start: Int, end: Int, href: String) {
        if marks.contains(where: { $0.kind == 0 && $0.start == start && $0.end == end }) { return }
        marks.append(TextMark(
            start: start, end: end, kind: 0,
            open: anchorOpen(href), close: "</a>"
        ))
    }

    private static func applyMarks(_ ns: NSString, _ marks: [TextMark]) -> String {
        let n = ns.length
        func active(_ i: Int) -> [TextMark] {
            marks.filter { $0.start <= i && i < $0.end }
                .sorted { a, b in
                    if a.kind != b.kind { return a.kind < b.kind }
                    if a.start != b.start { return a.start < b.start }
                    return a.end > b.end
                }
        }
        func same(_ a: TextMark, _ b: TextMark) -> Bool {
            a.kind == b.kind && a.start == b.start && a.end == b.end && a.open == b.open
        }
        var stack: [TextMark] = []
        var out = ""
        var i = 0
        func sync() {
            let want = i < n ? active(i) : []
            while !stack.isEmpty {
                if stack.count <= want.count,
                   zip(stack, want).prefix(stack.count).allSatisfy({ same($0.0, $0.1) }) {
                    break
                }
                out += stack.removeLast().close
            }
            for m in want.dropFirst(stack.count) {
                out += m.open
                stack.append(m)
            }
        }
        while i < n {
            sync()
            let step = utf16Step(ns, i)
            out += escape(ns.substring(with: NSRange(location: i, length: step)))
            i += step
        }
        sync()
        return out
    }

    private static func utf16Step(_ ns: NSString, _ i: Int) -> Int {
        guard i < ns.length else { return 0 }
        let c = ns.character(at: i)
        if i + 1 < ns.length, UTF16.isLeadSurrogate(c), UTF16.isTrailSurrogate(ns.character(at: i + 1)) {
            return 2
        }
        return 1
    }

    private static func anchorOpen(_ href: String) -> String {
        "<a href=\"\(escape(href))\" rel=\"noreferrer\" target=\"_blank\">"
    }

    private static func linkHREF(from data: Any?, fallbackText: String? = nil) -> String? {
        if let href = dictString(data, "url") ?? dictString(data, "href") {
            return safeHTTPURL(href)
        }
        if let d = data as? [String: Any] {
            if let href = d["url"] as? String ?? d["href"] as? String {
                return safeHTTPURL(href)
            }
        }
        return safeHTTPURL(fallbackText)
    }

    private static func safeHTTPURL(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        guard let u = URL(string: s),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              u.host != nil
        else { return nil }
        return s
    }

    private static func renderAtomic(
        _ block: [String: Any],
        entityMap: Any?,
        media: [String: String],
        coverage: inout Coverage
    ) -> String {
        let ranges = block["entityRanges"] as? [[String: Any]] ?? []
        guard let first = ranges.first else {
            return droppedFigure(entity: "atomic", detail: nil, coverage: &coverage)
        }
        let key = intVal(first["key"])
        guard let ent = lookupEntity(entityMap, key: key) else {
            return droppedFigure(entity: "atomic", detail: "key=\(key)", coverage: &coverage)
        }
        let type = (ent["type"] as? String ?? "").uppercased()
        if type == "MARKDOWN", let md = dictString(ent["data"], "markdown") {
            coverage.atomicRendered += 1
            coverage.markdownRendered += 1
            let fence = renderFence(md)
            return fence.hasSuffix("\n") ? fence : fence + "\n"
        }
        // Decorative section rule. Not an image; do not emit cv-x-dropped.
        if type == "DIVIDER" || type == "HORIZONTAL_RULE" || type == "HR" {
            coverage.atomicRendered += 1
            return "<hr>\n"
        }
        if type == "LINK" {
            if let href = linkHREF(from: ent["data"]) {
                coverage.atomicRendered += 1
                return "<p>\(anchorOpen(href))\(escape(href))</a></p>\n"
            }
            return droppedFigure(entity: "LINK", detail: nil, coverage: &coverage)
        }
        if type == "IMAGE" || type == "MEDIA" {
            if let src = imageURL(from: ent["data"], media: media) {
                coverage.atomicRendered += 1
                return "<figure><img src=\"\(escape(src))\" alt=\"\"></figure>\n"
            }
            let ids = mediaIds(from: ent["data"])
            let detail = ids.isEmpty ? type.lowercased() : "mediaId=\(ids.joined(separator: ","))"
            return droppedFigure(entity: type, detail: detail, coverage: &coverage)
        }
        return droppedFigure(entity: type.isEmpty ? "atomic" : type, detail: nil, coverage: &coverage)
    }

    private static func droppedFigure(entity: String, detail: String?, coverage: inout Coverage) -> String {
        coverage.atomicDropped += 1
        let cap: String
        if let detail, !detail.isEmpty {
            cap = "未归档的插图（\(escape(detail))）"
        } else {
            cap = "未归档的介质（\(escape(entity))）"
        }
        return "<figure class=\"cv-x-dropped\" data-entity=\"\(escape(entity))\"><figcaption>\(cap)</figcaption></figure>\n"
    }

    private static func mediaIds(from data: Any?) -> [String] {
        guard let d = data as? [String: Any] else { return [] }
        var ids: [String] = []
        if let items = d["mediaItems"] as? [[String: Any]] {
            for item in items {
                if let id = stringVal(item["mediaId"]) ?? stringVal(item["media_id"]) {
                    ids.append(id)
                }
            }
        }
        if let id = stringVal(d["mediaId"]) ?? stringVal(d["media_id"]) {
            ids.append(id)
        }
        return ids
    }

    private static func markdownEntityCount(_ map: Any?) -> Int {
        var n = 0
        eachEntity(map) { ent in
            if ((ent["type"] as? String) ?? "").uppercased() == "MARKDOWN" { n += 1 }
        }
        return n
    }

    private static func eachEntity(_ map: Any?, _ fn: ([String: Any]) -> Void) {
        if let arr = map as? [[String: Any]] {
            for e in arr { fn((e["value"] as? [String: Any]) ?? e) }
            return
        }
        guard let dict = map as? [String: Any] else { return }
        if dict["type"] != nil {
            fn((dict["value"] as? [String: Any]) ?? dict)
            return
        }
        for (_, v) in dict {
            if let d = v as? [String: Any] { fn((d["value"] as? [String: Any]) ?? d) }
        }
    }

    private static func imageURL(from data: Any?, media: [String: String]) -> String? {
        if let src = dictString(data, "src") ?? dictString(data, "url"), src.hasPrefix("http") {
            return src
        }
        guard let d = data as? [String: Any] else { return nil }
        if let info = d["media_info"] as? [String: Any],
           let u = info["original_img_url"] as? String, u.hasPrefix("http") {
            return u
        }
        let items = d["mediaItems"] as? [[String: Any]] ?? []
        for item in items {
            if let id = stringVal(item["mediaId"]) ?? stringVal(item["media_id"]),
               let u = media[id] {
                return u
            }
        }
        if let id = stringVal(d["mediaId"]) ?? stringVal(d["media_id"]),
           let u = media[id] {
            return u
        }
        return nil
    }

    static func renderFence(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lang = ""
        if let first = lines.first, first.hasPrefix("```") {
            lang = String(first.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.removeFirst()
            if let last = lines.last, last.hasPrefix("```") {
                lines.removeLast()
            }
        }
        lang = lang.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "_" }
        let body = lines.joined(separator: "\n")
        let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
        return "<pre><code\(cls)>\(escape(body))</code></pre>"
    }

    /// fxtwitter `entityMap` is a shuffled `{key,value}` list. Match `key` first;
    /// array index is a last resort (dense maps only). Index 10 ≠ entity key 10.
    private static func lookupEntity(_ map: Any?, key: Int) -> [String: Any]? {
        guard let map else { return nil }
        if let arr = map as? [[String: Any]] {
            if let hit = arr.first(where: { intVal($0["key"]) == key }) {
                return (hit["value"] as? [String: Any]) ?? hit
            }
            if key >= 0, key < arr.count {
                let row = arr[key]
                return (row["value"] as? [String: Any]) ?? row
            }
        }
        if let dict = map as? [String: Any] {
            let row = dict[String(key)] ?? dict["\(key)"]
            return row as? [String: Any]
        }
        return nil
    }

    private static func dictString(_ raw: Any?, _ key: String) -> String? {
        if let d = raw as? [String: Any] { return d[key] as? String }
        if let d = raw as? [String: String] { return d[key] }
        return nil
    }

    private static func intVal(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String, let i = Int(s) { return i }
        return 0
    }

    private static func stringVal(_ raw: Any?) -> String? {
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let i = raw as? Int { return String(i) }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// After wrapping some UTF-16 slices in tags, escape remaining plain text.
    /// Tag inners were already escaped; copy the whole element so `&gt;` stays `&gt;`.
    private static func escapeOutsideTags(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<" {
                if let close = s[i...].firstIndex(of: ">") {
                    let tag = String(s[i...close])
                    out += tag
                    i = s.index(after: close)
                    if !tag.hasPrefix("</"), !tag.hasSuffix("/>") {
                        let name = tag.dropFirst().prefix(while: { $0.isLetter || $0.isNumber })
                        if !name.isEmpty {
                            let closer = "</\(name)>"
                            if let end = s[i...].range(of: closer) {
                                out += s[i..<end.upperBound]
                                i = end.upperBound
                            }
                        }
                    }
                    continue
                }
            }
            switch s[i] {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(s[i])
            }
            i = s.index(after: i)
        }
        return out
    }

    private static let fetchSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        if #available(macOS 14.0, *), portOpen(2080) {
            c.proxyConfigurations = [
                ProxyConfiguration(socksv5Proxy: NWEndpoint.hostPort(host: "127.0.0.1", port: 2080))
            ]
        }
        return URLSession(configuration: c)
    }()

    private static func portOpen(_ port: UInt16) -> Bool {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ok = true
                sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .utility))
        _ = sem.wait(timeout: .now() + 0.25)
        conn.cancel()
        return ok
    }

    private static func getJSON(_ urlStr: String) -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        fetchSession.dataTask(with: req) { data, resp, _ in
            if let data,
               let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               data.count > 80 {
                out = data
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return out
    }
}
