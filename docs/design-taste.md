# Keepsake · Design Taste（产品视觉真源）

> **长期产品**：跨 Mac Web / Android / 未来端共用同一套视觉身份。  
> 改颜色、标签、来源色前先改本文，再改实现。  
> 与 `AGENTS.md` §2 产品 taste 配套：叙事气质 + 本文件 = 可执行 token。

## 一句话

**暖蜂蜜品牌 + 语义色标签 + 克制玻璃壳** —— 像个人器物，不像工具箱皮肤。

## 品牌底色

| Token | Hex | 用途 |
| --- | --- | --- |
| Honey（品牌主色） | `#C47A2C` | Android primary、text 类型标签、暖光氛围 |
| Cream | `#F8F1E7` | Android 浅色背景 |
| Ink | `#1C1410` / Web `#1D1D1F` | 正文 |
| Apple chrome bg | `#F5F5F7` | Web 系统浅灰底 |
| Accent（系统蓝） | `#0071E3` | Web 链接/焦点/主按钮（系统感，不抢 Honey） |

Web 与 Android 可有平台壳差异，**语义色必须一致**。

## 剪贴板类型标签（Type badge）

列表/卡片左上角类型 chip。Android `typeStyle()` 与 Web `.badge.type-*` **同一 hex**。

| type | 中文 | Hex | 软底 α≈12% |
| --- | --- | --- | --- |
| `text` | 文本 | `#C47A2C` | Honey |
| `image` | 图片 | `#2E7D32` | 绿 |
| `url` | 链接 | `#1565C0` | 蓝 |
| `html` | HTML | `#6A1B9A` | 紫 |
| `rtf` | 富文本 | `#EF6C00` | 橙 |
| `pdf` | PDF | `#C62828` | 红 |
| `file` | 文件 | `#455A64` | 蓝灰 |
| `other` / 未知 | 其他 | `#5D4037` | 棕 |

规则：

1. 标签用 **语义色字 + 同色 12% 软底**，不要灰底灰字。  
2. 文案用中文（HTML/PDF 可保留拉丁缩写）。  
3. 禁止所有类型共用一个灰色 badge。  
4. 新类型：先补本表，再改 Android / Web。

## 操作日志来源色（Ops source）

Web `.ops-item.src-*` 与 Android `opsSourceStyle()` 共用：

| source | rail / ink 方向 |
| --- | --- |
| `web` | 蓝 `#007AFF` |
| `clipboard` | 绿 `#34C759` |
| `backup` | 紫 `#AF52DE` |
| `maintenance` | 橙 `#FF9500` |
| `app` | 靛 `#5856D6` |
| `sync` | 青 `#32ADE6` |
| `system` / 其它 | 灰 `#8E8E93` |

布局：左侧 3px 色轨 + 来源 pill + 字段区 **不 soft-wrap、可 XY pan**。

## 源码绑定

| 端 | 文件 |
| --- | --- |
| Web | `web/index.html` — `:root` type tokens、`.badge.type-*`、`typeMeta()` |
| Android | `ui/ContentRender.kt` `typeStyle()`；`MainActivity.kt` `opsSourceStyle()` |
| 产品约定 | `AGENTS.md` §2 + **本文** |

## 品味禁区

| Don't | 为什么 |
| --- | --- |
| 每端各调一盘色 | 品牌碎裂 |
| 灰 badge 通吃类型 | 扫一眼分不清介质 |
| 堆彩虹装饰、无语义 | 像玩具不是器物 |
| 为「好看」改交互语义色 | 色 = 信息通道 |

## 交互密度（轻量 & lazy）

**原则：展示尽可能充足的信息，同时尽可能轻量 & lazy。**

| Do | Don't |
| --- | --- |
| 单 ref（`copyCount ≤ 1`）只露主时间，无「事件时间线」入口 | 每张卡片都挂可展开时间线壳 |
| 多 ref 才露出时间线；内容 **点击后** 再 fetch | 列表阶段预拉 events |
| 展开只 **就地变高**（列高 remeasure），不 remount 瀑布流 | `rebuildFromData` / 整墙重排 |
| 字段/日志：需要时再滚、再加载 | 为「完整」预渲染隐藏 DOM |

时间线 = **多捕获历史** 的二级细节，不是默认噪音。

瀑布流内 **禁止就地 expand**（列高/重排不稳）。多 ref 时间线用 **底部可交互 toast 卡片** （毛玻璃 sheet + scrim，lazy fetch，Esc/遮罩关闭）—— 列表零布局扰动。
