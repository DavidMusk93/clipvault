import Foundation

/// mp.weixin.qq.com puts the article in the first HTML response (`#js_content`).
/// WKWebView on that page pulls a multi-megabyte script shell and, when :2080 is
/// up, sends it through the overseas SOCKS proxy. Direct fetch + this slice is
/// the archive. Domestic image hosts (qpic) use the same direct preference.
enum WeixinArticleHTML {
    struct Article {
        var title: String
        var html: String
        var text: String
    }

    static func isArticleURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        guard host == "mp.weixin.qq.com" else { return false }
        return url.path == "/s" || url.path.hasPrefix("/s/")
    }

    /// `src` must not match the tail of `data-src`. `\b` is true between `-` and `s`.
    static func attributeRegex(_ name: String, capture: Bool = false) -> NSRegularExpression? {
        let value = capture ? #"([^"]*)"# : #"[^"]*"#
        let pat = #"(?i)(?<![A-Za-z0-9_-])"#
            + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*""#
            + value
        return try? NSRegularExpression(pattern: pat)
    }

    /// Hosts that answer on the direct path and misbehave through the v2raya SOCKS hop.
    static func prefersDirectHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasSuffix(".") { h.removeLast() }
        if h == "mp.weixin.qq.com" || h == "weixin.qq.com" || h.hasSuffix(".weixin.qq.com") { return true }
        if h == "wx.qq.com" || h.hasSuffix(".wx.qq.com") { return true }
        if h == "qpic.cn" || h.hasSuffix(".qpic.cn") { return true }
        if h == "qlogo.cn" || h.hasSuffix(".qlogo.cn") { return true }
        return false
    }

    static func extract(html page: String) -> Article? {
        guard let sliced = sliceElement(page, id: "js_content") else { return nil }
        let html = revealRoot(promoteLazyImages(sliced))
        let text = plainText(html)
        guard text.count >= 40 else { return nil }
        let title = metaContent(page, property: "og:title")
            ?? innerTextOfId(page, id: "activity-name")
            ?? ""
        return Article(title: unescape(title), html: html, text: String(text.prefix(20_000)))
    }

    // MARK: - slice

    private static func sliceElement(_ html: String, id: String) -> String? {
        let needles = ["id=\"\(id)\"", "id='\(id)'"]
        guard let hit = needles.compactMap({ html.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        var i = hit.lowerBound
        var start: String.Index?
        while i > html.startIndex {
            html.formIndex(before: &i)
            if html[i] == "<" { start = i; break }
            if html[i] == ">" { return nil }
        }
        guard let start else { return nil }
        let name = elementName(html, at: start)
        guard name == "div" || name == "section" else { return nil }
        return balanced(html, from: start, name: name)
    }

    private static func elementName(_ html: String, at start: String.Index) -> String {
        var i = html.index(after: start)
        while i < html.endIndex, html[i] == "/" { i = html.index(after: i) }
        var name = ""
        while i < html.endIndex {
            let ch = html[i]
            if ch.isLetter || ch.isNumber || ch == "-" { name.append(ch); i = html.index(after: i) }
            else { break }
        }
        return name.lowercased()
    }

    private static func balanced(_ html: String, from start: String.Index, name: String) -> String? {
        var i = start
        var depth = 0
        while i < html.endIndex {
            if html[i] != "<" {
                html.formIndex(after: &i)
                continue
            }
            if depth > 0, hasTag(html, i, "script") || hasTag(html, i, "style") {
                let closer = "</\(elementName(html, at: i))>"
                if let end = html.range(of: closer, options: .caseInsensitive, range: i..<html.endIndex) {
                    i = end.upperBound
                    continue
                }
            }
            if isOpen(html, i, name) {
                depth += 1
                i = skipTag(html, i)
                continue
            }
            if isClose(html, i, name) {
                depth -= 1
                let after = skipTag(html, i)
                if depth == 0 { return String(html[start..<after]) }
                i = after
                continue
            }
            html.formIndex(after: &i)
        }
        return nil
    }

    private static func hasTag(_ html: String, _ i: String.Index, _ name: String) -> Bool {
        isOpen(html, i, name)
    }

    /// Compare a short prefix only. Lowercasing the whole tail is quadratic on a 4MB page.
    private static func hasPrefixCI(_ html: String, _ i: String.Index, _ literal: String) -> Bool {
        let end = html.index(i, offsetBy: literal.count, limitedBy: html.endIndex) ?? html.endIndex
        guard html.distance(from: i, to: end) == literal.count else { return false }
        return html[i..<end].lowercased() == literal
    }

    private static func isOpen(_ html: String, _ i: String.Index, _ name: String) -> Bool {
        guard hasPrefixCI(html, i, "<\(name)") else { return false }
        let next = html.index(i, offsetBy: name.count + 1, limitedBy: html.endIndex) ?? html.endIndex
        guard next < html.endIndex else { return true }
        let ch = html[next]
        return ch == ">" || ch == "/" || ch.isWhitespace
    }

    private static func isClose(_ html: String, _ i: String.Index, _ name: String) -> Bool {
        hasPrefixCI(html, i, "</\(name)")
    }

    private static func skipTag(_ html: String, _ i: String.Index) -> String.Index {
        var j = i
        while j < html.endIndex {
            if html[j] == ">" { return html.index(after: j) }
            html.formIndex(after: &j)
        }
        return html.endIndex
    }

    // MARK: - cleanup

    static func promoteLazyImages(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += promoteTag(ns.substring(with: m.range))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    private static func promoteTag(_ tag: String) -> String {
        let real = firstHTTP(tag, ["data-src", "data-original", "data-lazy-src", "data-actualsrc"])
        guard let real else { return tag }
        let src = attr(tag, "src") ?? ""
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return tag }
        let quoted = htmlQuoted(real)
        if let re = attributeRegex("src"),
           re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) != nil {
            return re.stringByReplacingMatches(
                in: tag,
                range: NSRange(location: 0, length: (tag as NSString).length),
                withTemplate: "src=\"\(quoted)\""
            )
        }
        return tag.replacingOccurrences(of: "<img", with: "<img src=\"\(quoted)\"", options: .caseInsensitive)
    }

    private static func htmlQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func firstHTTP(_ tag: String, _ names: [String]) -> String? {
        for name in names {
            guard var raw = attr(tag, name) else { continue }
            raw = unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("//") { raw = "https:" + raw }
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        }
        return nil
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let re = attributeRegex(name, capture: true) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// WeChat hides `#js_content` until its own script runs. The reader has no such script.
    static func revealRoot(_ html: String) -> String {
        guard let gt = html.firstIndex(of: ">") else { return html }
        var head = String(html[..<html.index(after: gt)])
        for piece in ["visibility: hidden;", "visibility:hidden;", "opacity: 0;", "opacity:0;"] {
            head = head.replacingOccurrences(of: piece, with: "", options: .caseInsensitive)
        }
        return head + html[html.index(after: gt)...]
    }

    static func plainText(_ html: String) -> String {
        var s = html
        if let re = try? NSRegularExpression(pattern: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        if let re = try? NSRegularExpression(pattern: #"(?s)<[^>]+>"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        s = unescape(s)
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func metaContent(_ html: String, property: String) -> String? {
        let patterns = [
            #"(?i)<meta[^>]*property=""# + property + #""[^>]*content="([^"]*)""#,
            #"(?i)<meta[^>]*content="([^"]*)"[^>]*property=""# + property + #"""#,
        ]
        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = html as NSString
            guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1 else { continue }
            let value = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func innerTextOfId(_ html: String, id: String) -> String? {
        guard let sliced = sliceElement(html, id: id) else { return nil }
        let text = plainText(sliced)
        return text.isEmpty ? nil : text
    }
}
