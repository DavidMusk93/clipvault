# Feature: URL 网页归档（Web Archive）

## 一句话目标

对 **用户手动点选** 的网址，用 **本机浏览器引擎** 抓取页面并落成可离线预览的 archive；不是自动爬全网，也不是依赖前端 `fetch`（CORS 会废）。

## 为何不能只靠 Web UI fetch

| 路径 | 结果 |
| --- | --- |
| 卡片页 `fetch(url)` | 几乎全部站点 CORS 失败 |
| iframe 嵌原站 | 不是 archive，依赖在线、隐私差 |
| 扩展 / bookmarklet | 可用，但安装成本高、非默认 |

**正确引擎：ClipFlowServer 内嵌 WebKit（WKWebView）** —— 与 Safari 同源能力，符合「利用浏览器自身能力」。

## 产品原则

1. **仅手动触发**（URL 卡「归档网页」）；用户判断「值得保存」
2. **沿用 §8 链接安全**：成人/敏感域名确认后再归档
3. **增量存储**：archive 进 CAS blobs；条目更新，不每轮全量
4. **预览沙箱**：渲染归档 HTML 时禁用脚本、链接不可点（或需二次确认打开原站）
5. **失败诚实**：超时 / 登录墙 / 付费墙明确提示，不假成功

## 两种保真度（建议分阶段）

| 模式 | 内容 | 体验 | 体积 |
| --- | --- | --- | --- |
| **readable（MVP）** | 标题 + 正文（Readability 类抽取） | 干净阅读，像「稍后读」 | 小 |
| **snapshot（增强）** | 尽量完整 DOM + 内联资源 / PDF | 更接近原页 | 大 |

MVP 先做 **readable**：对「剪贴板里值得留住的链接」性价比最高。

## 用户路径

```text
URL 卡片
  ├─ 打开…（已有，确认后新标签）
  ├─ 复制链接（已有）
  └─ 归档网页  ← 新
        → 确认（含成人门禁）
        → POST /api/archive { url, itemId?, mode: "readable" }
        → 状态：归档中… / 完成 / 失败原因
        → 卡片「查看」：ClipVault 弹层 iframe 嵌 `GET /api/archive/view?embed=1`
        → 同一份文档可再开浏览器新标签（排版与弹层一致）
```

## 架构

```text
┌─────────────┐   POST /api/archive    ┌──────────────────────┐
│  web UI     │ ─────────────────────► │ ClipFlowServer       │
│  (manual)   │ ◄── job status/SSE ─── │ ArchiveService       │
└─────────────┘                        │  └─ WKWebView (offscreen)
                                       │  └─ extract readable
                                       │  └─ CAS write + DB patch
                                       └──────────────────────┘
```

### API（草案）

```http
POST /api/archive
{ "url": "https://…", "itemId": "<uuid>?", "mode": "readable" }

→ 202 { "jobId": "…", "status": "queued" }

GET /api/archive/jobs/{jobId}
→ { status: queued|running|ok|error, title?, bytes?, error? }

GET /api/archive/view?id=<uuid>&embed=1
→ 完整 HTML 文档（浏览器引擎排版原文）。embed=1 去掉页内顶栏，给弹层用。
→ 同域注入 `/assets/archive-reader.js`：悬浮目录 + IndexedDB 阅读位置（不写 SQLite）。

# 列表 JSON 只带 archived + archive meta，不下发正文。
```

### 存储

| 字段 / 位置 | 用途 |
| --- | --- |
| 沿用 `htmlContent` 或 blob `archive/{sha}.html` | 正文 HTML |
| `textContent` | 纯文本/标题+摘要（搜索） |
| meta（keepsake_meta 或 JSON 列） | sourceUrl, mode, archivedAt |
| type | 保持 `url`，或扩展 `type=html` 并挂 sourceUrl（推荐 **仍为 url，带 archive 标记**） |

推荐：**type 仍为 url**，`htmlContent` 非空 = 已归档；UI 显示「已归档」chip。避免引入过多类型分叉。

### 安全

| 项 | 规则 |
| --- | --- |
| SSRF | 禁 `file://`、localhost、链路本地、RFC1918（可配置） |
| 超时 | 导航 + 空闲默认 15–25s |
| 体积 | readable 上限如 2–5MB HTML |
| 脚本 | 预览 DOMPurify；不执行页面 JS 于卡片内 |
| 登录墙 | 检测常见登录标题/过短正文 → error: paywall_or_login |

### 并发

- 同时 1 个 WKWebView 任务（串行队列），避免后台 WebKit 炸内存
- UI 显示排队

## 非目标（首期不做）

- 自动归档每一个复制的 URL  
- 完整 SPA 交互回放  
- 云端爬虫集群  
- 替代 SingleFile 的像素级 100% 保真  

## 实现切片

| Phase | 交付 |
| --- | --- |
| **P0** | **已实现**：`WebArchiveService` + WKWebView + Mozilla Readability；`POST /api/archive`；URL 卡「归档网页」；`htmlContent` + `keepsake_meta`；离线预览（DOMPurify） |
| **P1** | job 队列 + SSE 进度；成人门禁复用；SSRF/超时/体积限制 |
| **P2** | snapshot 模式（PDF 或 single-file 内联）；资源 CAS |
| **P3** | 与 Android 同步展示 archive；搜索归档正文 |

## 技术选型备忘

| 能力 | 选型 |
| --- | --- |
| 浏览器引擎 | **WKWebView**（系统 WebKit） |
| 正文抽取 | 注入 **Mozilla Readability**（成熟）或 Swift 侧简化抽取 |
| HTML 消毒展示 | 已有 **DOMPurify** 路径 |
| 禁止自研 markdown 式「半吊子抓取」 | 引擎 + 成熟抽取库 |

## 验收

1. 对公开文章 URL 点「归档」→ 卡片可离线读正文  
2. 断网后仍可预览归档  
3. 复制仍为原始 URL（或可选「复制正文」）  
4. 滚动列表不因归档完成而全量 rebuild 回顶（差分更新该卡）  
5. 敏感域名走确认  

