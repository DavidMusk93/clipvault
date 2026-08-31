import Foundation
import AppKit
import WebKit
import CryptoKit
import Network

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
    /// Medium/CF often exceeds 20s on a clean WKWebView (no Safari cookies).
    static let navigationTimeout: TimeInterval = 48
    static let requestTimeout: TimeInterval = 45
    static let settleAfterLoad: TimeInterval = 1.6
    static let hydratePolls = 16
    static let hydratePollInterval: TimeInterval = 0.45

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var busy = false

    private var session: Session?
    weak var database: DatabaseManager?
    var onFinished: ((String?, String, String?) -> Void)? // itemId, jobId, error

    // MARK: - Public

    func enqueue(url: URL, itemId: UUID?) -> (Job?, String?) {
        let url = ArchiveURLPolicy.canonicalize(url)
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
        // X Articles: Draft.js MARKDOWN/headings are not in the logged-out DOM.
        // Prefer the article payload over WKWebView+Readability <p> soup.
        if XArticleHTML.isXURL(job.url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                if let fetched = XArticleHTML.fetchArticle(url: job.url),
                   let html = XArticleHTML.render(article: fetched.article),
                   html.lowercased().contains("<pre") || html.lowercased().contains("<h2") {
                    print("[Archive] x-article fast-path \(job.url) bytes=\(html.utf8.count)")
                    DispatchQueue.main.async {
                        self.finish(
                            jobId: job.id,
                            error: nil,
                            title: fetched.title.isEmpty ? nil : fetched.title,
                            html: html,
                            text: fetched.title
                        )
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.session = Session(owner: self, job: job, url: url)
                    self.session?.start()
                }
            }
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
        guard database != nil else {
            done()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let database = self.database else {
                done()
                return
            }
            var articleHTML = html
            var articleTitle = title
            var engine = "webkit+readability"
            if let enriched = XArticleHTML.enrich(url: url, html: html, title: title) {
                articleHTML = enriched.html
                articleTitle = enriched.title
                engine = enriched.engine
                print("[Archive] x-article enrich \(url) bytes=\(articleHTML.utf8.count)")
            }
            let localHTML = ArchiveImageInliner.embed(
                html: articleHTML,
                pageURL: URL(string: url),
                writeBlob: { hash, data in database.writeBlobFile(hash: hash, data: data) }
            )
            let sha = SHA256.hash(data: Data(localHTML.utf8)).map { String(format: "%02x", $0) }.joined()
            var meta: [String: Any] = [
                "sourceUrl": url,
                "title": articleTitle,
                "mode": "readable",
                "archivedAt": ClipTimeFormat.isoLocal(Date()),
                "bytes": localHTML.utf8.count,
                "engine": engine,
            ]
            let keys = ArchiveBlobClosure.stamp(&meta, root: sha, html: localHTML)
            let metaStr = ArchiveBlobClosure.encodeMeta(meta)
            database.applyWebArchive(
                id: itemId,
                html: localHTML,
                textSnippet: text,
                title: articleTitle,
                metaJSON: metaStr
            ) { ok in
                if ok {
                    CloudDocsSyncService.shared?.recordLocalArchive(
                        itemId: itemId,
                        htmlSHA: sha,
                        metaJSON: metaStr,
                        blobKeys: keys
                    )
                }
                done()
            }
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
        var loadAttempt = 0
        var usingSocksProxy = false

        init(owner: WebArchiveService, job: Job, url: URL) {
            self.owner = owner
            self.job = job
            self.url = url
        }

        func start() {
            ClipboardMonitor.shared?.suppressCapture(for: WebArchiveService.navigationTimeout + 8)
            // System HTTP/SOCKS proxy is often off; the browser still uses v2raya :2080.
            // Prefer that SOCKS when it is listening so Medium is not a 45s direct timeout.
            let socks = ArchiveProxy.localhostPortOpen(2080)
            attachWebView(socksProxy: socks)
            armTimeout()
            startLoad()
        }

        /// Safari can be on v2raya SOCKS while system HTTP/SOCKS proxy is off.
        /// WKWebView then goes direct and Medium times out. macOS 14+ can attach
        /// SOCKS to this data store only (not the user's browser).
        private func attachWebView(socksProxy: Bool) {
            usingSocksProxy = socksProxy
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            let cfg = WKWebViewConfiguration()
            let store = WKWebsiteDataStore.nonPersistent()
            if socksProxy {
                if #available(macOS 14.0, *) {
                    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 2080)
                    store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
                    print("[Archive] WKWebView SOCKS 127.0.0.1:2080")
                } else {
                    print("[Archive] SOCKS retry skipped: need macOS 14+ proxyConfigurations")
                }
            }
            cfg.websiteDataStore = store
            cfg.suppressesIncrementalRendering = false
            if #available(macOS 11.0, *) {
                cfg.defaultWebpagePreferences.allowsContentJavaScript = true
            }
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
            wv.customUserAgent =
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
            wv.navigationDelegate = self
            if window == nil {
                let win = NSWindow(
                    contentRect: NSRect(x: -4800, y: -4800, width: 1280, height: 900),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                win.isReleasedWhenClosed = false
                win.isOpaque = false
                win.backgroundColor = .clear
                win.orderBack(nil)
                window = win
            }
            window?.contentView = wv
            webView = wv
        }

        private func armTimeout() {
            timeoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.fail("归档超时（页面过慢或需登录）")
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + WebArchiveService.navigationTimeout, execute: work)
        }

        private func startLoad() {
            loadAttempt += 1
            let req = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: WebArchiveService.requestTimeout
            )
            webView?.load(req)
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
            ClipboardMonitor.shared?.absorbPasteboardNow()
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
            handleLoadFailure(error, provisional: false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error, provisional: true)
        }

        private func handleLoadFailure(_ error: Error, provisional: Bool) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            let timedOut = ns.domain == NSURLErrorDomain && (
                ns.code == NSURLErrorTimedOut || ns.code == NSURLErrorCannotConnectToHost
                    || ns.code == NSURLErrorNetworkConnectionLost
            )
            if timedOut && !usingSocksProxy {
                print("[Archive] direct failed (\(ns.code)); retry via SOCKS 2080 \(url.host ?? "")")
                attachWebView(socksProxy: true)
                loadAttempt = 0
                armTimeout()
                startLoad()
                return
            }
            if timedOut && usingSocksProxy && loadAttempt < 2 {
                print("[Archive] SOCKS timeout retry \(url.host ?? "") attempt=\(loadAttempt)")
                armTimeout()
                startLoad()
                return
            }
            let prefix = provisional ? "无法打开" : "加载失败"
            let hint = usingSocksProxy ? "" : "（浏览器能打开、归档不能：系统代理未开，归档走直连）"
            fail("\(prefix)：\(error.localizedDescription)\(hint)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + WebArchiveService.settleAfterLoad) { [weak self] in
                self?.waitForArticleThenExtract(attempt: 0)
            }
        }

        /// Medium is a JS shell: didFinish fires before story text exists.
        private func waitForArticleThenExtract(attempt: Int) {
            guard !finished else { return }
            guard let webView else {
                fail("WebView 已释放")
                return
            }
            let probe = """
            (function(){
              var root = document.querySelector('article,[data-testid="storyContent"],.postArticle-content,main') || document.body;
              var t = (root && (root.innerText || root.textContent) || '').replace(/\\s+/g,' ').trim();
              return t.length;
            })()
            """
            webView.evaluateJavaScript(probe) { [weak self] result, _ in
                guard let self, !self.finished else { return }
                let n = (result as? Int) ?? (result as? Double).map { Int($0) } ?? 0
                if n < 400 && attempt < WebArchiveService.hydratePolls {
                    DispatchQueue.main.asyncAfter(deadline: .now() + WebArchiveService.hydratePollInterval) {
                        self.waitForArticleThenExtract(attempt: attempt + 1)
                    }
                    return
                }
                self.extract()
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
                var live = document.querySelectorAll('img');
                for (var i = 0; i < live.length; i++) {
                  var im = live[i];
                  var real = im.getAttribute('data-src') || im.getAttribute('data-original') || im.getAttribute('data-lazy-src') || im.getAttribute('data-actualsrc');
                  if (!real) continue;
                  if (real.indexOf('//') === 0) real = (location.protocol || 'https:') + real;
                  if (!/^https?:/i.test(real)) continue;
                  var src = im.getAttribute('src') || '';
                  if (!src || src.indexOf('data:image') === 0) im.setAttribute('src', real);
                }
                var clone = document.cloneNode(true);
                // Invalid <figcaption> next to <img> (not in <figure>) is common in
                // technical blogs. Readability then drops the parent <ul> because
                // img>1 && each <li> has >1 element child. Wrap first so diagram
                // lists survive (swap-expand-entry / swap-full-hash-overflow).
                (function repairOrphanFigures(doc) {
                  var caps = doc.querySelectorAll('figcaption');
                  for (var i = 0; i < caps.length; i++) {
                    var cap = caps[i];
                    if (cap.closest('figure')) continue;
                    var img = cap.previousElementSibling;
                    if (!img || String(img.tagName || '').toUpperCase() !== 'IMG') {
                      img = null;
                      var parent = cap.parentNode;
                      var kids = parent ? parent.children : [];
                      for (var s = 0; s < kids.length; s++) {
                        if (kids[s] === cap) break;
                        if (String(kids[s].tagName || '').toUpperCase() === 'IMG') img = kids[s];
                      }
                    }
                    if (!img) continue;
                    var fig = doc.createElement('figure');
                    img.parentNode.insertBefore(fig, img);
                    fig.appendChild(img);
                    fig.appendChild(cap);
                  }
                })(clone);
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

enum ArchiveProxy {
    /// Fast TCP probe so we do not wait 45s on a black-holed direct path.
    static func localhostPortOpen(_ port: UInt16) -> Bool {
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
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        _ = sem.wait(timeout: .now() + 0.25)
        conn.cancel()
        return ok
    }
}

enum ArchiveURLPolicy {
    /// Drop OAuth/JWT fragments (Medium `#id_token=`) so WKWebView fetches the article, not a login hash.
    static func canonicalize(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        let drop = Set(["id_token", "access_token", "refresh_token", "code", "state"])
        if let items = c?.queryItems, !items.isEmpty {
            let kept = items.filter { !drop.contains($0.name.lowercased()) }
            c?.queryItems = kept.isEmpty ? nil : kept
        }
        return c?.url ?? url
    }

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
