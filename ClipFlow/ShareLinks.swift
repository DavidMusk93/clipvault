import Foundation
import CryptoKit
import Security

/// Capability-token shares: owner mints/revokes; holder of the URL can read one item.
/// Not synced (token lives on the machine behind the tunnel). Capture payload unchanged.
enum ShareLinks {
    struct Record {
        var token: String
        var itemId: String
        var kind: String
        var createdAt: Double
        var snapshotTitle: String
        var snapshotBody: String
        var snapshotType: String
        var archiveSha: String?
        var blobKeys: [String]
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data: Data
        if status == errSecSuccess {
            data = Data(bytes)
        } else {
            data = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isToken(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 32, t.count <= 64 else { return false }
        return t.unicodeScalars.allSatisfy { ch in
            (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
            || (ch >= "0" && ch <= "9") || ch == "-" || ch == "_"
        }
    }

    static func rewriteAssets(_ html: String, token: String) -> String {
        let t = token
        var s = html
        s = s.replacingOccurrences(of: "/api/archive/asset?sha=", with: "/api/share/asset?t=\(t)&sha=")
        s = s.replacingOccurrences(of: "/api/image?sha=", with: "/api/share/asset?t=\(t)&sha=")
        return s
    }

    static func allowsAsset(_ rec: Record, sha: String) -> Bool {
        rec.blobKeys.contains(sha)
    }

    static func pageHTML(_ rec: Record, archiveHTML: String?) -> String {
        let title = htmlEscape(rec.snapshotTitle.isEmpty ? "分享" : rec.snapshotTitle)
        switch rec.kind {
        case "archive":
            let body = rewriteAssets(archiveHTML ?? rec.snapshotBody, token: rec.token)
            return wrap(
                title: title,
                kindLabel: "归档",
                inner: "<main class=\"cv-article share-article\">\(body)</main>",
                extraHead: "<link rel=\"stylesheet\" href=\"/assets/archive-view.css?v=20260905a\"/>",
                scripts: false
            )
        case "note":
            let raw = rec.snapshotBody
            let escaped = jsonEscape(raw)
            return wrap(
                title: title,
                kindLabel: "笔记",
                inner: """
                <article class="share-note">
                  <h1>\(title)</h1>
                  <div id="md" class="share-md"></div>
                </article>
                <script src="https://cdn.jsdelivr.net/npm/marked@9.1.6/marked.min.js"></script>
                <script src="https://cdn.jsdelivr.net/npm/dompurify@3.1.6/dist/purify.min.js"></script>
                <script>
                (function(){
                  var src = "\(escaped)";
                  src = src.replace(/\\/api\\/(?:image|archive\\/asset)\\?sha=/g, "/api/share/asset?t=\(rec.token)&sha=");
                  var html = "";
                  try {
                    if (window.marked && marked.parse) html = marked.parse(src, {async:false, gfm:true, breaks:true});
                  } catch (e) {}
                  if (window.DOMPurify) html = DOMPurify.sanitize(html || "", {USE_PROFILES:{html:true}, FORBID_TAGS:["script","iframe","object","form"]});
                  document.getElementById("md").innerHTML = html || "<pre></pre>";
                })();
                </script>
                """,
                extraHead: "",
                scripts: true
            )
        default:
            let body = htmlEscape(rec.snapshotBody)
            let img: String
            if rec.snapshotType == "image" {
                img = "<p><img class=\"share-img\" src=\"/api/share/asset?t=\(htmlEscape(rec.token))&src=image\" alt=\"\"/></p>"
            } else {
                img = ""
            }
            return wrap(
                title: title,
                kindLabel: "卡片",
                inner: """
                <article class="share-card">
                  <p class="share-kicker">\(htmlEscape(rec.snapshotType.isEmpty ? "text" : rec.snapshotType))</p>
                  <h1>\(title)</h1>
                  \(img)
                  <pre class="share-body">\(body)</pre>
                </article>
                """,
                extraHead: "",
                scripts: false
            )
        }
    }

    static func goneHTML() -> String {
        wrap(title: "链接已失效", kindLabel: "", inner: "<article class=\"share-card\"><h1>链接已失效</h1><p>分享已取消，或从未存在。</p></article>", extraHead: "", scripts: false)
    }

    private static func wrap(title: String, kindLabel: String, inner: String, extraHead: String, scripts: Bool) -> String {
        let kicker = kindLabel.isEmpty ? "" : "<p class=\"share-brand\">ClipVault · \(htmlEscape(kindLabel))</p>"
        let scriptCsp = scripts
            ? "script-src 'unsafe-inline' https://cdn.jsdelivr.net; connect-src 'none'"
            : "script-src 'none'"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width,initial-scale=1"/>
          <title>\(title)</title>
          <meta name="robots" content="noindex,nofollow"/>
          <meta name="referrer" content="no-referrer"/>
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline' 'self'; font-src 'self'; \(scriptCsp); base-uri 'none'; form-action 'none'"/>
          \(extraHead)
          <style>
            body{margin:0;background:#f5f5f7;color:#1d1d1f;font:17px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif}
            .share-brand{margin:0;padding:18px 22px 0;font-size:12px;letter-spacing:.04em;color:#6e6e73}
            .share-card,.share-note{max-width:40rem;margin:0 auto;padding:12px 22px 64px}
            .share-kicker{font-size:12px;color:#6e6e73;margin:8px 0 0}
            h1{font-size:1.6rem;letter-spacing:-.03em;margin:.4rem 0 1rem}
            .share-body{white-space:pre-wrap;word-break:break-word;font:14.5px/1.55 ui-monospace,Menlo,monospace;background:#fff;border-radius:14px;padding:16px;border:.5px solid rgba(60,60,67,.12)}
            .share-img{max-width:100%;height:auto;border-radius:14px}
            .share-md{background:#fff;border-radius:16px;padding:22px 24px 40px;border:.5px solid rgba(60,60,67,.12)}
            .share-md pre{overflow:auto;background:#f5f5f7;padding:12px;border-radius:10px}
            .share-md img{max-width:100%;height:auto}
          </style>
        </head>
        <body>
        \(kicker)
        \(inner)
        </body>
        </html>
        """
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            case 0x0a: out += "\\n"
            case 0x0d: out += "\\r"
            case 0x09: out += "\\t"
            case 0x3c: out += "\\u003c"
            case 0x3e: out += "\\u003e"
            case 0..<0x20: out += String(format: "\\u%04x", ch.value)
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
