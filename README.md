# ClipFlow - 优雅的剪切板历史管理工具

一个遵循《软件设计的哲学》原则的 macOS 剪切板历史管理应用，支持多种剪切板类型，数据本地持久化存储，并提供 Web 界面。

## 项目亮点

- ✨ **优雅命名**: ClipFlow - 流畅、简洁、好记
- 📦 **模块化设计**: 每个模块职责单一，深度封装
- 💾 **DuckDB 准备**: 预留 DuckDB 集成接口，当前使用 JSON 文件存储
- 🖥️ **现代化 GUI**: SwiftUI 打造的精美界面
- 🌐 **Web 界面**: 内置 HTTP 服务器，浏览器访问
- 🚀 **简单运行**: 提供脚本，即使是 Mac 小白也能轻松使用

## 架构设计

本项目严格遵循《软件设计的哲学》(A Philosophy of Software Design) 中的设计原则：

### 核心设计原则

1. **深度模块** - 简单接口，丰富实现
2. **信息隐藏** - 封装所有实现细节
3. **向下拉取复杂度** - 模块内部处理复杂逻辑
4. **将错误定义为不存在** - 通过设计减少异常

### 模块架构

```
ClipFlow/
├── ClipboardItem.swift       # 数据模型
├── ClipboardMonitor.swift    # 剪切板监听（深度模块）
├── DatabaseManager.swift     # 数据库管理（深度模块）
├── ClipboardViewModel.swift  # 视图模型（协调层）
├── WebServer.swift           # Web 服务器
├── ContentView.swift         # SwiftUI 界面
└── ClipFlowApp.swift         # 应用入口
```

## 功能特性

- ✅ 监听剪切板变化（支持所有类型）
- ✅ 本地数据持久化（JSON 文件，预留 DuckDB 接口）
- ✅ 现代化 macOS GUI 界面
- ✅ Web 展示界面（默认端口 8080）
- ✅ 搜索功能
- ✅ 内容去重（基于 SHA256 哈希）
- ✅ 记录来源应用
- ✅ 菜单栏快捷访问

## 快速开始（Mac 小白也会用！）

### 方法一：使用运行脚本（最简单）

1. 打开终端（Terminal）
2. 进入项目目录：
   ```bash
   cd /Users/<user>/Documents/ClipFlow
   ```
3. 运行脚本：
   ```bash
   ./run.sh
   ```
4. 按提示输入 `y`，Xcode 会自动打开
5. 在 Xcode 中：
   - 选择顶部的 "My Mac" 目标
   - 点击左上角的运行按钮（▶️）或按 `Cmd + R`

### 方法二：手动打开 Xcode

1. 双击 `ClipFlow.xcodeproj` 文件
2. 在 Xcode 中选择 "My Mac" 目标
3. 点击运行按钮（▶️）

## 使用说明

### 主界面功能

- **监控开关**: 控制是否监听剪切板（默认开启）
- **Web 服务器**: 点击开启后，浏览器访问 `http://localhost:8080`
- **搜索框**: 输入关键词过滤历史记录
- **列表项**: 点击查看详情，右键菜单可复制/删除
- **刷新按钮**: 重新加载历史记录
- **清空按钮**: 清空所有历史记录

### 数据存储位置

所有数据存储在：
```
~/Library/Application Support/ClipFlow/
├── clipflow.duckdb          # DuckDB 数据库文件（预留）
└── items/                    # JSON 格式的剪切板历史
    ├── <UUID1>.json
    ├── <UUID2>.json
    └── ...
```

## 学习 macOS 开发

这个项目展示了以下 macOS 开发技术：

- **SwiftUI**: 现代化声明式 UI 框架
- **AppKit**: 系统集成（菜单栏、剪切板）
- **Network**: 现代网络编程
- **Foundation**: 文件管理、JSON 序列化
- **Combine**: 响应式编程
- **GCD**: 多线程和异步处理

## 设计亮点详解

### 1. 深度模块设计

`ClipboardMonitor` 和 `DatabaseManager` 都是典型的深度模块：

```swift
// 简单的接口
monitor.startMonitoring()
monitor.stopMonitoring()

database.saveItem(item)
database.fetchItems { items in ... }
```

内部实现复杂，但调用者完全不需要了解。

### 2. 信息隐藏

- 剪切板监听的定时器、哈希计算都封装在内部
- 数据库存储的格式、路径完全隐藏
- Web 服务器的网络处理细节不暴露

### 3. 向下拉取复杂度

- 异步处理在模块内部完成
- 错误处理在底层进行
- 调用者只需关心简单的接口

### 4. 优雅的数据流

```
剪切板 → ClipboardMonitor → ClipboardViewModel 
                                    ↓
                            DatabaseManager
                                    ↓
                        JSON 文件存储
                                    ↓
                ┌───────────────────┴───────────────────┐
                ↓                                       ↓
          ContentView (GUI)                    WebServer (Web)
```

## DuckDB 集成说明

当前版本使用 JSON 文件存储，已预留 DuckDB 接口：

- `DatabaseManager.swift` - 当前使用 JSON 文件
- `DatabaseManagerSQLite.swift` - SQLite 版本备份
- `Package.swift` - 已配置 DuckDB Swift 依赖

如需切换到 DuckDB：
1. 安装 DuckDB CLI: `brew install duckdb`
2. 或使用 DuckDB Swift 绑定重写 `DatabaseManager`

## 项目结构

```
ClipFlow/
├── ClipFlow/                   # 主应用源代码
│   ├── ClipboardItem.swift
│   ├── ClipboardMonitor.swift
│   ├── DatabaseManager.swift
│   ├── DatabaseManagerSQLite.swift  # SQLite 备份版本
│   ├── ClipboardViewModel.swift
│   ├── WebServer.swift
│   ├── ContentView.swift
│   ├── ClipFlowApp.swift
│   └── Assets.xcassets/
├── ClipFlow.xcodeproj/         # Xcode 项目
├── Package.swift               # Swift Package Manager 配置
├── run.sh                      # 快速运行脚本
├── README.md                   # 本文档
└── SKILL.md                    # 软件设计哲学指南
```

## 未来改进

- [ ] 完整 DuckDB 集成
- [ ] iCloud 同步支持
- [ ] 标签和分类功能
- [ ] 全局快捷键
- [ ] 更多 Web 界面功能
- [ ] 数据导出功能

## 许可证

MIT License

---

**享受流畅的剪切板管理体验！** 🚀
