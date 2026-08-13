import Foundation
import AppKit
import WebKit

/// Long-term URL archive plane: **manual**, **browser-engine** (WKWebView / WebKit),
/// **useful-first** (Mozilla Readability). Not CORS fetch. Not auto-crawl.
///
/// Taste: save useful. Readable article is the product; snapshot/PDF can share this job queue later.
final class WebArchiveService: NSObject, WKNavigationDelegate {
    struct Job {
        var id: String
        var url: String
        var itemId: String?
        var status: String // queued | running | ok | error
        var title: String?
        var error: String?
        var bytes: Int?
        var createdAt: TimeInterval
        var updatedAt: TimeInterval

        func json() -> [String: Any] {
            var d: [String: Any] = [
                "jobId": id,
                "url": url,
                "status": status,
                "createdAt": createdAt,
                "updatedAt": updatedAt,
            ]
            if let itemId { d["itemId"] = itemId }
            if let title { d["title"] = title }
            if let error { d["error"] = error }
            if let bytes { d["bytes"] = bytes }
            return d
        }
    }

    static let maxHTMLBytes = 2_500_000
    static let navigationTimeout: TimeInterval = 22
    static let settleAfterLoad: TimeInterval = 0.9

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var busy = false

    private var session: Session?
    weak var database: DatabaseManager?
    var onFinished: ((String?, String, String?) -> Void)? // itemId, jobId, error

    // MARK: - Public

    func enqueue(url: URL, itemId: UUID?) -> (Job?, String?) {
        if let reason = ArchiveURLPolicy.denyReason(url) {
            return (nil, reason)
        }
        let now = Date().timeIntervalSince1970
        var job = Job(
            id: UUID().uuidString.lowercased(),
            url: url.absoluteString,
            itemId: itemId?.uuidString,
            status: "queued",
            title: nil,
            error: nil,
            bytes: nil,
            createdAt: now,
            updatedAt: now
        )
        lock.lock()
        jobs[job.id] = job
        queue.append(job.id)
        lock.unlock()
        print("[Archive] queued \(job.id) \(url.host ?? "")")
        kick()
        return (job, nil)
    }

    func job(id: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    // MARK: - Queue

    private func kick() {
        DispatchQueue.main.async { [weak self] in
            self?.startNextIfIdle()
        }
    }

    private func startNextIfIdle() {
        lock.lock()
        if busy {
            lock.unlock()
            return
        }
        guard let nextId = queue.first else {
            lock.unlock()
            return
        }
        queue.removeFirst()
        busy = true
        var job = jobs[nextId]
        job?.status = "running"
        job?.updatedAt = Date().timeIntervalSince1970
        if let job { jobs[nextId] = job }
        lock.unlock()
        guard let job else {
            lock.lock(); busy = false; lock.unlock()
            kick()
            return
        }
        guard let url = URL(string: job.url) else {
            finish(jobId: job.id, error: "无效 URL", title: nil, html: nil, text: nil)
            return
        }
        session = Session(owner: self, job: job, url: url)
        session?.start()
    }

    fileprivate func finish(jobId: String, error: String?, title: String?, html: String?, text: String?) {
        session?.teardown()
        session = nil

        lock.lock()
        var job = jobs[jobId]
        job?.updatedAt = Date().timeIntervalSince1970
        if let error {
            job?.status = "error"
            job?.error = error
        } else {
            job?.status = "ok"
            job?.title = title
            job?.bytes = html?.utf8.count
            job?.error = nil
        }
        if let job { jobs[jobId] = job }
        let itemId = job?.itemId
        let urlStr = job?.url ?? ""
        busy = false
        lock.unlock()

        print("[Archive] done \(jobId) status=\(error == nil ? "ok" : "error") \(error ?? "")")
        if error == nil, let html, let itemId, let uuid = UUID(uuidString: itemId) {
            persist(itemId: uuid, url: urlStr, title: title ?? "", html: html, text: text ?? "") { [weak self] in
                self?.onFinished?(itemId, jobId, error)
                self?.kick()
            }
        } else {
            onFinished?(itemId, jobId, error)
            kick()
        }
    }

    private func persist(
        itemId: UUID,
        url: String,
        title: String,
        html: String,
        text: String,
        done: @escaping () -> Void
    ) {
        guard let database else {
            done()
            return
        }
        let meta: [String: Any] = [
            "sourceUrl": url,
            "title": title,
            "mode": "readable",
            "archivedAt": ClipTimeFormat.isoLocal(Date()),
            "bytes": html.utf8.count,
            "engine": "webkit+readability",
        ]
        let metaData = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data()
        let metaStr = String(data: metaData, encoding: .utf8) ?? "{}"
        database.applyWebArchive(
            id: itemId,
            html: html,
            textSnippet: text,
            title: title,
            metaJSON: metaStr
        ) { _ in
            done()
        }
    }

    // MARK: - Session (main-thread WKWebView)

    fileprivate final class Session: NSObject, WKNavigationDelegate {
        weak var owner: WebArchiveService?
        let job: Job
        let url: URL
        var webView: WKWebView?
        var window: NSWindow?
        var timeoutWork: DispatchWorkItem?
        var finished = false

        init(owner: WebArchiveService, job: Job, url: URL) {
            self.owner = owner
            self.job = job
            self.url = url
        }

        func start() {
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            cfg.suppressesIncrementalRendering = false
            if #available(macOS 11.0, *) {
                cfg.defaultWebpagePreferences.allowsContentJavaScript = true
            }
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
            wv.customUserAgent =
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 ClipVaultArchive/1.0"
            wv.navigationDelegate = self
            let win = NSWindow(
                contentRect: NSRect(x: -4800, y: -4800, width: 1280, height: 900),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            win.isOpaque = false
            win.backgroundColor = .clear
            win.contentView = wv
            win.orderBack(nil)
            self.webView = wv
            self.window = win
            wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))

            let work = DispatchWorkItem { [weak self] in
                self?.fail("归档超时（页面过慢或需登录）")
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + WebArchiveService.navigationTimeout, execute: work)
        }

