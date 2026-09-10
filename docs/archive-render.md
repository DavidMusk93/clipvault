# 归档网页渲染知识库

ClipVault 离线阅读面怎么从 URL 变成可排版的 HTML。产品入口与存储见 [`feature-url-archive.md`](feature-url-archive.md)。视觉 token 见 [`design-taste.md`](design-taste.md)「归档 View 技术介质」。

## 一句话

归档分两层：**CAS 里的抽取 HTML**（快照，改渲染器要重新归档）和 **View 运行时**（CSS/JS 包板、目录、划线；禁止为了好看改 `archive_html`）。

## 两层

```text
  捕获（写入 CAS）                         阅读（不写 CAS）
  WebArchiveService                        GET /api/archive/view
    ├─ X 快路径 Draft.js → HTML            ├─ flattenPictures / promoteLazyImages
    └─ 否则 WKWebView + Readability        ├─ decorateArchiveMedia（YouTube 链）
         └─ ArchiveImageInliner            ├─ archive-view.css
              图 → blobs + /api/archive/asset
                                           └─ archive-reader.js enhanceTechnicalMedia
                                                代码板 / 图板 / 表 / callout / lightbox
```

| 层 | 可变？ | 产物 |
| --- | --- | --- |
| Capture HTML | 归档当时冻结 | `archive_html` + 图 blob 闭包 |
| View 包装 | 每次 GET 现包 | 文档壳、CSP、`cv-*` 类 |
| 阅读态 | SQLite | 划线 / 评论 / 续读；不进 HTML |

禁止：View 为高亮改 CAS；同步拉出版商 CDN 图（CSP `img-src 'self'`，iframe 会像「归档为空」）。

## 捕获流水线

```text
POST /api/archive
  │
  ├─ x.com / twitter.com ?
  │    是 → XArticleHTML.archive
  │         1. fxtwitter article.content.blocks（X Article / Draft.js）
  │         2. 否则 vxtwitter 全文（Note / 长帖；fxtwitter text 常被截到 ~140）
  │            `\n\n` → <p>；headingLike → <h2>；qrt → blockquote.cv-x-quote
  │         可用（cv-x-article 且够长）→ 跳过 Readability
  │         失败 → 回落 WKWebView；enrich 再按最长节点剥换行重切段
  │
  └─ 否 → 离屏 WKWebView（无 Safari cookie；无系统代理则 SOCKS :2080）
           Readability.js（二进制同目录）
           抽前 repairOrphanFigures：孤儿 img+figcaption 包进 figure
           保留「每条 li 有文案+图」

  → 内联远程 <img> → CAS
  → meta.engine / meta.coverage
  → ArchiveBlobClosure（root HTML + 它点名的全部 blob）
```

`cv-x-article` 只说明走了 Draft.js 重建，**不等于**介质齐。对照作者清单，对不上要占位 + `meta.coverage.warnings`。

## X Article（Draft.js）

长文不在登出 DOM 里。真源是 `article.content`：

```text
blocks[]                  entityMap[]（乱序 {key,value}）
  type                    key: 10          ← 按这个找，不是数组下标
  text                    value.type
  entityRanges[{key}]  →  value.data
  inlineStyleRanges
```

例：`https://x.com/AdrianPunk115/status/2088543211656753278`  
78 blocks；entityMap 12 条；`MEDIA×10` + `LINK×1` + `DIVIDER×1`。  
`key=10` 是 DIVIDER，数组下标 10 却是另一张 MEDIA。按下标查会把分割线认成图、或把图认成分割线。

### block.type

有 `article.title` 时先输出 `<h1>`，正文 `header-*` **下移一级**，避免和标题抢 h1。

| type | 无标题 | 有标题（shift=1） |
| --- | --- | --- |
| `header-one` | `h1` | `h2` |
| `header-two` | `h2` | `h3` |
| `header-three` | `h3` | `h4` |
| `blockquote` | `blockquote` | 同 |
| `code-block` | `pre>code` | 同 |
| `unordered-list-item` / `ordered-list-item` | 连续 `ul`/`ol` | 同 |
| `unstyled` 且像「一、…」「1. …」 | `h2`（`headingLike`，不 shift） | 同 |
| `unstyled` | `p` | 同 |
| `atomic` | 看 entity | 同 |

### atomic entity.type

| type | 语义 | 归档 |
| --- | --- | --- |
| `MEDIA` / `IMAGE` | 正文图。entity 常只有 `mediaId` | `<figure><img>`，URL 来自 `article.media_entities[].media_info.original_img_url` |
| `MARKDOWN` | 围栏代码 | `renderFence` → `pre>code` |
| `DIVIDER`（别名 `HR` / `HORIZONTAL_RULE`） | 装饰分割线，`data` 为空 | **`<hr>`**。不是丢图 |
| `LINK` | inline `entityRanges`，偶尔 atomic | `<a href>`（只 http/https；`rel=noreferrer` `target=_blank`）。`javascript:` 丢掉属性，留纯文本 |
| 其它（`TWITTER_CARD`…） | 未建模 | `.cv-x-dropped` +「未归档的介质（TYPE）」 |

