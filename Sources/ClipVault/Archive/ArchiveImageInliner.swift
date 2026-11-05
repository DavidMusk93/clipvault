import Foundation
import CryptoKit
import Network

/// Pull remote `<img>` bytes into CAS and rewrite src to `/api/archive/asset?sha=`.
/// View documents must not hit publisher CDNs.
enum ArchiveImageInliner {
    static let assetPrefix = "/api/archive/asset?sha="
    static let maxBytes = 8_000_000
    static let maxImages = 48

    static func containsRemoteImages(_ html: String) -> Bool {
        html.range(of: #"<img\b[^>]*(src|data-src|data-original|data-lazy-src|data-actualsrc)\s*=\s*"(https?:|//)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func embed(html: String, pageURL: URL?, writeBlob: @escaping (String, Data) -> Bool) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return repairDoubledAssetQuotes(html) }

        var tags: [(NSRange, String, URL?)] = []
        var unique: [URL] = []
        var seen = Set<String>()
        for m in matches {
            let tag = ns.substring(with: m.range)
            let url = remoteImageURL(in: tag)
            tags.append((m.range, tag, url))
            if let url {
                let key = url.absoluteString
                if !seen.contains(key), unique.count < maxImages {
                    seen.insert(key)
                    unique.append(url)
                }
            }
        }
        guard !unique.isEmpty else { return repairDoubledAssetQuotes(html) }

        let fetched = fetchAll(unique, referer: pageURL, writeBlob: writeBlob)
        guard !fetched.isEmpty else { return repairDoubledAssetQuotes(html) }

        var out = ""
        var cursor = 0
        for (range, tag, url) in tags {
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            if let url, let sha = fetched[url.absoluteString] {
                out += rewriteTag(tag, sha: sha)
            } else {
                out += tag
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return repairDoubledAssetQuotes(flattenPictures(out))
    }

    /// Older rewrites matched `src="…` without the closing quote and left `""`.
    static func repairDoubledAssetQuotes(_ html: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "(/api/archive/asset\\?sha=[0-9a-f]{64})\"\""
        ) else { return html }
        return re.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length),
            withTemplate: "$1\""
        )
    }

    /// Medium wraps figures in `<picture><source srcset="https://miro…">`.
    /// Browsers prefer source/srcset over `<img src>`, then CSP `img-src 'self'`
    /// blocks the CDN and the inlined CAS `src` never paints.
    static func flattenPictures(_ html: String) -> String {
        var s = html
        if let re = try? NSRegularExpression(pattern: #"<source\b[^>]*>"#, options: [.caseInsensitive]) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        if let re = try? NSRegularExpression(pattern: #"</?picture\b[^>]*>"#, options: [.caseInsensitive]) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)\s+(srcset|sizes)\s*=\s*"[^"]*""#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        return s
    }

    static func mimeType(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.count > 12, data[8..<12].elementsEqual(Array("WEBP".utf8)) { return "image/webp" }
        if data.starts(with: [0x3C, 0x73]) || data.starts(with: [0x3C, 0x3F]) { return "image/svg+xml" }
        return "application/octet-stream"
    }

    static func isAssetSHA(_ raw: String) -> Bool {
        raw.count == 64 && raw.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    // MARK: - private

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let re = WeixinArticleHTML.attributeRegex(name, capture: true) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func unescapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private static func remoteImageURL(in tag: String) -> URL? {
        let keys = ["src", "data-src", "data-original", "data-lazy-src", "data-actualsrc"]
        for key in keys {
            guard var raw = attr(tag, key) else { continue }
            raw = unescapeHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("//") { raw = "https:" + raw }
            guard raw.hasPrefix("http://") || raw.hasPrefix("https://") else { continue }
            if raw.contains("/api/archive/asset") { return nil }
            if raw.hasPrefix("data:") { continue }
            if let hash = raw.range(of: "#") { raw = String(raw[..<hash.lowerBound]) }
            return URL(string: raw)
        }
        return nil
    }

    private static func rewriteTag(_ tag: String, sha: String) -> String {
        let local = assetPrefix + sha
        var next = tag
        if let re = WeixinArticleHTML.attributeRegex("src") {
            let range = NSRange(location: 0, length: (next as NSString).length)
            if re.firstMatch(in: next, range: range) != nil {
                next = re.stringByReplacingMatches(in: next, range: range, withTemplate: "src=\"\(local)\"")
            } else {
                next = next.replacingOccurrences(of: "<img", with: "<img src=\"\(local)\"", options: .caseInsensitive)
            }
        }
        for name in ["data-src", "data-original", "data-lazy-src", "data-actualsrc"] {
            if let re = WeixinArticleHTML.attributeRegex(name) {
                let range = NSRange(location: 0, length: (next as NSString).length)
                next = re.stringByReplacingMatches(in: next, range: range, withTemplate: "")
            }
        }
        return next
    }

    private static func fetchAll(_ urls: [URL], referer: URL?, writeBlob: @escaping (String, Data) -> Bool) -> [String: String] {
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 4)
        let lock = NSLock()
        var map: [String: String] = [:]
        for url in urls {
            group.enter()
            gate.wait()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { gate.signal(); group.leave() }
                guard let data = fetch(url, referer: referer) else { return }
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard writeBlob(sha, data) else { return }
                lock.lock()
                map[url.absoluteString] = sha
                lock.unlock()
            }
        }
        // Two hops: SOCKS TLS can fail in a few seconds, then a direct GET
        // still has to finish (modernescpp PNG is ~240KB).
        _ = group.wait(timeout: .now() + 32)
        return map
    }

