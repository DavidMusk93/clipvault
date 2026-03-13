#!/bin/bash

echo "========================================="
echo "  📋 ClipFlow - 环境检查"
echo "========================================="
echo ""

# 检查 Xcode
if [ -d "/Applications/Xcode.app" ]; then
    echo "✅ Xcode.app 已安装"
    XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1)
    if [ -n "$XCODE_VERSION" ]; then
        echo "   版本: $XCODE_VERSION"
    fi
else
    echo "❌ Xcode.app 未找到"
    echo ""
    echo "📋 重要提示："
    echo "ClipFlow 是一个 macOS GUI 应用，需要 Xcode 才能编译和运行。"
    echo ""
    echo "📥 安装 Xcode 的方式："
    echo ""
    echo "方式 1: 从 App Store 安装（推荐）"
    echo "  1. 打开 App Store"
    echo "  2. 搜索 'Xcode'"
    echo "  3. 点击获取/安装（需要 Apple ID）"
    echo "  4. 安装完成后，打开一次 Xcode 并同意许可协议"
    echo ""
    echo "方式 2: 从 Apple Developer 网站下载"
    echo "  访问: https://developer.apple.com/download/"
    echo ""
fi

echo ""

# 检查命令行工具
if xcode-select -p 2>/dev/null; then
    echo "✅ Xcode 命令行工具已配置"
    CLT_VERSION=$(xcode-select --version 2>&1)
    echo "   $CLT_VERSION"
else
    echo "⚠️  Xcode 命令行工具未配置"
    echo "   可运行: xcode-select --install"
fi

echo ""

# 检查 Swift
if command -v swift &> /dev/null; then
    echo "✅ Swift 已安装"
    SWIFT_VERSION=$(swift --version 2>&1 | head -1)
    echo "   $SWIFT_VERSION"
else
    echo "❌ Swift 未找到"
fi

echo ""
echo "========================================="
echo "  📁 项目文件检查"
echo "========================================="
echo ""

PROJECT_FILE="ClipFlow.xcodeproj/project.pbxproj"
if [ -f "$PROJECT_FILE" ]; then
    echo "✅ 项目文件存在: $PROJECT_FILE"
else
    echo "❌ 项目文件缺失"
fi

SOURCE_DIR="ClipFlow"
if [ -d "$SOURCE_DIR" ]; then
    echo "✅ 源代码目录存在: $SOURCE_DIR"
    FILE_COUNT=$(ls -1 "$SOURCE_DIR"/*.swift 2>/dev/null | wc -l | tr -d ' ')
    echo "   Swift 文件数: $FILE_COUNT"
else
    echo "❌ 源代码目录缺失"
fi

echo ""
echo "========================================="
echo "  🚀 下一步"
echo "========================================="
echo ""

if [ -d "/Applications/Xcode.app" ]; then
    echo "🎉 你的环境已经准备好了！"
    echo ""
    echo "运行方式："
    echo "1. 双击: ClipFlow.xcodeproj"
    echo "2. 或运行: open ClipFlow.xcodeproj"
    echo "3. 或运行: ./quick-start.sh"
    echo ""
    echo "然后在 Xcode 中："
    echo "  - 选择 'My Mac' 目标"
    echo "  - 点击 ▶️ 按钮，或按 Cmd+R"
else
    echo "⚠️  请先安装 Xcode，然后再运行项目。"
    echo ""
    echo "安装完成后，再次运行此脚本检查："
    echo "  ./check-env.sh"
fi

echo ""