inline 还认：

| 来源 | 结果 |
| --- | --- |
| `inlineStyleRanges` Bold/Italic/Underline/Strikethrough/CODE | `strong` / `em` / `u` / `s` / `code` |
| `entityRanges` LINK | `<a>`，与加粗可套叠 |
| `block.data.urls[]` `fromIndex..toIndex` | 裸 URL 自动成链（与 entity 同区间不重复） |
| `block.data.mentions[]` | `https://x.com/{handle}`（已被 LINK 覆盖则跳过） |

封面：`cover_media.media_info.original_img_url`，与正文 `media_entities` 分开索引。

禁止：只认 entity 上的 `src`/`url`（会只剩封面、正文图全丢）；解析失败的 atomic 静默省略。

### 覆盖率 `meta.coverage`

| 字段 | 含义 |
| --- | --- |
| `mediaExpected` / `mediaRendered` | `media_entities`+封面 vs 实际 `<img>` |
| `atomicExpected` / `atomicRendered` / `atomicDropped` | atomic 块；DIVIDER 算 rendered，不算 dropped |
| `markdownExpected` / `markdownRendered` | MARKDOWN 实体 |
| `warnings[]` | 丢图 / 未解析介质 / 代码块缺口；UI 可展示 |

成功分割线不得进 warnings。

## 站点特例（Readability 路径）

| 站点/形态 | 坑 | 修正 |
| --- | --- | --- |
| 微信 | `src` 是 1px SVG，真地址在 `data-src` | View `promoteLazyImages` |
| Medium | `<picture><source srcset=miro…>` 盖过已内联的 `img src` | `flattenPictures` 剥 source/srcset |
| Mermaid 时序图 | Readability 剥 stroke | `archive-view.css` 补 sequence stroke |
| YouTube / Vimeo | iframe 可进 CSP `frame-src` | View 后补「Watch」链，不改 CAS |
| 技术文 callout | Readability 收成嵌套 `<article>` | View `wrapCallouts`；禁止当 h2 进 TOC |

图默认浅纸板 `#F5F5F7`；仅「整体偏暗且不太透明」才 `.is-dark`。禁止透明流程图铺黑底。

## View 运行时

`GET /api/archive/view?id=&embed=1` 包完整文档。弹层与新标签同一份。

- 图只走 `/api/archive/asset?sha=`
- `enhanceTechnicalMedia` 只包 `.cv-code` / `.cv-figure` / `.cv-table` / `.cv-callout`
- `.cv-article hr` 已有分割线样式，X 的 `<hr>` 直接用
- 已归档条目要看到新抽取逻辑：**重新点「归档网页」**。View CSS/JS 改了刷新即可

## 改渲染器清单

1. 先对层：抽取（Swift）还是 View（css/js）？抽取进 CAS，View 不写库。
2. 新 atomic type：在 `renderAtomic` 显式分支；能画的算 `atomicRendered`；不能画的 `droppedFigure`，禁止省略。
3. `entityMap` **先匹配 `key`**，禁止 `arr[i]` 当 key。
4. 测：`tests/x_article_main.swift`（`swiftc` 进 `check-frontend.sh`）+ `tests/archive-view.test.mjs` 字符串门禁。
5. 对照作者介质清单（X：`media_entities` / atomic / MARKDOWN / DIVIDER / LINK / `data.urls`）。
6. 回写本文 entity 表；视觉改动先改 `design-taste.md`。

## 源码索引

| 文件 | 职责 |
| --- | --- |
| `ClipFlow/WebArchiveService.swift` | 队列、X 快路径、WK 会话、persist |
| `ClipFlow/XArticleHTML.swift` | Draft.js → HTML + coverage |
| `ClipFlow/ArchiveImageInliner.swift` | 远程图 → CAS；flatten `<picture>` |
| `ClipFlow/ArchiveBlobClosure.swift` | 闭包 keys |
| `ClipFlow/WebServer.swift` | `/api/archive/view` 文档壳、CSP、lazy img、视频链 |
| `web/assets/archive-view.css` | 阅读面 + 介质板 |
| `web/assets/archive-reader.js` | 目录 / 划线 / `enhanceTechnicalMedia` |
| `tests/x_article_main.swift` | Draft.js 重建 |
| `tests/archive-view.test.mjs` | View 契约字符串门禁 |
