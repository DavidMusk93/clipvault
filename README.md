# ClipFlow - 现代高性能剪切板管理工具

ClipFlow 是一个遵循《软件设计的哲学》原则构建的 macOS 剪切板历史管理应用。它采用 **DuckDB** 作为底层存储引擎，提供高性能的数据读写能力，并配备了现代化的原生 GUI 和 Web 管理界面。

## 🚀 项目亮点

- **🦆 DuckDB 驱动**: 内置高性能嵌入式数据库 DuckDB，轻松处理海量剪切板历史，支持复杂查询。
- **⚡️ 极致性能**: 
  - 启动速度优化（~0.3s 冷启动）。
  - 采用 SwiftUI 虚拟列表（Virtual List）技术，流畅渲染成千上万条记录。
- **🌐 现代化 Web 界面**: 
  - 内置 HTTP 服务器，局域网内通过浏览器访问。
  - 响应式卡片布局，支持深色模式。
  - 富文本预览（HTML、图片 OCR、RTF）。
  - **一键拷贝**功能，手机也能轻松获取电脑剪贴板内容。
- **🛡️ 隐私安全**: 所有数据存储在用户本地文档目录 (`~/Documents/ClipFlow`)，完全掌控数据所有权。
- **⌨️ 原生体验**: 支持键盘导航（上下键选择，回车复制，Delete 删除）。

## 🛠 技术架构

本项目严格遵循《软件设计的哲学》(A Philosophy of Software Design) 原则：

### 核心模块

```
ClipFlow/
├── ClipboardMonitor.swift    # [深度模块] 负责底层剪切板监听与去重
├── DatabaseManager.swift     # [深度模块] 封装 DuckDB C-API，处理高性能存储
├── WebServer.swift           # [深度模块] 集成 Web 服务与前端资源（HTML/CSS/JS）
├── ClipboardViewModel.swift  # [协调层] 连通数据流与 UI，处理业务逻辑
└── ContentView.swift         # [UI 层] 声明式 SwiftUI 界面，虚拟列表优化
```

### 技术栈

- **语言**: Swift 5.9
- **UI 框架**: SwiftUI (macOS 13+)
- **数据库**: DuckDB (通过 C-API 静态链接 `libDuckDB.a`)
- **网络**: Network.framework (原生高性能网络栈)
- **OCR**: Vision Framework (离线文字识别)

## 📦 快速开始

### 环境要求

- macOS 13.0 (Ventura) 或更高版本
- Xcode 14+

### 安装步骤

1. **克隆仓库**
   ```bash
   git clone https://github.com/DavidMusk93/ClipView.git
   cd ClipView
   ```

2. **初始化子模块**
   项目依赖 `duckdb-swift`，请确保子模块已下载：
   ```bash
   git submodule update --init --recursive
   ```

3. **构建准备**
   由于 DuckDB 需要通过静态库链接以绕过 App Sandbox 的部分限制（同时保持高性能），项目已配置为手动管理 `libDuckDB.a`。
   
   *注意：`Vendor/lib/libDuckDB.a` 文件较大，未包含在 git 仓库中。您可能需要根据 `Vendor/duckdb-swift` 的说明手动编译或下载该静态库并放置在 `Vendor/lib/` 目录下。*

4. **运行**
   - 双击打开 `ClipFlow.xcodeproj`
   - 确保证书签名配置正确（Sign to Run Locally）
   - 点击 Xcode 运行按钮 (Cmd + R)

## 📖 使用指南

### 主界面功能
- **监控开关**: 开启/暂停剪切板监听。
- **Web Server**: 开启后，在浏览器访问 `http://localhost:8080`（或局域网 IP）。
- **OCR**: 自动识别图片中的文本（需在设置中开启）。
- **搜索**: 顶部搜索框支持实时过滤历史记录。

### 数据存储
所有数据默认存储于：
```
~/Documents/ClipFlow/
├── clipflow.duckdb          # 主数据库文件
└── Logs/                    # 运行日志
```

## 📝 开发手记

### DuckDB 集成挑战
为了在 macOS Sandbox 环境下获得最佳性能，我们摒弃了传统的 SPM 依赖方式，转而采用 **手动静态链接 (Manual Static Linking)** 方案。通过直接链接 `libDuckDB.a` 并通过 C-API 交互，我们成功绕过了 Swift Package Manager 在沙盒环境下的部分网络和编译限制，同时确保了数据库操作的原子性和速度。

### Web 界面现代化
Web 界面不再是简单的文本列表。我们重写了前端代码，实现了：
- **卡片式设计**: 类似原生应用的视觉体验。
- **富文本渲染**: 能够解析并展示 HTML 片段。
- **交互优化**: 引入 Toast 提示和异步剪贴板写入 API。

## 📄 许可证

MIT License

---

**ClipFlow** - 让剪切板管理如水般流畅。 🌊
