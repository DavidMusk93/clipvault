import Foundation

@main
enum XArticleHTMLTests {
    static func main() {
        var fails = 0
        func eq(_ name: String, _ got: String, _ want: String) {
            if got != want {
                FileHandle.standardError.write(Data(
                    "FAIL \(name)\n  want: \(want.debugDescription)\n   got: \(got.debugDescription)\n".utf8
                ))
                fails += 1
            } else {
                print("OK \(name)")
            }
        }
        func ok(_ name: String, _ cond: Bool) {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name)\n".utf8))
                fails += 1
            }
        }

        ok("status-id", XArticleHTML.statusID(from: "https://x.com/ewind_dev/status/2092955281714209193") == "2092955281714209193")
        ok("is-x", XArticleHTML.isXURL("https://x.com/i/article/1"))
        ok("flattened", XArticleHTML.looksFlattened("<div><p>hello</p><p>world</p></div>"))
        ok("not-flat-pre", !XArticleHTML.looksFlattened("<pre><code>x</code></pre>"))

        let fence = XArticleHTML.renderFence("```ts\nconst g = prog()\n```")
        ok("fence-pre", fence.contains("<pre><code class=\"language-ts\">"))
        ok("fence-body", fence.contains("const g = prog()"))
        ok("fence-escape", XArticleHTML.renderFence("```\na < b\n```").contains("a &lt; b"))

        let blocks: [[String: Any]] = [
            ["type": "header-two", "text": "从 TestClock 看 Effect 的能力"],
            ["type": "unstyled", "text": "社区常见的回答", "inlineStyleRanges": [["offset": 0, "length": 2, "style": "Bold"]]],
            ["type": "blockquote", "text": "框架必须掌握每一个异步续延的调度权。"],
            ["type": "unordered-list-item", "text": "从 DST 理解虚拟时间"],
            ["type": "unordered-list-item", "text": "从续延归属解释 yield*"],
            [
                "type": "atomic",
                "text": " ",
                "entityRanges": [["key": 0, "length": 1, "offset": 0]],
            ],
        ]
        let map: [[String: Any]] = [
            [
                "key": 0,
                "value": [
                    "type": "MARKDOWN",
                    "data": ["markdown": "```ts\nfunction* prog() {\n  yield \"指令A\"\n}\n```"],
                ],
            ],
        ]
        let html = XArticleHTML.renderBlocks(blocks, entityMap: map)
        ok("h2", html.contains("<h2>从 TestClock 看 Effect 的能力</h2>"))
        ok("bold", html.contains("<strong>社区</strong>"))
        ok("quote", html.contains("<blockquote>框架必须掌握每一个异步续延的调度权。</blockquote>"))
        ok("ul", html.contains("<ul>") && html.contains("<li>从 DST 理解虚拟时间</li>") && html.contains("</ul>"))
        ok("code", html.contains("<pre><code class=\"language-ts\">") && html.contains("function* prog()"))

        let article: [String: Any] = [
            "title": "异步续延与 Effect 架构的第一性原理",
            "content": ["blocks": blocks, "entityMap": map],
        ]
        let full = XArticleHTML.render(article: article) ?? ""
        ok("wrap", full.contains("cv-x-article") && full.contains("<h1>异步续延与 Effect 架构的第一性原理</h1>"))

        if fails > 0 {
            FileHandle.standardError.write(Data("x-article-html: \(fails) failed\n".utf8))
            exit(1)
        }
        print("x-article-html: all passed")
    }
}