    /// miro.medium.com only loads through v2raya SOCKS :2080. qpic / weixin
    /// answer on the direct path and must not share that session.
    private static let directSession: URLSession = makeSession(socks: false)
    private static let socksSession: URLSession = makeSession(socks: true)

    private static func makeSession(socks: Bool) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 16
        if socks, #available(macOS 14.0, *), ArchiveProxy.localhostPortOpen(2080) {
            c.proxyConfigurations = [
                ProxyConfiguration(socksv5Proxy: NWEndpoint.hostPort(host: "127.0.0.1", port: 2080))
            ]
        }
        return URLSession(configuration: c)
    }

    /// SOCKS :2080 first for overseas CDNs (miro.medium.com). If that hop dies
    /// in the TLS handshake, try direct. modernescpp.com images are that case:
    /// SOCKS `SSL_ERROR_SYSCALL`, direct GET is a real PNG/JPEG. Leaving the
    /// publisher URL in the HTML makes View paint a broken image — CSP is
    /// `img-src 'self'`.
    private static func fetch(_ url: URL, referer: URL?) -> Data? {
        let socksUp = ArchiveProxy.localhostPortOpen(2080)
        let preferSocks = socksUp && !WeixinArticleHTML.prefersDirectHost(url.host)
        if let data = fetchOnce(url, referer: referer, socks: preferSocks) { return data }
        let otherIsSocks = !preferSocks && socksUp
        if preferSocks == otherIsSocks { return nil }
        print("[Archive] image \(preferSocks ? "SOCKS" : "direct") failed; retry \(otherIsSocks ? "SOCKS" : "direct") \(url.host ?? "")")
        return fetchOnce(url, referer: referer, socks: otherIsSocks)
    }

    private static func fetchOnce(_ url: URL, referer: URL?, socks: Bool) -> Data? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        if let referer {
            req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let session = socks ? socksSession : directSession
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        session.dataTask(with: req) { data, resp, _ in
            if let data,
               let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               data.count > 32,
               data.count <= maxBytes {
                let mime = http.mimeType ?? ""
                if mime.hasPrefix("image/") || mimeType(for: data).hasPrefix("image/") {
                    out = data
                }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 14)
        return out
    }
}
