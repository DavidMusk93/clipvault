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
        ok("not-flat-ul", !XArticleHTML.looksFlattened("<div><ul><li>a</li></ul></div>"))
        ok("heading-cn", XArticleHTML.headingLike("一、维他命与补剂：先验血，再补缺口"))
        ok("heading-five", XArticleHTML.headingLike("五、最核心、投入产出比最高的5 条行动"))
        ok("heading-num", XArticleHTML.headingLike("1. Zone 2"))
        ok("not-heading-body", !XArticleHTML.headingLike("当下欧美精英阶层的健康方式已经高度趋同：把健康当成可量化、可审计的资产。"))
        ok("not-heading-fact", !XArticleHTML.headingLike("Fact：曼哈顿私人诊所的常规是每年检测ApoB。"))

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
        ok("usable", XArticleHTML.isUsableArticleHTML(full))

        // Kenny-style: title + unstyled 一、 + ul/ol, no header-two / MARKDOWN.
        // Old gate required <pre>|<h2> and dropped this onto Readability <p> soup.
        let kennyBlocks: [[String: Any]] = [
            ["type": "unstyled", "text": "把健康当成可量化资产。", "inlineStyleRanges": [["offset": 5, "length": 3, "style": "Bold"]]],
            ["type": "unstyled", "text": "一、维他命与补剂：先验血，再补缺口"],
            ["type": "unordered-list-item", "text": "Omega-3", "inlineStyleRanges": [["offset": 0, "length": 7, "style": "Bold"]]],
            ["type": "unordered-list-item", "text": "维生素 D3 + K2"],
            ["type": "unstyled", "text": "五、最核心、投入产出比最高的5 条行动"],
            ["type": "ordered-list-item", "text": "每周锁定 180 分钟 Zone 2"],
            ["type": "ordered-list-item", "text": "固定 7-7.5 小时睡眠窗口"],
        ]
        let kennyArticle: [String: Any] = [
            "title": "欧美精英阶层极简健康管理架构",
            "cover_media": [
                "media_info": ["original_img_url": "https://pbs.twimg.com/media/HHjlxaAWAAcqAIn.jpg"],
            ],
            "content": ["blocks": kennyBlocks, "entityMap": [] as [Any]],
        ]
        let kenny = XArticleHTML.render(article: kennyArticle) ?? ""
        ok("kenny-usable", XArticleHTML.isUsableArticleHTML(kenny))
        ok("kenny-h1", kenny.contains("<h1>欧美精英阶层极简健康管理架构</h1>"))
        ok("kenny-cover", kenny.contains("HHjlxaAWAAcqAIn.jpg"))
        ok("kenny-h2", kenny.contains("<h2>一、维他命与补剂：先验血，再补缺口</h2>"))
        ok("kenny-h2-five", kenny.contains("<h2>五、最核心、投入产出比最高的5 条行动</h2>"))
        ok("kenny-ul", kenny.contains("<ul>") && kenny.contains("<li><strong>Omega-3</strong></li>"))
        ok("kenny-ol", kenny.contains("<ol>") && kenny.contains("<li>每周锁定 180 分钟 Zone 2</li>"))
        ok("kenny-no-pre-ok", !kenny.lowercased().contains("<pre"))
        ok("kenny-bold-body", kenny.contains("<strong>可量化</strong>"))

        let gtBlock: [[String: Any]] = [
            ["type": "unstyled", "text": "核心是 数据 > 意志力", "inlineStyleRanges": [["offset": 4, "length": 8, "style": "Bold"]]],
        ]
        let gtHTML = XArticleHTML.renderBlocks(gtBlock, entityMap: nil)
        ok("bold-gt", gtHTML.contains("<strong>数据 &gt; 意志力</strong>"))
        ok("bold-gt-once", !gtHTML.contains("&amp;gt;"))

        // JoshXie-style: atomic MEDIA has mediaId only; URL is on article.media_entities.
        let joshBlocks: [[String: Any]] = [
            ["type": "unstyled", "text": "最终我做了图右的小程序"],
            [
                "type": "atomic",
                "text": " ",
                "entityRanges": [["key": 0, "length": 1, "offset": 0]],
            ],
            ["type": "unstyled", "text": "市面上大部分回复助手都是图左"],
            [
                "type": "atomic",
                "text": " ",
                "entityRanges": [["key": 1, "length": 1, "offset": 0]],
            ],
        ]
        let joshMap: [[String: Any]] = [
            [
                "key": "0",
                "value": [
                    "type": "MEDIA",
                    "data": [
                        "mediaItems": [[
                            "localMediaId": "14",
                            "mediaCategory": "DraftTweetImage",
                            "mediaId": "2057506819006976001",
                        ]],
                    ],
                ],
            ],
            [
                "key": 1,
                "value": [
                    "type": "MEDIA",
                    "data": [
                        "mediaItems": [[
                            "mediaId": "2057495103355383808",
                        ]],
                    ],
                ],
            ],
        ]
        let joshArticle: [String: Any] = [
            "title": "不会代码，投入0元，AI帮我成立了公司",
            "cover_media": [
                "media_id": "2057503306176692225",
                "media_info": ["original_img_url": "https://pbs.twimg.com/media/HI24WxjagAEI9UL.jpg"],
            ],
            "media_entities": [
                [
                    "media_id": "2057506819006976001",
                    "media_info": ["original_img_url": "https://pbs.twimg.com/media/HI27jP3a0AEnOgM.jpg"],
                ],
                [
                    "media_id": "2057495103355383808",
                    "media_info": ["original_img_url": "https://pbs.twimg.com/media/HI2w5TqacAAKNje.jpg"],
                ],
            ] as [[String: Any]],
            "content": ["blocks": joshBlocks, "entityMap": joshMap],
        ]
        let joshDoc = XArticleHTML.renderDocument(article: joshArticle)!
        let josh = joshDoc.html
        ok("josh-cover", josh.contains("HI24WxjagAEI9UL.jpg"))
        ok("josh-body-1", josh.contains("HI27jP3a0AEnOgM.jpg"))
        ok("josh-body-2", josh.contains("HI2w5TqacAAKNje.jpg"))
        ok("josh-img-count", josh.components(separatedBy: "<img ").count - 1 == 3)
        ok("josh-cov-media", joshDoc.coverage.mediaExpected == 3 && joshDoc.coverage.mediaRendered == 3)
        ok("josh-cov-atomic", joshDoc.coverage.atomicExpected == 2 && joshDoc.coverage.atomicDropped == 0)
        ok("josh-cov-warn-empty", joshDoc.coverage.warnings.isEmpty)
        let noMedia = XArticleHTML.renderBlocks(joshBlocks, entityMap: joshMap)
        ok("josh-no-index-drops", !noMedia.contains("<img") && noMedia.contains("cv-x-dropped"))
        ok("josh-dropped-caption", noMedia.contains("mediaId=2057506819006976001"))

        var missingEntities = joshArticle
        missingEntities["media_entities"] = [] as [Any]
        let missing = XArticleHTML.renderDocument(article: missingEntities)!
        ok("missing-cover", missing.html.contains("HI24WxjagAEI9UL.jpg"))
        ok("missing-dropped", missing.html.contains("cv-x-dropped"))
        ok("missing-no-body-url", !missing.html.contains("HI27jP3a0AEnOgM.jpg"))
        ok("missing-atomic-dropped", missing.coverage.atomicDropped == 2)
        ok("missing-warnings", !missing.coverage.warnings.isEmpty)

        let unknownBlocks: [[String: Any]] = [[
            "type": "atomic",
            "text": " ",
            "entityRanges": [["key": 0, "length": 1, "offset": 0]],
        ]]
        let unknownMap: [[String: Any]] = [[
            "key": 0,
            "value": ["type": "TWITTER_CARD", "data": [:] as [String: Any]],
        ]]
        let unknown = XArticleHTML.renderBlocks(unknownBlocks, entityMap: unknownMap)
        ok("unknown-dropped", unknown.contains("cv-x-dropped") && unknown.contains("data-entity=\"TWITTER_CARD\""))

        if fails > 0 {
            FileHandle.standardError.write(Data("x-article-html: \(fails) failed\n".utf8))
            exit(1)
        }
        print("x-article-html: all passed")
    }
}
