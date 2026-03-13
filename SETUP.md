# ClipFlow 项目设置指南

## 项目概述

ClipFlow 是一个 **macOS GUI 应用程序**，使用 SwiftUI 和 AppKit 构建。

### 重要说明

**这个项目需要 Xcode 才能编译和运行！**

这是因为：
- 使用了 SwiftUI（macOS 原生 UI 框架）
- 使用了 AppKit（与 macOS 系统集成）
- 需要访问剪切板、菜单栏等系统功能

## 前置要求

### 1. 安装 Xcode

#### 方式 A：从 App Store 安装（推荐）
1. 打开 Mac 上的 App Store
2. 搜索 "Xcode"
3. 点击获取/安装（需要 Apple ID）
4. 安装完成后，打开一次 Xcode 并同意许可协议

#### 方式 B：安装命令行工具（如果只需要编译命令行工具）
```bash
xcode-select --install
```

**注意**：命令行工具不足以编译这个 GUI 应用，需要完整的 Xcode。

## 运行项目

### 步骤 1：打开项目
双击 `ClipFlow.xcodeproj` 文件，或在终端运行：
```bash
open ClipFlow.xcodeproj
```

### 步骤 2：选择目标
在 Xcode 顶部工具栏，选择：
- 目标设备：**My Mac**（你的 Mac）
-  scheme：**ClipFlow**

### 步骤 3：运行
点击左上角的 **▶️ 运行按钮**，或按快捷键 `Cmd + R`

## 项目结构

```
ClipFlow/
├── ClipFlow/                   # 主应用源代码
│   ├── ClipFlowApp.swift       # 应用入口
│   ├── ClipboardItem.swift     # 数据模型
│   ├── ClipboardMonitor.swift  # 剪切板监听
│   ├── DatabaseManager.swift   # 数据管理（JSON）
│   ├── ClipboardViewModel.swift  # 视图模型
│   ├── WebServer.swift         # Web 服务器
│   ├── ContentView.swift       # GUI 界面
│   └── Assets.xcassets/
├── ClipFlow.xcodeproj/         # Xcode 项目文件
├── Package.swift               # Swift Package Manager 配置
├── README.md                   # 项目文档
├── SETUP.md                    # 本文档
├── run.sh                      # 运行脚本
└── quick-start.sh              # 快速开始脚本
```

## 功能特性

- ✅ 监听剪切板变化（文本、图片、文件、URL 等）
- ✅ 本地数据存储（JSON 文件，预留 DuckDB 接口）
- ✅ 现代化 SwiftUI GUI 界面
- ✅ 内置 Web 服务器（端口 8080）
- ✅ 搜索功能
- ✅ 内容去重
- ✅ 菜单栏快捷访问

## 数据存储位置

所有数据存储在：
```
~/Library/Application Support/ClipFlow/
├── clipflow.duckdb          # DuckDB 文件（预留）
└── items/                    # JSON 格式的剪切板历史
    ├── <UUID1>.json
    ├── <UUID2>.json
    └── ...
```

## 设计原则

本项目严格遵循《软件设计的哲学》(A Philosophy of Software Design)：
- **深度模块**: 简单接口，丰富实现
- **信息隐藏**: 封装所有实现细节
- **向下拉取复杂度**: 模块内部处理复杂逻辑
- **优雅的数据流**: 单向数据流，易于追踪

## 常见问题

### Q: 可以不使用 Xcode 运行吗？
A: 不行。这是一个 macOS GUI 应用，需要 Xcode 来编译 SwiftUI 和 AppKit 代码。

### Q: 数据存储在哪里？
A: 在 `~/Library/Application Support/ClipFlow/` 目录下。

### Q: 如何使用 Web 界面？
A: 在应用中开启 "Web Server" 开关，然后浏览器访问 `http://localhost:8080`。

### Q: DuckDB 什么时候支持？
A: 当前使用 JSON 文件存储（简单可靠）。`Package.swift` 已配置 DuckDB 依赖，随时可以切换。

## 技术栈

- **语言**: Swift 5.9+
- **UI 框架**: SwiftUI
- **系统框架**: AppKit
- **网络**: Network framework
- **存储**: JSON 文件（预留 DuckDB 接口）
- **响应式**: Combine
- **并发**: Grand Central Dispatch (GCD)

## 许可证

MIT License
