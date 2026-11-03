import Foundation

@main
enum WeixinArticleHTMLTests {
    static func main() {
        var fails = 0
        func ok(_ name: String, _ cond: Bool) {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name)\n".utf8))
                fails += 1
            }
        }

        ok("article-url", WeixinArticleHTML.isArticleURL("https://mp.weixin.qq.com/s/7l4Kcmt4v7k1vEpLM_BYOg"))
        ok("not-home", !WeixinArticleHTML.isArticleURL("https://mp.weixin.qq.com/"))
        ok("direct-weixin", WeixinArticleHTML.prefersDirectHost("mp.weixin.qq.com"))
        ok("direct-qpic", WeixinArticleHTML.prefersDirectHost("mmbiz.qpic.cn"))
        ok("socks-medium", !WeixinArticleHTML.prefersDirectHost("miro.medium.com"))
        ok("socks-x", !WeixinArticleHTML.prefersDirectHost("x.com"))

        let fixture = """
        <html><head>
        <meta property="og:title" content="Peer Read 提速">
        </head><body>
        <h1 id="activity-name">ignored when og exists</h1>
        <div id="js_content" style="visibility: hidden; opacity: 0; ">
          <p>存算分离架构下，计算组间缓存无法共享，冷查询延迟高，扩缩容之后性能也会抖动。即将发布的版本要解决缓存孤岛。</p>
          <div><img src="data:image/svg+xml,%3Csvg%3E" data-src="https://mmbiz.qpic.cn/a.png"></div>
          <img data-src="https://mmbiz.qpic.cn/only.png?from=appmsg&amp;wx_co=1" class="rich_pages">
          <script>var x = "<div>not a real div</div>";</script>
        </div>
        <div id="after">尾部导航，不应进入正文</div>
        </body></html>
        """
        guard let art = WeixinArticleHTML.extract(html: fixture) else {
            FileHandle.standardError.write(Data("FAIL extract nil\n".utf8))
            exit(1)
        }
        ok("title", art.title == "Peer Read 提速")
        ok("body", art.text.contains("缓存无法共享"))
        ok("no-tail", !art.html.contains("尾部导航"))
        ok("revealed", !art.html.contains("visibility: hidden"))
        ok("promoted", hasRealSrc(art.html, "https://mmbiz.qpic.cn/a.png"))
        ok("promoted-lazy-only", hasRealSrc(art.html, "https://mmbiz.qpic.cn/only.png?from=appmsg&amp;wx_co=1"))
        ok("lazy-only-not-data-src", art.html.contains("<img src=\"https://mmbiz.qpic.cn/only.png?from=appmsg&amp;wx_co=1\""))
        ok("no-svg-src", !art.html.contains("data:image/svg"))
        ok("script-not-text", !art.text.contains("not a real div"))

        let live = "/tmp/wx.html"
        if FileManager.default.fileExists(atPath: live),
           let page = try? String(contentsOfFile: live, encoding: .utf8),
           page.contains("7l4Kcmt4v7k1vEpLM_BYOg") || page.contains("js_content"),
           let got = WeixinArticleHTML.extract(html: page) {
            ok("live-title", got.title.contains("Peer Read"))
            ok("live-bytes", got.html.utf8.count > 10_000 && got.html.utf8.count < 2_500_000)
            ok("live-img", got.html.contains("mmbiz.qpic.cn"))
            ok("live-real-src", realSrcCount(got.html, "https://mmbiz.qpic.cn") >= 10)
            ok("live-visible", !got.html.contains("visibility: hidden"))
            ok("live-text", got.text.contains("缓存"))
            print("live bytes=\(got.html.utf8.count) text=\(got.text.count)")
        }

        if fails > 0 {
            FileHandle.standardError.write(Data("\(fails) failed\n".utf8))
            exit(1)
        }
    }

    /// True when `url` is the value of a `src` attribute, not `data-src`.
    static func hasRealSrc(_ html: String, _ url: String) -> Bool {
        realSrcCount(html, url) > 0
    }

    static func realSrcCount(_ html: String, _ urlPrefix: String) -> Int {
        let pat = #"(?i)(?<![A-Za-z0-9_-])src\s*=\s*""# + NSRegularExpression.escapedPattern(for: urlPrefix)
        guard let re = try? NSRegularExpression(pattern: pat) else { return 0 }
        return re.numberOfMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
    }
}