        func teardown() {
            timeoutWork?.cancel()
            timeoutWork = nil
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
            window?.contentView = nil
            window?.close()
            window = nil
        }

        private func fail(_ message: String) {
            guard !finished else { return }
            finished = true
            timeoutWork?.cancel()
            owner?.finish(jobId: job.id, error: message, title: nil, html: nil, text: nil)
        }

        private func succeed(title: String, html: String, text: String) {
            guard !finished else { return }
            finished = true
            timeoutWork?.cancel()
            owner?.finish(jobId: job.id, error: nil, title: title, html: html, text: text)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail("加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail("无法打开：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + WebArchiveService.settleAfterLoad) { [weak self] in
                self?.extract()
            }
        }

        private func extract() {
            guard let webView else {
                fail("WebView 已释放")
                return
            }
            let js = Self.extractorJavaScript()
            webView.evaluateJavaScript(js) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    self.fail("抽取失败：\(error.localizedDescription)")
                    return
                }
                guard let raw = result as? String,
                      let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.fail("抽取结果无法解析")
                    return
                }
                if let ok = obj["ok"] as? Bool, ok == false {
                    self.fail((obj["reason"] as? String) ?? "无法抽取正文（登录墙或非文章页）")
                    return
                }
                let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let html = (obj["html"] as? String) ?? ""
                let text = (obj["text"] as? String) ?? ""
                if html.utf8.count < 80 && text.count < 40 {
                    self.fail("正文过短，可能是登录墙或空页")
                    return
                }
                if html.utf8.count > WebArchiveService.maxHTMLBytes {
                    self.fail("归档过大（>\(WebArchiveService.maxHTMLBytes / 1_000_000)MB）")
                    return
                }
                self.succeed(title: title, html: html, text: text)
            }
        }

        private static func extractorJavaScript() -> String {
            let lib = WebArchiveService.loadReadabilityJS()
            let runner = """
            (function(){
              try {
                if (typeof Readability !== 'function') {
                  return JSON.stringify({ok:false, reason:'Readability 未注入'});
                }
                var clone = document.cloneNode(true);
                var article = new Readability(clone).parse();
                if (!article || !article.content) {
                  return JSON.stringify({ok:false, reason:'Readability 无正文'});
                }
                var text = (article.textContent || '').replace(/\\s+/g,' ').trim();
                if (text.length < 40) {
                  return JSON.stringify({ok:false, reason:'正文过短'});
                }
                return JSON.stringify({
                  ok: true,
                  title: article.title || document.title || '',
                  byline: article.byline || '',
                  excerpt: article.excerpt || '',
                  siteName: article.siteName || '',
                  text: text.slice(0, 20000),
                  html: article.content
                });
              } catch (e) {
                return JSON.stringify({ok:false, reason: String(e && e.message ? e.message : e)});
              }
            })()
            """
            return lib + "\n" + runner
        }
    }

    static func loadReadabilityJS() -> String {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8), s.count > 1000 {
            return s
        }
        #endif
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            exe.deletingLastPathComponent().appendingPathComponent("Readability.js"),
            exe.deletingLastPathComponent().appendingPathComponent("Resources/Readability.js"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("ClipFlow/Resources/Readability.js"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Readability.js"),
        ]
        for u in candidates {
            if let s = try? String(contentsOf: u, encoding: .utf8), s.count > 1000 { return s }
        }
        return "function Readability(){ throw new Error('Readability.js missing'); }"
    }
}

enum ArchiveURLPolicy {
    static func denyReason(_ url: URL) -> String? {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return "仅支持 http(s) 网址" }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "无效主机" }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1"
            || host == "0.0.0.0" || host == "::1" || host == "[::1]" {
            return "禁止归档本机地址"
        }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") {
            return "禁止归档内网主机"
        }
        if isPrivateOrLinkLocalIP(host) {
            return "禁止归档内网 / 链路本地 IP（防 SSRF）"
        }
        return nil
    }

    private static func isPrivateOrLinkLocalIP(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0], b = parts[1]
        if a == 10 { return true }
        if a == 127 { return true }
        if a == 192 && b == 168 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        return false
    }
}
