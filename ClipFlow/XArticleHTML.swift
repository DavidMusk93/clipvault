import Foundation
import Network

/// X Articles (x.com/i/article) store headings / lists / fenced code as Draft.js
/// `header-two` / `MARKDOWN` entities. WKWebView+Readability only sees the
/// tweet dump: a stream of `<p>`, with atomic code blocks collapsed to spaces.
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

    /// Readability dump of an X Article: lots of `<p>`, no `<pre>` / `<h2>`.
    static func looksFlattened(_ html: String) -> Bool {
        let lower = html.lowercased()
        let hasCode = lower.contains("<pre") || lower.contains("<code")
        let hasHead = lower.contains("<h1") || lower.contains("<h2") || lower.contains("<h3")
        return !hasCode && !hasHead
    }

    static func enrich(url: String, html: String, title: String) -> (html: String, title: String, engine: String)? {
        guard isXURL(url), looksFlattened(html) else { return nil }
        guard let fetched = fetchArticle(url: url) else { return nil }
        let rendered = render(article: fetched.article)
        guard let rendered, rendered.utf8.count > 80 else { return nil }
        if !rendered.lowercased().contains("<pre"), !rendered.lowercased().contains("<h2") {
            return nil
        }
        let t = fetched.title.isEmpty ? title : fetched.title
        return (rendered, t, "x-article+draftjs")
    }

    static func render(article: [String: Any]) -> String? {
        let content = article["content"] as? [String: Any] ?? article
        let blocks = content["blocks"] as? [[String: Any]] ?? []
        guard !blocks.isEmpty else { return nil }
        let entityMap = content["entityMap"]
        var html = ""
        if let title = (article["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            html += "<h1>\(escape(title))</h1>\n"
        }
        if let cover = coverImageURL(article) {
            html += "<figure><img src=\"\(escape(cover))\" alt=\"\"></figure>\n"
        }
        html += renderBlocks(blocks, entityMap: entityMap)
        let out = html.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : "<div class=\"cv-x-article\">\(out)</div>"
    }

    static func renderBlocks(_ blocks: [[String: Any]], entityMap: Any?) -> String {
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
                out += "<li>\(styledText(block))</li>\n"
                continue
            }
            flushList()
            switch type {
            case "header-one":
                out += "<h1>\(styledText(block))</h1>\n"
            case "header-two":
                out += "<h2>\(styledText(block))</h2>\n"
            case "header-three":
                out += "<h3>\(styledText(block))</h3>\n"
            case "blockquote":
                out += "<blockquote>\(styledText(block))</blockquote>\n"
            case "code-block":
                out += "<pre><code>\(escape((block["text"] as? String) ?? ""))</code></pre>\n"
            case "atomic":
                if let piece = renderAtomic(block, entityMap: entityMap) {
                    out += piece
                    if !piece.hasSuffix("\n") { out += "\n" }
                }
            default:
                let inner = styledText(block)
                if !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out += "<p>\(inner)</p>\n"
                }
            }
        }
        flushList()
        return out
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

    private static func styledText(_ block: [String: Any]) -> String {
        let raw = (block["text"] as? String) ?? ""
        let ns = raw as NSString
        var marks: [(Int, Int, String)] = []
        if let styles = block["inlineStyleRanges"] as? [[String: Any]] {
            for s in styles {
                let off = intVal(s["offset"])
                let len = intVal(s["length"])
                let style = (s["style"] as? String ?? "").lowercased()
                let tag: String?
                if style.contains("bold") { tag = "strong" }
                else if style.contains("italic") { tag = "em" }
                else { tag = nil }
                if let tag, len > 0, off >= 0, off + len <= ns.length {
                    marks.append((off, off + len, tag))
                }
            }
        }
        marks.sort { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return a.1 > b.1
        }
        var body = raw
        for (start, end, tag) in marks {
            let innerRange = NSRange(location: start, length: end - start)
            let inner = escape((body as NSString).substring(with: innerRange))
            let wrapped = "<\(tag)>\(inner)</\(tag)>"
            body = (body as NSString).replacingCharacters(in: innerRange, with: wrapped)
        }
        if marks.isEmpty { return escape(raw) }
        // Already escaped insides of marks; escape the leftover plain runs.
        return escapeOutsideTags(body)
    }

    private static func renderAtomic(_ block: [String: Any], entityMap: Any?) -> String? {
        let ranges = block["entityRanges"] as? [[String: Any]] ?? []
        guard let first = ranges.first else { return nil }
        let key = intVal(first["key"])
        guard let ent = lookupEntity(entityMap, key: key) else { return nil }
        let type = (ent["type"] as? String ?? "").uppercased()
        if type == "MARKDOWN", let md = dictString(ent["data"], "markdown") {
            return renderFence(md)
        }
        if type == "IMAGE" || type == "MEDIA" {
            if let src = dictString(ent["data"], "src") ?? dictString(ent["data"], "url"),
               src.hasPrefix("http") {
                return "<figure><img src=\"\(escape(src))\" alt=\"\"></figure>"
            }
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

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// After wrapping some UTF-16 slices in tags, escape remaining plain text.
    private static func escapeOutsideTags(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<" {
                if let close = s[i...].firstIndex(of: ">") {
                    out += s[i...close]
                    i = s.index(after: close)
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
